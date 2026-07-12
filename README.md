# FPGA TPU

Parameterized systolic array matrix multiplier implemented in SystemVerilog, targeting simulation-verified correctness against a C++ golden model. Third paradigm in a high-performance matmul series alongside CPU and CUDA GPU implementations.

## Motivation

Following [CUDA SGEMM Optimization](https://github.com/shaswat-singh23/cuda-matmul), this project explores matrix multiplication at the hardware architecture level, implementing the physical compute pipeline directly in RTL rather than scheduling threads on fixed hardware.

## Status

Work in progress. Core systolic array design underway. See commit history for progress.

## Planned Scope

- 4×4 systolic array (output-stationary dataflow), parameterized for scaling to 8×8/16×16
- Verification against C++ golden model
- Vivado synthesis analysis (timing, resource utilization)
- Stretch: TPU-adjacent wrapper modules (instruction decode, activation unit)

## Hardware and Environment

- **Simulator:** Vivado (WebPACK, native Windows)
- **Target device (future physical):** TBD