# FPGA TPU

An 8×8 systolic array matrix multiplier in SystemVerilog, running end-to-end
on a Zynq-7000 SoC. Custom RTL, custom AXI-Stream IP, dual-DMA result
readback, verified against a CPU-side golden model on real hardware.

Companion piece to [CUDA SGEMM Optimization](https://github.com/shaswat-singh23/cuda-matmul):
matrix multiplication at the hardware architecture level, implementing the
compute pipeline directly in RTL rather than scheduling threads on fixed
GPU hardware.

## Architecture

```mermaid
flowchart LR
    DDR[("PS DDR")]
    DDR -->|HP0| DMA_A[axi_dma_0 MM2S]
    DDR -->|HP1| DMA_B[axi_dma_1 MM2S]
    DMA_A -->|A stream| ML[matrix_loader]
    DMA_B -->|B stream| ML
    ML -->|a_full, b_full| FS["feeder_sequencer<br/>+ systolic_array<br/>(64 PEs, 1 DSP/PE)"]
    FS -->|results 2048b| RR[result_reader]
    RR -->|port 1| DMA_C1[axi_dma_2 S2MM]
    RR -->|port 2| DMA_C2[axi_dma_3 S2MM]
    DMA_C1 -->|HP2| DDR
    DMA_C2 -->|HP3| DDR
```

- **PEs**: 64 output-stationary MAC units, one DSP48E1 per PE (8-bit × 8-bit → 32-bit accumulate).
- **Dataflow**: skewed diagonal wavefront via per-diagonal `enable` gating. 3N-2 = 22 cycles per matmul.
- **I/O**: 4× AXI DMA in Simple mode over Zynq HP ports — 2 for input matrices, 2 for interleaved 32-elements/cycle result readback.
- **Software**: bare-metal C on ARM Cortex-A9, cache-coherent DMA setup, golden-model verification.

See `docs/` for module-level design notes.

## Status

**Working on hardware.** The 8×8 systolic array matches a CPU golden model bit-exactly, and an ARM-side tiling driver now runs larger matmuls by decomposing into 8×8 tiles with PS-side accumulation: 64x64 (512 tiles) passes bit-exact against a CPU golden model at ~16.9 MB/s effective throughput. Per-tile timing breakdown (ARM global timer) showws the pipeline is latency-bound on per-tile DMA setupt, not bandwidth-bound. See `docs/` for the optimization writeup. Board: PYNQ-Z2 (XC7Z020-1CLG400C).

Resource utilization:
![Resource Utilization](images/resource_utilization.png)
64 DSP48E1 slices (one per PE, 29% of Zynq-7020's 220), ~5700 LUTs, ~7300 FFs. Clock: 100 MHz (FCLK_CLK0).

## Repository Layout

```
bd/         Block design regeneration script (design_1.tcl)
docs/       Per-module design notes
rtl/        SystemVerilog source
sim/        Testbenches
vitis/      Bare-metal ARM application
```

## Build

Requires Vivado 2024.2+ and Vitis Unified IDE. From a fresh clone:

1. Create a new Vivado RTL project targeting `xc7z020clg400-1`.
2. Add all files in `rtl/` as design sources.
3. Package each of `matrix_loader`, `feeder_sequencer`, `pipeline_ctrl`, `result_reader` as a Vivado IP. Set the IP output directory as your IP repository.
4. In the Tcl console: `source ./bd/design_1.tcl`. This regenerates the block design.
5. Validate design, generate output products, run synthesis + implementation + bitstream.
6. Export XSA (`File → Export → Export Hardware`, Select "include bitstream/binary", check bitstream, leave binary unchecked).
7. In Vitis: create a new platform component from the XSA, then a new application component. Import `vitis/dma_driver.c` as a source file.
8. Program the bitstream, run the application. Expected output ends with `PASS: all 256 elements match golden model`.

## Verification

- **Simulation**: `sim/top_wrapper_tb.sv` — full-pipeline testbench with independent randomized backpressure on both S2MM ports, timeout on deadlock, cycle-count and TLAST checks, verified via waveform inspection.
- **Hardware**: automated CPU-side golden matmul in `vitis/dma_driver.c`, run at end-of-transfer against DMA'd result buffers.
- **Tiled hardware**: 64×64 matmul via 512× tiled 8×8 hardware calls with PS-side accumulation, verified against a CPU golden model bit-exact on hardware. Per-tile ARM Global Timer instrumentation identified DMA re-arm and result-accumulation overhead as the dominant costs (not DMA bandwidth); two targeted software fixes (tile-major memory layout, tile-local accumulation) cut total runtime ~24% with no RTL changes.

![DMA results verified](images/dma_success.png)

## Known Limitations

- N=8 only. N=16 would require 256 DSPs, exceeding the 220 available on Zynq-7020.
- 8-bit unsigned operands with a 32-bit accumulator. Max accumulator value at N=8 is 8 × 255² ≈ 5.2 × 10⁵, well within 2³²; larger K or signed operands would require re-checking the bound.
- SG_LENGTH_WIDTH set to 8 bits on all DMAs; sufficient for N=8 but would need widening for larger single-shot transfers.

## Roadmap

- AXI Performance Monitor integration for per-port bandwidth breakdown (current numbers are ARM-side wall-clock; APM would isolate HP-port-level traffic).
- Scatter-gather DMA to reduce per-tile descriptor-arm overhead (currently the largest single cost bucket).
- Hardware k-accumulation in RTL to cut result-readback round trips.
- Timing closure pushed above 100 MHz.
- FPGA vs. CPU throughput comparison on the same Cortex-A9.