# Systolic Array Design

## Overview

Instantiates N x N PEs, wiring them into the diagonal-wavefront
grid. Purely structural: no internal timing or sequencing logic.
That lives in `gemm_sequencer` (see `gemm_sequencer_design.md`).

## Interface

### Parameters
| Name | Default | Description |
|---|---|---|
| `N` | 8 | Array dimension (N x N PEs) |
| `DATA_WIDTH` | 8 | Signed, matches PE |
| `ACC_WIDTH` | 32 | Signed, matches PE |

### Ports
| Name | Direction | Width | Description |
|---|---|---|---|
| `clk`, `rst` | input | 1 | Clock, synchronous reset |
| `enable` | input | 2N-1 | One bit per diagonal (d = i+j) |
| `pingpong` | input | 2N-1 | One bit per diagonal, bank select |
| `pingpongrst` | input | 2N-1 | One bit per diagonal, clears the inactive bank |
| `a_mat` | input | N x DATA_WIDTH | External A feed, entering column 0 |
| `b_mat` | input | N x DATA_WIDTH | External B feed, entering row 0 |
| `results1` | output | N x N x ACC_WIDTH | Bank 0 accumulators |
| `results2` | output | N x N x ACC_WIDTH | Bank 1 accumulators |

## Connectivity

Structural, unchanged from the original design: `a_out`/`b_out`
chains wire each PE to its right and bottom neighbor, boundary PEs
take `a_mat`/`b_mat` directly. `enable[d]`, `pingpong[d]`, and
`pingpongrst[d]` all route to every PE on diagonal `i+j == d`.

## Data Flow Control

`enable`, `pingpong`, and `pingpongrst` are all generated externally
by `gemm_sequencer`, per-diagonal, timed to the diagonal's own delay
relative to the load front. This module has no notion of cycle count.

## Design Decisions

**Per-diagonal `pingpong`/`pingpongrst`** replace what was originally
a single global signal, once the array moved to overlapping wavefronts
across separate output tiles. A global toggle cannot separate PEs that
have finished a tile from PEs still mid-accumulation on it, since
different diagonals reach their own completion point at different
cycles. Propagating the bank-select signal per diagonal reuses the
same `[i+j]` addressing already used for `enable`.

**`results1`/`results2` replace the single `results` output** to
expose both accumulator banks, since at any moment one bank holds the
tile currently accumulating and the other holds the previous tile's
finished value awaiting drain. `gemm_sequencer` selects between them
per diagonal when flushing to `C_buf`.

Output-stationary dataflow, N parameterization, and the resource/timing
scaling analysis from the original design (LUT vs. DSP inference,
critical path independent of N, IOB overflow motivating a bus-based
readout) are unchanged and still apply; see the archived version for
the full synthesis tables.