# Accelerator Architecture Plan

Reference doc for the instruction-driven matrix accelerator redesign,
modeled on Google's TPU v1 (Jouppi et al., ISCA 2017).

Core design principle, from the TPU paper: "The goal was to run whole
inference models in the TPU to reduce interactions with the host CPU."

Status: hardware fully validated on PYNQ-Z2 silicon, through a
complete batched MNIST inference demo. Two-layer and three-layer
pipelines are both bit-exact on real hardware. See the Module Map and
Verification sections below for current status.

---

## ISA Specification

4-bit opcode, fixed-width 64-bit instruction word. Fields are NOT
uniform across opcodes: LOAD-family instructions and MATMUL/ACTIVATE/
QUANTIZE use different bit layouts of the same 64-bit word. This is
deliberate (CISC allows per-opcode reinterpretation) but means the
layout must be read per-instruction-class, not assumed uniform. CISC
execution model: instructions can occupy EXECUTE for thousands of
cycles.

Opcode widened from 3 to 4 bits early on (each opcode's own reserved
region absorbed the extra bit, no real operand field shrank), to
leave headroom for instructions added later rather than exhausting
the encoding space.

### Instructions

| Opcode | Mnemonic   | Operands               | Description |
|--------|------------|-------------------------|-------------|
| 0000   | LOAD_A     | ddr_addr, bram_addr, length | PL pulls A from DDR into A_buf via DataMover |
| 0001   | LOAD_B     | ddr_addr, bram_addr, length | PL pulls B from DDR into B_buf via DataMover |
| 0010   | MATMUL     | a_addr, b_addr, c_addr, tiles, accumulate | Full i,j,k tile sweep with overlapped wavefronts. tiles = tile count per side. accumulate adds into existing C_buf contents instead of overwriting, for contraction dimensions wider than one MATMUL call covers |
| 0011   | STORE_C    | ddr_addr, bram_addr, length | PL pushes C_buf to DDR via DataMover |
| 0100   | ACTIVATE   | c_addr, bias_addr, bias_en, length, mode | Element-wise nonlinear on C_buf in place, with an optional per-neuron bias add before the nonlinearity. mode 0 is ReLU. Sigmoid is reserved but not implemented, any nonzero mode falls through to a plain bias-add pass-through |
| 0101   | QUANTIZE   | c_addr (src), b_addr (dst), scale_addr, length, shift | Per-neuron scale/shift/clamp of 32-bit C_buf values to 8-bit signed, written into B_buf, not A_buf (see note below) |
| 0110   | HALT       | -                       | Stop execution, signal done to PS |
| 0111   | LOAD_BIAS  | ddr_addr, bram_addr, length | PL pulls per-neuron int8 bias values into bias_buf |
| 1000   | LOAD_SCALE | ddr_addr, bram_addr, length | PL pulls per-neuron uint8 scale (M) values into scale_buf |
| 1001 - 1111 | reserved | -                  | 7 opcodes free for future instructions, e.g. on-chip argmax |

QUANTIZE writes to B_buf, not A_buf. Under the weights=A, inputs=B
convention, QUANTIZE's output becomes the next layer's input, which
belongs in B_buf. Writing to A_buf would need a transpose. This also
lines up with C_buf's column-major-within-tile layout, so the copy
into B_buf needs no reshaping at all.

### Instruction Word Layout: LOAD_A / LOAD_B / LOAD_BIAS / LOAD_SCALE / STORE_C (64 bits)

```
[63:60] opcode       4 bits
[59:28] ddr_addr    32 bits  (DDR source for LOAD, DDR destination for STORE)
[27:14] bram_addr   14 bits  (destination buffer address for LOAD, C_buf source for STORE)
[13:9]  length       5 bits  (tile count)
[8:0]   reserved     9 bits
```

Destination buffer isn't a field, it's determined by opcode alone
(0000=A_buf, 0001=B_buf, 0111=bias_buf, 1000=scale_buf), decoded into
an internal destination-select signal in `bram_adapter`.

### Instruction Word Layout: MATMUL (64 bits)

```
[63:60] opcode       4 bits
[59:46] a_addr      14 bits
[45:32] b_addr      14 bits
[31:18] c_addr      14 bits
[17:13] tiles        5 bits  (tiles-per-side, sets M=K=N=tiles*8 for this call)
[12]    accumulate   1 bit   (1 = add into existing C_buf, 0 = overwrite)
[11:0]  reserved    12 bits
```

### Instruction Word Layout: ACTIVATE (64 bits)

