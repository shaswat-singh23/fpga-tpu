# Systolic Array Design

## Overview

Instantiates N×N PEs in a grid, orchestrating output-stationary matrix multiplication. External data staggering (which PE receives which matrix element at which cycle) is handled entirely outside this module, by separate control/testbench logic — `systolic_array.sv` is purely structural: it wires PEs together and exposes staggered-input ports, but has no internal notion of timing or sequencing.

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

## Design Decisions

Output-stationary dataflow was chosen over weight-stationary — see `PE_design.md` for the full reasoning (weight reuse across many computations isn't applicable to this project's verification-against-random-matrices testing methodology, and output-stationary is simpler to implement correctly first).

The per-diagonal `enable` signal (rather than a single global enable) was added after recognizing that a global enable would cause PEs to begin accumulating before real data reached them, corrupting results with zero-valued products from idle inputs. Gating each diagonal's activation window ensures a PE only accumulates once its neighbors have actually propagated real operands to it.

`N` is parameterized to support scaling; `generate` blocks and wire-array indexing were designed to require no code changes when N changes, only parameter value changes. Verified correct at N=2 (hardcoded staggering) and N=4 (generalized, formula-driven staggering), with N=2 serving as a regression check before trusting the generalized N=4 logic.