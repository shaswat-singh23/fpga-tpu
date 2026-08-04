# Accelerator Architecture Plan

Reference doc for the instruction-driven matrix accelerator redesign,
modeled on Google's TPU v1 (Jouppi et al., ISCA 2017).

Core design principle, from the TPU paper: "The goal was to run whole
inference models in the TPU to reduce interactions with the host CPU."

---

## ISA Specification

3-bit opcode, fixed-width 64-bit instruction word. Unused operand
fields are reserved/zero-padded per instruction type. CISC execution
model: instructions can occupy EXECUTE for thousands of cycles.

### Instructions

| Opcode | Mnemonic   | Operands               | Description |
|--------|------------|------------------------|-------------|
| 000    | LOAD_A     | ddr_addr, length       | PL pulls A from DDR into A_buf via AXI4 master |
| 001    | LOAD_B     | ddr_addr, length       | PL pulls B from DDR into B_buf via AXI4 master |
| 010    | MATMUL     | a_addr, b_addr, c_addr, length | Full i,j,k tile sweep with overlapped wavefronts; length = N (sets k-step count and pingpong toggle period) |
| 011    | STORE_C    | ddr_addr, length       | PL pushes C_buf to DDR via AXI4 master |
| 100    | ACTIVATE   | c_addr, length, mode   | Element-wise nonlinear on C_buf in place; mode selects function (0=ReLU, 1=sigmoid) |
| 101    | QUANTIZE   | c_addr (src), a_addr (dst), length | Scale/shift/clamp 32-bit C_buf values to 8-bit signed, write into A_buf |
| 110    | HALT       | -                      | Stop execution, signal done to PS |
| 111    | reserved   | -                      | - |

### Instruction Word Layout (64 bits)

```
[63:61] opcode      3 bits
[60:47] addr_1     14 bits  (ddr_addr for LOAD/STORE, a_addr for MATMUL, c_addr for ACTIVATE, c_addr/src for QUANTIZE)
[46:33] addr_2     14 bits  (b_addr for MATMUL, a_addr/dst for QUANTIZE, unused otherwise)
[32:19] addr_3     14 bits  (c_addr for MATMUL, unused otherwise)
[18:14] length      5 bits  (tile count per side: max 128/8 = 16)
[13:11] mode        3 bits  (ACTIVATE function select, unused otherwise)
[10:0]  reserved   11 bits
```

### Instruction Separation Rationale

LOAD_A/LOAD_B are separate so weights (B) can load once and be reused
across a batch of input samples (A), rather than reloading per sample.

MATMUL and ACTIVATE are separate since not every matmul needs
activation. The TPU paper makes the same separation.

QUANTIZE is separate from ACTIVATE since not every activated result
needs to be requantized for reuse as input, only intermediate layers
in a multi-layer network.

### Example Programs

Single-layer batched inference (3 samples, shared weights):
```
LOAD_B   weights_ddr_addr, 16
LOAD_A   sample_0_ddr_addr, 16
MATMUL   0, 0, 0, 16
ACTIVATE 0, 16, 0
STORE_C  result_0_ddr_addr, 16
LOAD_A   sample_1_ddr_addr, 16
MATMUL   0, 0, 0, 16
ACTIVATE 0, 16, 0
STORE_C  result_1_ddr_addr, 16
LOAD_A   sample_2_ddr_addr, 16
MATMUL   0, 0, 0, 16
ACTIVATE 0, 16, 0
STORE_C  result_2_ddr_addr, 16
HALT
```

Two-layer inference (C feeds back as A via QUANTIZE):
```
LOAD_B    layer1_weights_ddr, 16
LOAD_A    input_ddr, 16
MATMUL    0, 0, 0, 16
ACTIVATE  0, 16, 0
QUANTIZE  0, 0, 16
LOAD_B    layer2_weights_ddr, 16
MATMUL    0, 0, 0, 16
ACTIVATE  0, 16, 0
STORE_C   output_ddr, 16
HALT
```

---

## Architecture Overview

### Module Map

