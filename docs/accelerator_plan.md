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
MATMUL    0, 0, 0, 8, 0                  ; C_buf base 0, any base works
ACTIVATE  0, 0, 1, 8, 0                  ; ReLU plus bias
STORE_C   layer1_out_ddr, 0, 8           ; optional, for debugging
QUANTIZE  0, 0, 0, 8, SHIFT_VAL          ; C_buf to B_buf, becomes layer 2's input
LOAD_A    layer2_weights_ddr, 0, 8       ; layer 2 weights, different from layer 1's
MATMUL    0, 0, 0, 8, 0
ACTIVATE  0, 0, 1, 8, 0
STORE_C   layer2_out_ddr, 0, 8
HALT
```

For a contraction dimension wider than one MATMUL call covers (layer
1's 784-wide input, K-tiled in chunks of 64, meaning 13 calls in the
MNIST demo), repeat the MATMUL line with different a_addr/b_addr per
K-chunk, the same c_addr every time, accumulate=0 on the first chunk
and 1 on the rest.

---

## Resolved: C_buf first-read address bug

Symptom, first seen in August: the first C_buf word of an operation
(the first drain word of tile[0][0]) came back wrong unless the C_buf
base address was the one value that happened to work. It was
originally blamed on a same-address dual-port BRAM collision inside
`tile_bram.sv`. That diagnosis was wrong. `tile_bram` was never the
problem, and neither was the result `gemm_sequencer` computed.

Root cause, in `accelerator_top`: STORE_C, ACTIVATE, and QUANTIZE each
present their first C_buf read address in their start cycle. The
`storing`/`activating`/`quantizing` latches that steer `c_raddr_mux`
are registered off the start pulse, so they go high one cycle later.
In that first cycle the mux still selected `gs_raddrC`, whatever
address the idle sequencer was parked on, so each unit read its word
0 from the wrong place. For STORE_C only the copy sent to DDR was
wrong. ACTIVATE and QUANTIZE wrote the bad word back (into C_buf and
B_buf), and from B_buf it spread to one full output column of the
next MATMUL.

Why the old workaround worked: the pre-pipelining sequencer computed
`raddrC` from its live `addrCoffset` and `tiles` inputs. During any
non-MATMUL instruction those decode to 0, which left the parked
address at `i_prev*8 + readfetch`, 63 after a tiles=8 MATMUL. Setting
every c_addr to N*8-1 = 63 made the requested address equal the
parked one. A coincidence, not a property of the BRAM.

Why it resurfaced: the pipelined sequencer latches its offsets and
parks at `cbase + readfetch`, the last word of the result. That never
equals the base, so no c_addr value hides the bug, and the workaround
stopped working on the 83.3 MHz build. It went unnoticed there at
first because the MNIST demo only compares accuracy counts and the
corruption is confined to one image.

Fix: the mux also selects each unit during its start cycle.

```systemverilog
assign c_raddr_mux = (quantizing || qz_start)  ? qz_raddrC :
                     (activating || act_start) ? act_raddrC :
                     (storing    || s_start)   ? store_raddr :
                                                 gs_raddrC;
```

The c_addr = N*8-1 rule is no longer required. Any C_buf base works,
including 0.

Validation: reproduced and fixed in a top-level simulation that runs
the MNIST instruction stream stage by stage against the C software
baseline (0 / 4096 mismatches at every stage, C_buf bases 0, 63, 200,
and 317, with and without stream backpressure), plus 180 random
back-to-back programs (tiles 1, 2, 4, 8, random A/B/C offsets,
accumulate chains of 1 to 3, no reset in between). On hardware, the
bitstream checker's five tests all pass at 0 / 4096 mismatches on the
fixed 83.3 MHz build, and the MNIST demo passes with every C_buf base
set to 0.

Lesson: every unit TB passed while this bug was live, because the bug
is in the wiring between units, not inside any one of them. It took a
top-level simulation to see it.

---

## Architecture Overview

### Module Map

| Module              | Status     | Role |
|---------------------|------------|------|
| processing_element  | verified on hardware | Dual-bank accumulator PE, signed arithmetic, per-diagonal pingpong/pingpongrst |
| systolic_array       | verified on hardware | 8x8 PE mesh, enable/pingpong/pingpongrst all [2N-2:0] wide, [i+j] addressed |
| tile_bram           | verified on hardware | Parameterized dual-port BRAM, registered read |
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

Clock: 83.3 MHz (12 ns). History: 62.5 MHz on the two-layer build,
dropped to 52.6 MHz after this BRAM resize, where the limit turned
out to be `gemm_sequencer`'s read-address generation (multiplies and
a carry chain feeding the BRAM address buses). Replacing that with
registered address counters brought it to 83.3 MHz. See
`docs/gemm_sequencer_design.md` and `docs/performance_analysis.md`.

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
  QUANTIZE handoff: 0 mismatches. First validated with the c_addr
  workaround, which the `c_raddr_mux` fix has since made unnecessary
  (see Resolved above).
- Bitstream checker on the fixed 83.3 MHz build: two-layer
  regression, accumulate, 3-chunk K-tile chain, high BRAM addresses,
  and instruction slots above 128 all pass at 0 / 4096 mismatches.
- Instruction memory addressing beyond the original 128-slot range,
  high-address BRAM access: both verified.

Simulation:
- `gemm_sequencer`: randomized signed TB, every N from 16 to 128 in
  steps of 8 (pre-accumulate version), plus a dedicated accumulate TB
  with different operands per call and a multi-tile trial. All cases
  pass. `sim/gemm_sequencer_tb.sv`.
- `tile_bram`: isolated TB, write/read correctness, registered read
  latency, independent-port behavior. The C_buf bug once attributed
  to this module was a top-level mux timing bug, see Resolved above.
- `quantize_unit`: 5-trial back-to-back TB, varying length/shift/
  offsets, no reset between runs, including length=1 and scale=0
  edge cases.

Not yet built: an `accelerator_top` testbench in `sim/` (the
top-level simulation that found the C_buf bug is not in the repo's
sim set), randomized backpressure testing on the DataMover
interface.

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