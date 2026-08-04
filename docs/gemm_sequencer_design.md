# GEMM Sequencer Design

## Overview

The MATMUL execution unit. Owns `systolic_array` and autonomously
sweeps the full i,j,k tile space for one MATMUL instruction: streaming
A and B tiles in from BRAM, driving overlapped wavefronts, and
draining finished output tiles to `C_buf`. Absorbs what would
otherwise be a separate feeder/sequencer module, since the continuous
overlapped pipeline has no natural per-tile start/stop boundary.

## Interface

### Parameters
| Name | Default | Description |
|---|---|---|
| `MAX_N` | 128 | Largest supported logical matrix dimension |
| `DATA_WIDTH` | 8 | Signed operand width |
| `ACC_WIDTH` | 32 | Signed accumulator width |
| `ARRAY_N` | 8 | Physical array size |

### Ports
| Name | Direction | Width | Description |
|---|---|---|---|
| `clk`, `rst`, `start` | input | 1 | Clock, reset, one-cycle start pulse |
| `tiles` | input | 5 | N/ARRAY_N for this MATMUL |
| `rdataA`, `rdataB` | input | signed 64 | BRAM read data |
| `addrAoffset`, `addrCoffset` | input | 14 | Base addresses into A_buf, C_buf |
| `raddrA` | output | 14 | A_buf read address |
| `raddrB` | output | 11 | B_buf read address |
| `waddrC` | output | 13 | C_buf write address |
| `weC` | output | 1 | C_buf write enable |
| `wdataC` | output | signed 256 | C_buf write data, one row (8 elements) |
| `done` | output | 1 | Asserted after the final tile is flushed |

## Behavior

Two fronts run concurrently, offset by the array's fill/drain latency.

**Load front.** `stagger` (0-7) cycles through one BRAM row per cycle,
staggered per row into local `a_full`/`b_full` registers via
`a_full[ia][3'(stagger-ia)]`-style indexing, matching the wavefront's
own consumption rate. `i,j,k` track tile position; `raddrA`/`raddrB`
are computed one cycle ahead of consumption (`_next` values), so BRAM
data is ready exactly when needed. `load_complete` (all counters at
their terminal value) freezes `i,j,k`; `stagger` keeps running so the
array's remaining diagonals can still drain real data out of
`a_full`/`b_full` after the counters stop.

**Control generation.** `enable`, `pingpong`, `pingpongrst` are all
`[2*ARRAY_N-2:0]`, one bit per diagonal, matching `systolic_array`'s
per-diagonal ports.
- `enable[d]` opens at diagonal d's own start and closes based on
  `end_count`, a counter that starts once `load_complete` fires so the
  array's trailing diagonals get the extra cycles they need to finish.
- `pingpong[d]` reflects the new tile's parity once the load front has
  reached diagonal d (`newtilecycle >= d`), otherwise the outgoing
  tile's parity (`j_parity_prev`). `newtilecycle` resets at each tile
  boundary (`j` changing, or once via `loaded_pulse` at the final
  transition).
- `pingpongrst[d]` clears diagonal d's inactive bank one cycle after
  its row is read during drain, plus a tail pulse for the diagonals
  past the array's last row.

**Drain front.** Runs `ARRAY_N` cycles behind the load front's tile
boundary. Reads one row (`drain_row`) of the finished tile per cycle
from whichever bank `pingpong[drain_row]` indicates, packs 8 elements
into `wdataC`, and writes to `C_buf` at the address derived from the
*captured* tile coordinates (`i_prev`/`j_prev`, latched at the tile
boundary, since the load front has already moved on by the time the
drain runs).

**Completion.** `drain_counter` counts completed drains; `done` fires
once it reaches `tiles*tiles` and the final drain (`drain_consumed`)
has landed, not on any cycle-count coincidence.

## Verification

Randomized signed TB (`sim/gemm_sequencer_tb.sv`) sweeps every
supported N from 16 to 128 in steps of 8, checked element-by-element
against a CPU golden matmul. All cases pass.

## Design Decisions

**Overlapped wavefronts, not one tile at a time.** The array can
process a new output tile's first cycles while the previous tile is
still draining, since different diagonals reach their own toggle
point at different cycles. This was the direct motivation for making
`enable`/`pingpong`/`pingpongrst` per-diagonal rather than global.

**One-cycle-ahead address generation** (`raddrA`/`raddrB` computed
from `_next` state) avoids a bypass mux on the data-consuming side;
`a_full`/`b_full` are always exactly one BRAM latency ahead of what
the wavefront needs, uniformly, without a special case at startup.
The one place a genuine special case remains is the final tile's
drain, where `stagger` is frozen and `a_mat`/`b_mat` need their own
indexing branch to keep advancing through rows already loaded but not
yet consumed.

**`i_prev`/`j_prev` capture, not live `i`/`j`, for C_buf addressing.**
By the time a tile's drain runs, the load front has already advanced
to the next tile; writing to `C_buf` at the *current* `i,j` would
target the wrong address.

**`done`'s timing was a real bug, not a planned decision, and the fix
itself had a second bug.** An early draft derived `done` from
`load_complete` and `drain_consumed`. That coincidentally fired on the *third* tile's drain at N=16, one tile early, since `drain_consumed` fired after every tile drain, and at systolic array size of 8, lines up with the condition for `load_complete`. The  fix was a `drain_counter` compared against `tiles*tiles`, gating `done` on the *actual* final drain rather than simply checking if draining was done.