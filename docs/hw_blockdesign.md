# DMA / PS-PL Integration

## Overview

Block design connects the Zynq PS to the accelerator pipeline via 4 AXI DMA engines, one per stream, each on an independent HP port.

## DMA Instances

| Instance | Direction | Channel | Feeds/From | HP Port |
|---|---|---|---|---|
| `axi_dma_0` | Read (MM2S) | matrix_loader `s_axis_a` | HP0 |
| `axi_dma_1` | Read (MM2S) | matrix_loader `s_axis_b` | HP1 |
| `axi_dma_2` | Write (S2MM) | result_reader `m_axis_one` | HP2 |
| `axi_dma_3` | Write (S2MM) | result_reader `m_axis_two` | HP3 |

All instances: Simple Mode (no scatter-gather), Memory Map/Stream Data Width = 64 bits, Max Burst Size = 16 (Zynq-7000 HP port native burst limit).

Control: shared AXI-Lite path from PS `M_AXI_GP0` through `axi_smc`, fanned out to all four DMA `S_AXI_LITE` ports.

## Result Buffer Layout (for PS software)

Results arrive in DDR as two separate buffers, one per DMA write channel. To reconstruct `results[N][N]` in row-major order, software must interleave the two buffers using the same group scheme as `result_reader`:

- Buffer from `axi_dma_2` (port one): linear indices `4k`, `4k+1`
- Buffer from `axi_dma_3` (port two): linear indices `4k+2`, `4k+3`

## Known Gaps

- Zynq-7000 HP ports are not cache-coherent. PS software must explicitly flush/invalidate cache around DMA buffers.