```
[63:60] opcode       4 bits
[59:46] c_addr      14 bits
[45:32] bias_addr   14 bits
[31]    bias_en      1 bit   (1 = add bias_buf[bias_addr + tile-row] before the nonlinearity)
[30:18] reserved    13 bits
[17:13] length       5 bits
[12:10] mode         3 bits  (0=ReLU, sigmoid deferred)
[9:0]   reserved    10 bits
```

### Instruction Word Layout: QUANTIZE (64 bits)

```
[63:60] opcode       4 bits
[59:46] c_addr (src) 14 bits
[45:32] b_addr (dst) 14 bits
[31:18] scale_addr  14 bits
[17:13] length       5 bits
[12:8]  shift         5 bits  (shared right-shift for the whole call)
[7:0]   reserved     8 bits
```

Per lane: out = clamp((C_buf_value * scale_buf[neuron_tile]) >>> shift,
-128, 127). scale_buf holds one unsigned uint8 M value per neuron.

### Instruction Word Layout: HALT (64 bits)

```
[63:60] opcode       4 bits
[59:0]  unused      60 bits
```

### Bit-position note

Bit 12 is reinterpreted per opcode (MATMUL's accumulate flag vs the
top bit of ACTIVATE's mode). Safe since only one opcode's
interpretation is ever active per instruction, but it has no single
universal meaning. Always read it in the context of the opcode's own
layout table above.

### Instruction Separation Rationale

LOAD_A/LOAD_B are separate so weights can load once and get reused
across a batch of input samples, rather than reloading per sample.

MATMUL and ACTIVATE are separate since not every matmul needs
activation. The TPU paper makes the same separation. ACTIVATE and
QUANTIZE are likewise separate from each other, since not every
activated result needs requantizing, only intermediate layers in a
multi-layer network. The final layer's raw accumulator output goes
straight to STORE_C for host-side argmax.

LOAD_BIAS and LOAD_SCALE are separate from LOAD_A/LOAD_B because bias
and scale are per-neuron, not per-tile matrices. They're much smaller
and load into their own small dedicated buffers (bias_buf/scale_buf).

MATMUL's accumulate flag lets the instruction stream manually tile a
contraction dimension wider than one MATMUL call can cover: run
several MATMULs against different K-slices with the same c_addr,
accumulate=0 on the first chunk (overwrite), accumulate=1 on the rest
(add into the existing partial sum). This is instruction-stream-
managed tiling, not hardware-managed. The ISA provides the primitive,
the instruction stream provides the loop.

### Example: two-layer inference, real weights per layer

```
LOAD_A    layer1_weights_ddr, 0,  8      ; layer 1 weight tile into A_buf
LOAD_B    input_ddr,          0,  8      ; input vector(s) into B_buf
LOAD_BIAS layer1_bias_ddr,    0,  1
LOAD_SCALE layer1_scale_ddr,  0,  1
MATMUL    0, 0, C_ADDR, 8, 0             ; C_ADDR: see Known Issue below
ACTIVATE  C_ADDR, 0, 1, 8, 0             ; ReLU plus bias
STORE_C   layer1_out_ddr, 0, 8           ; optional, for debugging
QUANTIZE  C_ADDR, 0, 0, 8, SHIFT_VAL     ; C_buf to B_buf, becomes layer 2's input
LOAD_A    layer2_weights_ddr, 0, 8       ; layer 2 weights, different from layer 1's
MATMUL    0, 0, C_ADDR, 8, 0
ACTIVATE  C_ADDR, 0, 1, 8, 0
STORE_C   layer2_out_ddr, 0, 8
HALT
```

For a contraction dimension wider than one MATMUL call covers (layer
1's 784-wide input, K-tiled in chunks of 64, meaning 13 calls in the
MNIST demo), repeat the MATMUL line with different a_addr/b_addr per
K-chunk, the same c_addr every time, accumulate=0 on the first chunk
and 1 on the rest.

---

## Known Issue: accumulate and C_buf addressing workaround

There's an unresolved hardware bug where certain C_buf accesses at
address 0 corrupt the first drain word, most likely a same-address
dual-port BRAM collision inside `tile_bram.sv`. Not root-caused. Two
fix attempts in that file didn't resolve it, see project notes if
revisiting this.

Current workaround, required in every instruction stream: for any
tiles=N (N*8-wide) operation, every c_addr-family operand that touches
C_buf, meaning MATMUL's c_addr, ACTIVATE's c_addr, QUANTIZE's c_addr,
and STORE_C's bram_addr when reading C_buf, must use c_addr=N*8-1, not 0.
This is safe because C_buf's physical address port is narrower than
the address signals feeding it, so any offset wraps modulo C_buf's
depth the same way for every consumer, as long as every step in a
chain uses the same base. Verified end to end (13-call accumulate
chain, then ACTIVATE, then QUANTIZE, then layer 2 MATMUL) with zero
mismatches using this rule.

This is a workaround, not a fix. Revisit `tile_bram.sv`'s collision
handling and `processing_element.sv` (never reviewed during the
original investigation) after higher-priority work is done.

---

## Architecture Overview

### Module Map

| Module              | Status     | Role |
|---------------------|------------|------|
| processing_element  | verified on hardware | Dual-bank accumulator PE, signed arithmetic, per-diagonal pingpong/pingpongrst |
| systolic_array       | verified on hardware | 8x8 PE mesh, enable/pingpong/pingpongrst all [2N-2:0] wide, [i+j] addressed |
| tile_bram           | verified, known issue | Parameterized dual-port BRAM. See Known Issue above |
| gemm_sequencer      | verified on hardware | Core compute engine: overlapped wavefronts, progressive tile loading, C_buf flush, accumulate/K-tiling |
| activate_unit       | verified on hardware | Element-wise ReLU plus optional per-neuron bias, in place on C_buf |
| quantize_unit       | verified on hardware | Per-neuron scale/shift/clamp, C_buf to B_buf, pipelined for timing closure |
| accelerator_top     | verified on hardware | Top wrapper: A_buf/B_buf/C_buf/bias_buf/scale_buf/instruction BRAM, DataMover-based AXI4 master, AXI-Lite slave (`newip`), full instruction dispatch |
| AXI4 access (DataMover) | verified on hardware | PL-initiated DDR reads/writes for LOAD-family and STORE_C, via Xilinx DataMover IP instead of a hand-written master |
| instruction fetch/decode | verified on hardware | Opcode decode, PC, dispatch (`instruction_unit`) |

### Memory Map (current build: 3-layer MLP, batch=64, tiles=8 throughout)

Sizing here is workload-specific, tuned for a 784→64→64→10 MLP at
batch=64, not a generic MAX_N/batch-N design. Every buffer's depth is
justified on its own rather than derived from one shared size.

| Buffer     | Width | Depth | Contents |
|------------|-------|-------|----------|
| A_buf      | 64b   | 7680  | All three layers' weights, resident at once (13 K-chunks for layer 1, 1 chunk each for layers 2 and 3) |
| B_buf      | 64b   | 6656  | Largest single layer's input (layer 1's 13 K-chunks). Layer 2 and 3's inputs are written here by QUANTIZE, reusing the same space once layer 1's reads are done |
| C_buf      | 256b  | 512   | One tile-cube's worth of scratch space, reused across layers |
| bias_buf   | 64b   | 128   | Per-neuron int8 biases for all three layers (real need is 10 tile-rows) |
| scale_buf  | 64b   | 128   | Per-neuron uint8 QUANTIZE scale values (real need is 8 tile-rows) |
| Instr      | 64b   | 512   | Instruction program |

