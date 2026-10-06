# FPGA TPU

An instruction-driven matrix accelerator in SystemVerilog, targeting a
Zynq-7000 SoC. Custom on-chip GEMM engine with its own CISC ISA, PL-side
DDR access via Xilinx DataMover, and overlapped systolic wavefronts,
architecturally modeled on Google's TPU v1 (Jouppi et al., ISCA 2017).

Companion piece to [CUDA SGEMM Optimization](https://github.com/shaswat-singh23/cuda-matmul).

## Status

Fully validated end to end on real PYNQ-Z2 silicon, hardware through
a complete batched MNIST inference demo.

The `gemm_sequencer` rewrite (instruction-driven, on-chip GEMM engine
with overlapped wavefronts and a PL-side AXI4 master via DataMover)
replaced the original fixed-function design and is bit-exact on
hardware. That includes a full three-layer inference pipeline
(MATMUL, ACTIVATE with bias, QUANTIZE, and manually-tiled accumulate
for contraction dimensions wider than one MATMUL call covers),
running a real 3-layer MLP trained from scratch, quantized to int8,
and deployed entirely on-chip.

Result: on a 64-image test batch at 83.3 MHz, the accelerator runs
the full three-layer inference in 1,013 &micro;s versus 94,742
&micro;s for the same arithmetic as -O3 NEON-vectorized C on the same
ARM core. Same weights, same batch, same quantized arithmetic, only
the accelerator-vs-not variable changes. About 93x speedup. Both
sides classify 58 of the 64 images correctly, in line with the
model's roughly 91 percent accuracy on held-out data.

Correctness on the current build: the hardware regression checker is
bit-exact (0 / 4096 mismatches on all five tests). The three-layer
MNIST pipeline was checked bit-for-bit against a Python golden model
on the earlier pre-pipelining build. On the current build the demo
compares classification results against the C baseline, and they
agree.

See `docs/accelerator_plan.md` for the full ISA spec, instruction
encoding, memory map, and design rationale, including the root cause
and fix for an earlier C_buf addressing bug (see below).

## Architecture

![accelerator_top data flow](images/accelerator_dataflow.svg)
![vivado block design](images/vivado_block_design.png)
Full block diagram of PS and PL; accelerator_top encapsulates PL
![Resource utilization](images/resource_util_simple.png)
Resource utilization for full hardware design running inference

- ISA: 9-instruction CISC set (LOAD_A, LOAD_B, LOAD_BIAS, LOAD_SCALE,
  MATMUL, STORE_C, ACTIVATE, QUANTIZE, HALT), 64-bit fixed-width
  instructions, 7 opcodes reserved for future use. MATMUL is a single
  instruction whose EXECUTE stage runs the full i,j,k tile sweep, with
  an accumulate flag for instruction-stream-managed contraction tiling.
- PEs: 64 output-stationary MAC units, dual accumulator banks per PE,
  one DSP48E1 per PE (8-bit signed times 8-bit signed to 32-bit
  signed accumulate).
- Overlapped wavefronts: enable, pingpong, and pingpongrst are per-diagonal ([2N-2:0] wide, [i+j] addressed) rather than globally broadcast, so different diagonals can be mid-accumulation on different output tiles simultaneously. A naive systolic array wastes most of its cycles on fill and drain (about 36% average PE utilization at this array size). Overlapping tiles this way gets steady-state utilization close to 100 percent for any real chain of tiles, which is most of what this accelerator actually runs.
- On-chip memory: A_buf/B_buf/C_buf/bias_buf/scale_buf sized for the
  MNIST demo workload (a 784→64→64→10 MLP at batch=64, with the final
  layer's output padded to a full 64-wide tile to match the batch
  dimension). See the memory map in `docs/accelerator_plan.md` for
  exact depths.
- PS-PL interface: PL-initiated DDR access via Xilinx DataMover (no
  hand-written AXI4 master, no PS-driven DMA) and one AXI-Lite slave
  (`newip`) for the PS to write the instruction program and read back
  debug state.
- ACTIVATE (ReLU plus optional per-neuron bias) and QUANTIZE
  (per-neuron scale/shift/clamp, feeding a quantized layer's output
  directly back in as the next layer's input) are both implemented
  and hardware-verified.

See `docs/accelerator_plan.md` for the full ISA spec, instruction
encoding, memory map, and design rationale.

## Resolved Issue: C_buf first-read address

Earlier versions documented an unresolved C_buf bug, attributed to a
BRAM collision inside `tile_bram.sv`, with a fixed-base-address
workaround. The real cause was in `accelerator_top`: the C_buf read
mux switched over to STORE_C, ACTIVATE, or QUANTIZE one cycle after
that unit issued its first read, so word 0 came from the wrong
address. Fixed with a one-statement change to the mux, and the
workaround is no longer needed. See "Resolved: C_buf first-read
address bug" in `docs/accelerator_plan.md` for the full write-up.

## Repository Layout

```
bd/         Block design regeneration script (design_1.tcl)
docs/       Design notes and architecture plan
images/     Diagrams referenced from this README
rtl/        SystemVerilog source
sim/        Testbenches
mnist/      From-scratch training, quantization export, and golden model
vitis/      Bare-metal ARM application (accelerator driver + software baseline)
```

## Verification

Hardware (PYNQ-Z2):
- Full three-layer MNIST inference pipeline: hardware and the C
  software baseline classify the demo batch identically (58 of 64).
  Matched the Python golden model bit-for-bit on the earlier
  pre-pipelining build (see Status above).
- About 93x speedup over -O3 NEON-vectorized C on the same ARM core,
  same quantized int8 arithmetic, same input batch, at 83.3 MHz.
- Regression checker (two-layer pipeline, accumulate, K-tile chain,
  high BRAM addresses, instruction slots above 128): 0 / 4096
  mismatches on every test.
- Accumulate/K-tiling, including the full accumulate to ACTIVATE to
  QUANTIZE handoff: 0 mismatches.
- Instruction memory addressing beyond the original slot count, high
  BRAM address access: verified.

Software (numpy, from scratch):
- MLP trained from scratch, no framework, on MNIST, 784→64→64→10,
  full-batch gradient descent with L2 bias regularization to keep
  quantized bias magnitudes within int8 range at zero accuracy cost.
- Bespoke quantization exporter: per-neuron weight scales, solved
  per-layer (M, shift) requantization parameters via a brute-force
  shift sweep.
- Golden model reproducing hardware's exact int8/int32 fixed-point
  arithmetic in numpy. This is what the hardware result above is
  checked against.

Simulation:
- `gemm_sequencer`: randomized signed TB sweeping every supported N
  (16-128, step 8) pre-accumulate, plus a dedicated accumulate TB.
  All cases pass. `sim/gemm_sequencer_tb.sv`.
- `tile_bram`: isolated TB, write/read correctness, registered read
  latency, independent-port behavior.
- `quantize_unit`: 5-trial back-to-back TB, no reset between runs,
  including length=1 and scale=0 edge cases.

Not yet built: an `accelerator_top` testbench in `sim/` (the C_buf
bug above was invisible to every unit TB), randomized backpressure
testing on the DataMover interface.

## History

The instruction-driven `gemm_sequencer` redesign described above has
been merged into `main` and is the current design. It replaced an
earlier fixed-function 8x8 design: four PS-side AXI DMAs, verified
bit-exact on hardware, with a software tiling driver reaching about
16.9 MB/s at 64x64 after two rounds of measured optimization
(tile-major memory layout, tile-local accumulation, see
`docs/archive/perf_optimization.md`).

- 64 DSP48E1 slices (one per PE, 29% of Zynq-7020's 220), about 5700
  LUTs, about 7300 FFs, 100 MHz.
- N=8 fixed array size, 8-bit unsigned operands.

## Build

Requires Vivado 2024.2+ and Vitis Unified IDE. The current design on
`main` is fully hardware-validated (first hardware-verified milestone
tagged `v2.0-axilite-hardware-working`). Formal build documentation
is still pending.