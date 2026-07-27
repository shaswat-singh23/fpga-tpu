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

A shared group counter (index) advances once both ports have accepted the current group's beat. Per-port one_accepted/two_accepted latches let the two lanes handshake independently within a group. The leading port deasserts its tvalid after acceptance and waits for the trailing port to catch up, rather than re-transmitting the same beat. This prevents duplicate emission under asymmetric backpressure. read_done asserts once the FSM has reached the end of the transfer.

Each port tracks its own `tvalid`/`tlast`/done state so one lane can finish slightly ahead of the other; `read_done` only asserts once both are done.

## Verification

Verification: covered by the full-pipeline testbench (sim/top_wrapper_tb.sv) with independent randomized backpressure on both m_axis_*_tready signals to expose asymmetric drain. Golden-model correctness is checked on hardware via CPU-side matmul in vitis/dma_driver.c.

## Performance

Read time: N²/4 beats. At N=8: 16 cycles (down from 64 with the original single-port interface).