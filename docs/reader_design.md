# Result Reader Design

## Overview

Streams `results` out over two independent AXI-Stream master ports, interleaved. Two ports support parallel drain across two DMA/HP paths.

## Interface

### Parameters
| Name | Default | Description |
|---|---|---|
| `N` | 8 | Matrix dimension |
| `ACC_WIDTH` | 32 | Accumulator width |

### Ports
| Name | Direction | Width | Description |
|---|---|---|---|
| `clk`, `rst` | input | 1 | Clock, synchronous reset |
| `start_read` | input | 1 | Begin streaming |
| `m_axis_one_tvalid`, `m_axis_one_tready`, `m_axis_one_tdata`, `m_axis_one_tlast` | mixed | 1/1/ACC_WIDTH×2/1 | Port one, 2 elements packed per beat |
| `m_axis_two_*` | mixed | same | Port two |
| `results` | input | N×N × ACC_WIDTH | Source array |
| `read_done` | output | 1 | Both ports finished |

## Interleave Scheme

Elements are grouped in linear (row-major) sets of 4. Within each group of 4 (indices `4k, 4k+1, 4k+2, 4k+3`):
- Port one carries elements `4k`, `4k+1`
- Port two carries elements `4k+2`, `4k+3`

Little-endian packing within each beat: lower element index in the lower bits.

## Behavior

Single shared group counter (`index`) drives both ports — a group only advances once both ports have consumed it. This couples the two lanes: a stall on either port blocks both from advancing. Accepted tradeoff, since total throughput is bound by the slower lane regardless of indexing independence.

Each port tracks its own `tvalid`/`tlast`/done state so one lane can finish slightly ahead of the other; `read_done` only asserts once both are done.

## Verification

Isolated testbench drives `results` directly, checks fire count and `tlast` count per port against golden values.

## Performance

Read time: N²/4 beats. At N=8: 16 cycles (down from 64 with the original single-port interface).