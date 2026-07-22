# Pipeline Integration

## Overview

Top-level wiring for the full pipeline: `matrix_loader` → `feeder_sequencer` → `result_reader`, coordinated by `pipeline_ctrl`. Gating logic ensures shared buffers (`a_full`/`b_full`, `results`) are not overwritten while still in use downstream.

## `pipeline_ctrl`

Standalone module owning the gating logic between the three pipeline stages.

### Ports
| Name | Direction | Description |
|---|---|---|
| `clk`, `rst` | input | Clock, synchronous reset |
| `load_done` | input | From `matrix_loader` |
| `calc_done` | input | From `feeder_sequencer` |
| `read_done` | input | From `result_reader` |
| `feeder_start` | output | To `feeder_sequencer.start` |
| `loader_consumed` | output | To `matrix_loader.consumed` |

### Behavior

`feeder_start = load_done && read_consumed`. `read_consumed` is an internal latch: sets high on `read_done`'s one-cycle pulse, clears when `feeder_start` fires, defaults high after reset so the first computation isn't blocked waiting on a nonexistent prior `read_done`. Will need adjustment in future for pipelining to be possible.

`loader_consumed` is a direct passthrough of `calc_done`. Once the feeder has finished consuming `a_full`/`b_full`, the loader is safe to rearm.

## Verified Behavior

Two back-to-back computations with different input matrices produce correct outputs matching the golden model, with all gating boundaries holding correctly and no phantom writes to shared buffers.