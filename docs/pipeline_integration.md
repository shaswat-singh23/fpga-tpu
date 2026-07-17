# Pipeline Integration

## Overview

Top-level wiring for the full pipeline: `matrix_loader` → `feeder_sequencer` → `result_reader`. Gating logic ensures shared buffers (`a_full`/`b_full`, `results`) are not overwritten while still in use downstream.

## Gating

### `feeder_sequencer.start`

Assigned as `load_done && not_reading`. Both conditions must hold to trigger a new computation:
- `load_done`: matrices are loaded and ready
- `not_reading`: the previous computation's results have been fully read out

### `not_reading` latch

`read_done` from `result_reader` is a one-cycle pulse. To use it as a level condition, it is latched:

- Sets high on `read_done` pulse
- Clears when `feeder_start` fires (new computation begins)
- Defaults high after reset, so the very first computation is not blocked waiting for a nonexistent prior `read_done`

### `matrix_loader.consumed`

Wired to `calc_done` (the feeder's `done` output). This blocks `matrix_loader` from rearming and accepting new data until the feeder has finished reading `a_full`/`b_full`, protecting the input buffers from mid-computation overwrite.

## Verified Behavior

Two back-to-back computations with different input matrices produce correct outputs matching the golden model, with all gating boundaries holding correctly and no phantom writes to shared buffers.