Clock: 50 MHz. Dropped from an earlier 62.5 MHz after this BRAM
resize violated WNS at 62.5 MHz. The bottleneck both times was BRAM
address-bus net delay, not logic depth.

### PS-PL Interface

| Interface      | Direction | Purpose |
|----------------|-----------|---------|
| AXI4 (DataMover) | PL-DDR  | LOAD-family instructions, STORE_C |
| AXI-Lite Slave (`newip`) | PS-PL | Instruction program writes, debug readback, status/control registers |

### 4-Stage CISC Pipeline

1. FETCH: read instruction from instruction BRAM, advance PC
2. DECODE: extract opcode and operands, dispatch
3. EXECUTE: multi-cycle operation (MATMUL runs the full i,j,k sweep)
4. RETIRE: signal completion, advance pipeline

One instruction owns EXECUTE at a time. Instruction-level overlap
(DAE) is a documented future optimization, not implemented.

### Key Design Decisions

CISC over RISC: MATMUL occupies EXECUTE for thousands of cycles,
matching the TPU paper's stated rationale for this workload class.

Overlapped wavefronts: `enable`, `pingpong`, and `pingpongrst` are all
per-diagonal, allowing different diagonals to be mid-accumulation on
different output tiles at once. Each diagonal's control signals are
delayed relative to the load front by exactly its own diagonal index,
mirroring how data already propagates through the array.

