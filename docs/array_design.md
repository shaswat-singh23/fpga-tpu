# Systolic Array Design

## Overview

Instantiates N×N PEs in a grid, orchestrating output-stationary matrix multiplication. External data staggering (which PE receives which matrix element at which cycle) is handled entirely outside this module, by separate control/testbench logic. `systolic_array.sv` is purely structural: it wires PEs together and exposes staggered-input ports, but has no internal notion of timing or sequencing.

## Interface

### Parameters
| Name | Default | Description |
|---|---|---|
| `N` | 4 | Array dimension (N×N PEs) |
| `DATA_WIDTH` | 8 | Matches PE parameter |
| `ACC_WIDTH` | 32 | Matches PE parameter |

### Ports
| Name | Direction | Width | Description |
|---|---|---|---|
| `clk` | input | 1 | Clock |
| `rst` | input | 1 | Synchronous reset |
| `enable` | input | 2N-1 | One bit per diagonal (d = i+j); high for N consecutive cycles starting at cycle d |
| `a_mat` | input | N × DATA_WIDTH | External A feed, one element per row, entering column 0 |
| `b_mat` | input | N × DATA_WIDTH | External B feed, one element per column, entering row 0 |
| `results` | output | N×N × ACC_WIDTH | Accumulated output matrix; results[i][j] = PE(i,j)'s final accumulator value |

## Connectivity

PEs are instantiated via a `generate` block over indices i (row) and j (column), 0 to N-1. Internal wire arrays `a_wire[0:N-1][0:N-1]` and `b_wire[0:N-1][0:N-1]` carry data between neighbors:

- `pe[i][j].a_out` connects to `pe[i][j+1].a_in` for j < N-1 (horizontal, A flows right)
- `pe[i][j].b_out` connects to `pe[i+1][j].b_in` for i < N-1 (vertical, B flows down)
- Boundary PEs (j=0) receive `a_in` directly from `a_mat[i]` (external) rather than from a neighbor wire
- Boundary PEs (i=0) receive `b_in` directly from `b_mat[j]` (external) rather than from a neighbor wire
- Rightmost column's `a_out` and bottom row's `b_out` are unconnected (no downstream neighbor)

Each `pe[i][j]`'s `result` output connects directly to `results[i][j]`.

## Data Flow Control

Staggering logic lives in the testbench (`sim/systolic_array_tb.sv`), not in this module, since this module has no synthesized notion of "which cycle" a value belongs to. The testbench:

1. Maintains a `cycle_count` counter, incrementing each clock cycle after reset deasserts
2. Generates per-diagonal `enable` bits via a `generate` block: `enable[d] = (cycle_count >= d) && (cycle_count <= d+N-1)`, since diagonal d = i+j becomes active at cycle d and remains active for N cycles (the length of the dot product being accumulated)
3. Feeds staggered `a_mat`/`b_mat` values via an `always_comb` block: row i receives `a_full[i][cycle_count-i]` starting at cycle i, column j receives `b_full[cycle_count-j][j]` starting at cycle j; both default to 0 outside their active window

This logic is explicitly a verification-only stand-in for what would become a real synthesizable "feeder/sequencer" module if this project is extended toward physical hardware implementation.

## Verification

