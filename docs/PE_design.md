# Processing Element (PE) Design

## Overview

Each processing element computes the product of the two data elements
it is given, adds that to one of two private accumulators, and passes
the elements along to its neighbors. Two accumulator banks allow the
PE to hold a finished tile's result while beginning accumulation on
the next tile, enabling overlapped wavefronts across the array.

## Interface

### Parameters
| Name | Default | Description |
|---|---|---|
| `DATA_WIDTH` | 8 | Bit width of input operands (A, B elements), signed |
| `ACC_WIDTH` | 32 | Bit width of each accumulator, signed |

### Ports
| Name | Direction | Width | Description |
|---|---|---|---|
| `clk` | input | 1 | Clock |
| `rst` | input | 1 | Synchronous reset, clears both accumulators and pass-through registers to 0 |
| `pingpong` | input | 1 | Selects which bank accumulates: 0 -> result1, 1 -> result2 |
| `pingpongrst` | input | 1 | Clears the inactive bank (the one `pingpong` does not currently select) |
| `enable` | input | 1 | Gates accumulation and pass-through; low holds all registers |
| `a_in` | input | signed DATA_WIDTH | Element of A from left neighbor |
| `b_in` | input | signed DATA_WIDTH | Element of B from top neighbor |
| `a_out` | output | signed DATA_WIDTH | Registered pass-through of a_in, one cycle later |
| `b_out` | output | signed DATA_WIDTH | Registered pass-through of b_in, one cycle later |
| `result1` | output | signed ACC_WIDTH | Bank 0 accumulator |
| `result2` | output | signed ACC_WIDTH | Bank 1 accumulator |

## Behavior

On each rising clock edge, in priority order:
1. `rst`: both accumulators, `a_out`, and `b_out` clear to 0.
2. `pingpongrst`: the bank not selected by `pingpong` clears to 0. The
   selected bank is untouched, so accumulation into it can continue on
   the same cycle a reset fires elsewhere.
3. `enable`: the PE computes `a_in * b_in` and adds it into whichever
   bank `pingpong` currently selects, and registers `a_in` -> `a_out`,
   `b_in` -> `b_out`.

Steps 2 and 3 target different registers under any given `pingpong`
value and do not conflict; both can fire on the same cycle.

The one-cycle registered delay on `a_out`/`b_out` produces the
systolic wavefront: data at PE(i,j) on cycle t reaches PE(i,j+1) and
PE(i+1,j) at cycle t+1.

## Design Decisions

**Output-stationary dataflow** was chosen over weight-stationary for
implementation simplicity, at the cost of not exploiting weight reuse
across a batch the way a weight-stationary array naturally can. The
tradeoff is discussed further in `array_design.md` and
`accelerator_plan.md`.

**Dual accumulator banks with per-diagonal pingpong** replace the
original single-accumulator design once the array moved from
processing one tile at a time to overlapped wavefronts, where
different diagonals of the array can be mid-accumulation on different
output tiles simultaneously. A single global pingpong bit cannot
express this, since different diagonals reach their own toggle point
at different cycles; `pingpong` and `pingpongrst` are driven
per-diagonal by the array (see `array_design.md`), and the PE itself
only needs to know its own current bit.

**Signed arithmetic** was added after recognizing that trained neural
network weights are routinely negative; an unsigned multiply of a
negative weight against a positive activation produces a wrong-sign,
wrong-magnitude result. This bug was invisible under early testing
with small positive-only test values and only surfaced once the
testbench swept the full signed range.

**`ACC_WIDTH = 32`** carries generous headroom (strict minimum is
`2*DATA_WIDTH + ceil(log2(N))`) to avoid recomputing the bound per
scale; the extra bits cost negligible FF resources.

**Synchronous reset** for cleaner FPGA timing analysis and no
metastability concern on deassertion.

**Priority-ordered branches, not independent `if`s.** An earlier
version had `rst`, `pingpongrst`, and `enable` as three separate `if`
statements rather than a priority chain; when `pingpongrst` and
`enable` were both asserted on the same cycle, the PE skipped
accumulation entirely for that cycle, silently dropping one MAC per
tile transition. Structuring the branches as `if / else if / else if`
makes `pingpongrst` and `enable` (for the active bank) able to fire
together correctly, since they target disjoint registers, while still
giving `rst` unconditional priority.