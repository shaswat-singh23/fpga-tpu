# Processing Element (PE) Design

## Overview

Each processing element within the systolic array is responsible for computing the product of the two data elements it's given, adding that to its private accumulated sum, and passing along the appropriate data elements to its neighbors.

## Interface

### Parameters
| Name | Default | Description |
|---|---|---|
| `DATA_WIDTH` | 8 | Bit width of input operands (A, B elements) |
| `ACC_WIDTH` | 32 | Bit width of accumulator (chosen high to prevent overflow across scaling; see Design Decisions) |

### Ports
| Name | Direction | Width | Description |
|---|---|---|---|
| `clk` | input | 1 | Clock signal |
| `rst` | input | 1 | Synchronous reset (clears accumulator and pass-through registers to 0) |
| `enable` | input | 1 | Gates accumulation; when low, PE holds all registers unchanged |
| `a_in` | input | DATA_WIDTH | Element of matrix A from left neighbor |
| `b_in` | input | DATA_WIDTH | Element of matrix B from top neighbor |
| `a_out` | output | DATA_WIDTH | Pass-through of a_in to right neighbor (registered, one-cycle delay) |
| `b_out` | output | DATA_WIDTH | Pass-through of b_in to bottom neighbor (registered, one-cycle delay) |
| `result` | output | ACC_WIDTH | Running accumulated value (a_in × b_in summed across active cycles) |

## Behavior

On each rising clock edge:
- If `rst` is asserted, `result`, `a_out`, and `b_out` are all cleared to 0.
- Else if `enable` is high, the PE computes `a_in × b_in`, adds the product to the internal accumulator, and registers `a_in` → `a_out` and `b_in` → `b_out` for pass-through to neighbors on the next cycle.
- Else (`enable` low, not in reset), all registers hold their current values — no accumulation, no pass-through update.

The one-cycle registered delay on `a_out`/`b_out` is what enables the systolic wavefront pattern: data arriving at PE(i,j) on cycle t propagates to PE(i,j+1) and PE(i+1,j) at cycle t+1, correctly aligned for their own computation.

## Design Decisions

**Output-stationary dataflow** was chosen over weight-stationary. Weight-stationary is more efficient when the same weight matrix processes many different inputs (as in LLM inference, where trained weights are frozen and streamed against different activation batches), because weights load once and stay put while activations flow through, reducing per-cycle data movement. However, this project's verification methodology uses different random test matrices for each simulation run — there's no weight reuse pattern to exploit — so output-stationary's per-cycle data flow of both operands has equivalent efficiency here while being simpler to implement correctly.

**`ACC_WIDTH = 32`** was chosen with generous headroom to accommodate scaling without needing recalculation for each N. Strict minimum required is `2*DATA_WIDTH + ceil(log2(N))` (16 + log₂N for DATA_WIDTH=8) — 18 bits at N=4, 20 bits at N=16, 21 bits at N=32. Choosing 32 upfront avoids per-scale readjustment; the extra bits cost negligible additional FF resources.

**Synchronous reset** was chosen over asynchronous reset for cleaner FPGA timing analysis and to avoid metastability concerns on reset deassertion. The reset condition is checked inside the clock-triggered `always_ff` block, taking effect on the next `posedge clk` when `rst` is high.

**Per-PE `enable` gating** (rather than always-accumulating behavior) was added after recognizing that PEs need to be inactive until real data reaches them via the systolic wavefront. Without gating, PEs would accumulate zero-valued products from idle inputs during pre-activation cycles, which is functionally harmless (0 × 0 = 0) but signals a design that hadn't correctly modeled the temporal wavefront pattern. The `enable` signal makes the temporal activation explicit and would remain necessary for any variant supporting partial-matrix operation or pipelining.