| Module              | Status     | Role |
|---------------------|------------|------|
| processing_element  | verified   | Dual-bank accumulator PE, signed arithmetic, per-diagonal pingpong/pingpongrst |
| systolic_array       | verified   | 8x8 PE mesh, enable/pingpong/pingpongrst all [2N-2:0] wide, [i+j] addressed |
| tile_bram           | verified   | Parameterized dual-port BRAM, 1-cycle registered read |
| gemm_sequencer      | verified in sim | Core compute engine: overlapped wavefronts, progressive tile loading, C_buf flush. Randomized sweep N=16-128 passes. |
| accelerator_top     | in progress | Top wrapper: A_buf, B_buf, C_buf, instruction BRAM, AXI4 master, AXI-Lite slave, gemm_sequencer |
| AXI4 master         | not started | PL-initiated DDR reads/writes for LOAD_A/LOAD_B/STORE_C |
| instruction fetch/decode | not started | Opcode decode, PC, dispatch |
| ACTIVATE hardware   | not started | Element-wise nonlinear on C_buf |
| QUANTIZE hardware   | not started | 32b to 8b scale/shift/clamp, C_buf to A_buf |

### Memory Map (MAX_N=128, batch=7)

| Buffer | Width | Depth | Total | Contents |
|--------|-------|-------|-------|----------|
| A_buf  | 64b   | 14336 | 112 KiB | 7 batch samples x N^2/8 rows each |
| B_buf  | 64b   | 2048  | 16 KiB  | 1 stationary weight matrix |
| C_buf  | 256b  | 14336 | 448 KiB | 7 batch results |
| Instr  | 64b   | 128   | 1 KiB   | Instruction program |
| Total  |       |       | ~590 KB | of 630 KB available |

### PS-PL Interface

| Interface      | Direction | Purpose |
|----------------|-----------|---------|
| AXI4 Master    | PL-DDR    | LOAD_A, LOAD_B, STORE_C |
| AXI-Lite Slave | PS-PL     | Instruction program writes, status/control registers |

### 4-Stage CISC Pipeline

1. FETCH: read instruction from instruction BRAM, advance PC
2. DECODE: extract opcode and operands, dispatch
3. EXECUTE: multi-cycle operation (MATMUL runs the full i,j,k sweep)
4. RETIRE: signal completion, advance pipeline

One instruction owns EXECUTE at a time. Instruction-level overlap is a
documented future optimization, not implemented.

### Key Design Decisions

CISC over RISC: MATMUL occupies EXECUTE for thousands of cycles,
matching the TPU paper's stated rationale for this workload class.

Overlapped wavefronts: enable, pingpong, and pingpongrst are all
per-diagonal, allowing different diagonals to be mid-accumulation on
different output tiles at once. Each diagonal's control signals are
delayed relative to the load front by exactly its own diagonal index,
mirroring how data already propagates through the array.

Separate A_buf/B_buf/C_buf, not unified: progressive tile loading
during compute needs simultaneous independent reads from A and B every
cycle. A single BRAM instance gives at most two ports; three separate
instances are required regardless of logical grouping.

Single HP port with internal steering (planned): one AXI4 master,
internal counter routes incoming beats to A_buf or B_buf sequentially.

---

## Verification

gemm_sequencer: randomized signed TB, every N from 16 to 128 in steps
of 8, checked element-by-element against a CPU golden model. All
cases pass. `sim/gemm_sequencer_tb.sv`.

tile_bram: isolated TB, write/read correctness, 1-cycle registered
read latency, independent-port behavior, same-address collision
behavior.

Not yet built: AXI4 master TB, instruction-level TB (multi-instruction
programs, batched inference sequences), ACTIVATE/QUANTIZE TBs,
randomized backpressure on the AXI4 master interface.

---

## Documented Non-Implementations

Pipeline hazard handling (forwarding, stalling between dependent
instructions): not implemented. The CISC execution model (one long
instruction at a time) does not generate the class of hazards RISC
forwarding solves.

Delay slots: the TPU paper describes explicit synchronization between
dependent instructions. No cross-instruction data hazard exists at
this scope (one instruction in EXECUTE at a time), so no mechanism is
needed.

Streaming-input systolic architecture: would require per-row
independent memory channels with temporally staggered delivery. The
production-scale approach, out of scope here.

Fill/drain utilization ceiling: average PE utilization within one
wavefront is N_array/(3*N_array-2), about 36.4% at N_array=8,
asymptoting to 33.3% as array size grows. Fixed structural property of
the diagonal-skew topology. The overlapped-wavefront design (built)
raises utilization by keeping multiple tiles in flight, but does not
change this per-wavefront ceiling. Parallels TPU paper Table 3
(6.3%-78.2% utilization gaps).