Verified correct at N=2, N=4, N=8, and N=16 against golden numpy `A @ B` reference:
- N=2 with hardcoded per-cycle staggering as a regression baseline (all-1s matrices, then distinct values to expose indexing bugs)
- N=4 with the generalized formula-driven staggering (reproduces N=2's result before validating the general approach)
- N=8 and N=16 spot-checked against Python golden model (full hand-verification impractical at these sizes)

## Synthesis Analysis

Synthesized to Xilinx Artix-7 (xc7a200tfbg676-2) at 100MHz target clock. Two synthesis variants were compared: Vivado's default primitive mapping (LUT-based multiplication) vs. explicit DSP inference via a module-level `(* use_dsp = "yes" *)` attribute on the PE.

### LUT-based version (default synthesis)

| N | PEs | LUTs (% of 134,600) | FFs (% of 269,200) | DSPs | Bonded IOB (% of 400) | WNS @ 100MHz |
|---|---|---|---|---|---|---|
| 4 | 16 | 1,391 (1.03%) | 704 (0.26%) | 0 | 585 (146.25%) | 3.333 ns |
| 8 | 64 | 5,563 (4.13%) | 2,944 (1.09%) | 0 | 2,193 (548.25%) | 3.354 ns |
| 16 | 256 | 22,267 (16.54%) | 12,032 (4.47%) | 0 | 8,481 (2120.25%) | 3.354 ns |

### DSP-inferred version

| N | PEs | LUTs | FFs (% of 269,200) | DSPs (% of 740) | Bonded IOB (% of 400) | WNS @ 100MHz |
|---|---|---|---|---|---|---|
| 4 | 16 | 0 | 64 (0.02%) | 16 (2.16%) | 585 (146.25%) | 8.284 ns |
| 8 | 64 | 0 | 1,280 (0.48%) | 64 (8.65%) | 2,321 (580.25%) | 8.284 ns |
| 16 | 256 | 0 | 6,656 (2.47%) | 256 (34.59%) | 8,737 (2184.25%) | 8.284 ns |

### Key findings

**1. Resource utilization scales cleanly with N² (PE count) in both versions.** Each 2× increase in N produces almost exactly 4× resource growth (LUTs in LUT-based version, DSPs in DSP-based version). Confirms no unexpected super-linear cost from control logic or interconnect overhead. The design is as resource-efficient as its architecture allows.

**2. Timing is flat regardless of N in both versions** (3.333 → 3.354 → 3.354 ns for LUT-based, 8.284 ns across all three sizes for DSP-based). This confirms the architectural property that systolic arrays' nearest-neighbor-only interconnect keeps critical path length independent of array size. The maximum achievable clock frequency depends only on per-PE logic depth, not on how many PEs exist. This makes systolic arrays fundamentally more scalable than architectures with global or broadcast interconnect, where longer routes emerge as N grows.

**3. DSP inference dramatically improves both resource footprint and timing.** The `(* use_dsp = "yes" *)` attribute maps each PE's multiply-accumulate to a single DSP48E1 block, absorbing multiplication logic AND accumulator registers into dedicated hardware. Results: LUT usage drops to zero, FF count drops ~10×, and WNS at 100MHz improves from ~3.3ns to 8.284ns, meaning critical path drops from ~6.7ns to ~1.7ns, roughly a 4× improvement in achievable clock frequency (theoretical maximum ~588 MHz vs ~150 MHz for the default LUT-based version). Vivado does not infer DSPs by default for 8-bit operands, likely because its heuristic considers small-width multipliers competitive when implemented in LUTs but for scaling to larger arrays, explicit DSP inference is clearly the better choice.

**4. Different resources become the scaling constraint in each version.** LUT-based version's dominant resource is LUT count; extrapolating, this chip could support up to approximately N=~50 before exhausting LUTs. DSP-based version's dominant compute resource is DSP48 blocks; with 740 available and one per PE, the hard scaling limit is approximately **N=27** on this target chip (256 DSPs at N=16 = 34.59%, so N=27 would need 729 DSPs = 98.5%).

**5. Bonded IOB overflow persists regardless of primitive choice** (146.25% at N=4 in both versions, scaling quadratically to over 2000% at N=16). This confirms the direct-parallel-output interface is a fundamental architectural limitation, independent of how the compute logic is synthesized. Physical implementation at any meaningful N would require a bus-based readout interface (e.g., AXI-Stream) to sequentially transmit result values through a narrow physical bus rather than exposing them all simultaneously as parallel pins. This motivates AXI-Stream interfacing as a natural extension of this project.

**6. At a tighter clock constraint of 6.5ns (~154MHz), the LUT-based version begins failing timing** (WNS = -0.147 ns, 78 of 640 endpoints violating). The DSP-based version, by contrast, meets timing comfortably at 6.5ns and would only start failing at approximately 1.7ns period (~590 MHz), making it the appropriate choice for any high-frequency target.

## Design Decisions

Output-stationary dataflow was chosen over weight-stationary; see `PE_design.md` for the full reasoning.

The per-diagonal `enable` signal (rather than a single global enable) was added after recognizing that a global enable would cause PEs to begin accumulating before real data reached them, corrupting results with zero-valued products from idle inputs. Gating each diagonal's activation window ensures a PE only accumulates once its neighbors have actually propagated real operands to it.

`N` is parameterized to support scaling; `generate` blocks and wire-array indexing were designed to require no code changes when N changes, only parameter value changes. Verification confirmed correct behavior across N ∈ {2, 4, 8, 16}, and synthesis analysis confirmed both linear-resource scaling and constant critical-path timing across the same range.