Separate A_buf/B_buf/C_buf, not unified: progressive tile loading
during compute needs simultaneous independent reads from A and B
every cycle. A single BRAM instance gives at most two ports, so
separate instances are needed regardless of logical grouping.

C_buf is column-major within tile, changed from an earlier row-major
layout. One 256-bit word holds one full input vector's 8-neuron
output slice. This lets QUANTIZE copy C_buf to B_buf directly with no
transpose, and simplified ACTIVATE's bias handling since bias_buf's 8
lanes line up 1:1 with C_buf's 8 lanes with no per-lane broadcast
needed.

Single access path via DataMover with internal steering: LOAD/STORE
instructions route through `bram_adapter`'s destination mux instead
of a hand-rolled multi-channel master.

---

## Verification

Hardware (PYNQ-Z2, real silicon):
- Full two-layer pipeline (LOAD to MATMUL to ACTIVATE to STORE_C to
  QUANTIZE to MATMUL to ACTIVATE to STORE_C): 0 mismatches per layer,
  batch=64.
- Full three-layer MNIST inference pipeline: hardware output matches
  a Python golden model bit-for-bit on the demo batch. Model accuracy
  on held-out data is around 91 percent, see `mnist/` for training
  and evaluation details.
- Accumulate/K-tiling, including the full accumulate to ACTIVATE to
  QUANTIZE handoff: 0 mismatches, using the addressing workaround
  documented above.
- Instruction memory addressing beyond the original 128-slot range,
  high-address BRAM access: both verified.

Simulation:
- `gemm_sequencer`: randomized signed TB, every N from 16 to 128 in
  steps of 8 (pre-accumulate version), plus a dedicated accumulate TB
  with different operands per call and a multi-tile trial. All cases
  pass. `sim/gemm_sequencer_tb.sv`.
- `tile_bram`: isolated TB, write/read correctness, registered read
  latency, independent-port behavior. Does not currently catch the
  hardware collision issue noted above. Sim's behavioral RAM model
  doesn't reproduce the real primitive's collision semantics.
- `quantize_unit`: 5-trial back-to-back TB, varying length/shift/
  offsets, no reset between runs, including length=1 and scale=0
  edge cases.

Not yet built: randomized backpressure testing on the DataMover
interface, a simulation model that reproduces the C_buf collision
issue.

---

## Documented Non-Implementations

Pipeline hazard handling (forwarding, stalling between dependent
instructions): not implemented. The CISC execution model, one long
instruction at a time, doesn't generate the class of hazards RISC
forwarding solves.

Delay slots: no cross-instruction data hazard exists at this scope
(one instruction in EXECUTE at a time), so no mechanism is needed.

DAE (Decoupled Access-Execute): deferred, not rejected. Real hardware
timing measured (N=64, 62.5 MHz build): LOAD_A about 9 to 10 us,
LOAD_B about 9 to 10 us, MATMUL about 66 us, STORE_C about 34 us.
Worth revisiting the DAE question with this real data rather than an
earlier unmeasured guess. Double-buffered C banks was the original
plan if it comes back up.

Streaming-input systolic architecture: would need per-row independent
memory channels with temporally staggered delivery. Out of scope
here.

Fill and drain utilization, single isolated tile: average PE
utilization within one wavefront with no neighboring tile to overlap
against is N_array/(3*N_array-2), about 36.4% at N_array=8,
asymptoting to 33.3% as array size grows. Fixed structural property
of the diagonal-skew topology, for that specific case. Parallels TPU
paper Table 3 (6.3% to 78.2% utilization gaps).

Overlapped wavefronts change this in practice, not just on paper.
This was the hard part of writing `gemm_sequencer`, getting the
per-diagonal `enable`/`pingpong`/`pingpongrst` timing right so that
the next tile's fill starts while the current tile is still draining,
using diagonals that would otherwise sit idle. In steady state, any
real chain of tiles such as the K-tile accumulate chains or
multi-layer inference this project actually runs, utilization reaches
close to 100 percent. The 36.4% figure only applies at the very first
and very last tile of a chain, where there's genuinely no neighbor on
one side. Over a long chain that one-time ramp cost gets amortized
down to negligible.

Sigmoid activation: ACTIVATE's mode field reserves an encoding for
it, but only ReLU is implemented. Planned approach, not built: clip
the input window and use it as a BRAM address into a precomputed
lookup table. Not needed for the current MNIST demo, ReLU throughout,
argmax handled host-side.