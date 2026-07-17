# Matrix Loader Design

## Overview

Receives A and B matrices over two independent AXI-Stream slave ports and writes them into `a_full`/`b_full` for the feeder to consume. Two ports (rather than one shared stream) enable future concurrent loading and early-start optimization.

## Interface

### Parameters
| Name | Default | Description |
|---|---|---|
| `N` | 8 | Matrix dimension |
| `DATA_WIDTH` | 8 | Element width |

### Ports
| Name | Direction | Width | Description |
|---|---|---|---|
| `clk`, `rst` | input | 1 | Clock, synchronous reset |
| `s_axis_a_tvalid`, `s_axis_a_tready`, `s_axis_a_tdata`, `s_axis_a_tlast` | mixed | 1/1/DATA_WIDTH/1 | AXI-Stream slave port for A |
| `s_axis_b_*` | mixed | same | AXI-Stream slave port for B |
| `consumed` | input | 1 | Feeder finished with `a_full`/`b_full`; safe to rearm |
| `a_full`, `b_full` | output | N×N × DATA_WIDTH | Loaded matrices |
| `load_done` | output | 1 | Both matrices fully received |

## Behavior

Each port maintains an independent counter (`a_count`, `b_count`) that increments on each accepted transfer (`tvalid && tready`) and writes incoming `tdata` into the corresponding cell (row-major indexing). The counter freezes at `TOTAL-1` and `_done` latches high once the full matrix is received. `tready = !_done`, so no further data is accepted once a matrix is complete.

`load_done = a_done && b_done`. Reset of counters and done flags is gated on `consumed`, not on `load_done` itself, so the module holds its "loaded" state until the feeder explicitly signals it has consumed the data.

Internal `a_frame_err`/`b_frame_err` flags catch `tlast` mismatches (early or missing). Currently unobservable outside the module; might revisit for error handling.

## Verification

 Full pipeline testbench (`sim/top_wrapper_tb.sv`) verifies two consecutive computations back-to-back with correct rearm timing.