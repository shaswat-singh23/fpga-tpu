# Performance

Perf notes for the current instruction-driven accelerator. The older
fixed-function N=8 design's numbers live in
`docs/archive/perf_optimization.md`, that's a different
architecture and a different metric (raw memory throughput, not
end-to-end inference), so it's kept separate rather than merged in
here.

## End-to-end result

Batched MNIST inference, 3-layer MLP (784 to 64 to 64 to 10),
batch=64, on PYNQ-Z2, 83.3 MHz build.

| | Accelerator | Software (same ARM core, -O3 NEON) |
|---|---|---|
| Total runtime | 1,013 us | 94,742 us |
| Speedup | about 93x | baseline |

Both sides ran the identical quantized int8 arithmetic, same trained
weights, same input batch. The only variable that changes is whether
the matmuls ran on the systolic array or as C on the ARM core. Both
classify 58 of the 64 images correctly.

The baseline is built at -O3 with NEON auto-vectorization on the
Cortex-A9. Against the same loop at the Vitis default -O0 (296,394
us) the ratio is about 293x, but that mostly measures an unoptimized
baseline, so 93x is the number to quote.

See `vitis/` for the driver code and `docs/MNIST_model.md` for how
the model gets to int8 in the first place.

## Clock history

| Build | Clock | MNIST runtime | Limiting path |
|---|---|---|---|
| Three-layer, batch=64 | 52.6 MHz | 1,567 us | `gemm_sequencer` read-address generation (multiplies and a carry chain in front of the BRAM address ports) |
| Pipelined address generation | 83.3 MHz | 1,013 us | Buffer BRAM output through the `a_mat`/`b_mat` bypass mux into the PE MAC |

Runtime tracked the clock closely (1.58x clock, 1.55x runtime), so
fixed PS and DataMover overhead is a small share of the total.

## Not yet profiled

The 1,013 us total hasn't been broken down into per-instruction or
per-stage timing (how much is LOAD, how much is the 13-chunk K-tile
accumulate chain, how much is ACTIVATE/QUANTIZE, how much is STORE_C)
for this specific 3-layer, 83.3 MHz build. Earlier per-instruction
numbers exist from a two-layer build at 62.5 MHz (before the batch=64
BRAM resize dropped the clock), but the clock and instruction count
have both changed since, so those aren't presented here as current.
Worth profiling for real if throughput optimization becomes a
priority.

## PE utilization

A single isolated systolic tile with nothing to overlap against
caps out around 36.4% average PE utilization at N_array=8 (fill and
drain cost, no neighbor to hide it behind). That number gets cited a
lot in systolic array literature, including the TPU paper, as the
structural cost of the diagonal-skew topology.

This design does not run at that number in practice. The
`gemm_sequencer` core overlaps wavefronts: the next tile's fill
starts while the current tile is still draining, using diagonals
that would otherwise sit idle. Getting the per-diagonal
`enable`/`pingpong`/`pingpongrst` timing right for this was the
hardest part of writing that module, but it means steady-state
utilization across any real chain of tiles, like the K-tile
accumulate chains or multi-layer inference this project actually
runs, reaches close to 100 percent. The 36.4% figure only shows up at
the very first and very last tile of a chain. Over a long chain that
cost is amortized down to negligible.

Measured with `sim/gemm_sequencer_perf.sv` (cycles from start to
done for one MATMUL, operands already in BRAM, result checked against
a golden model). Fill and drain cost a fixed 20 cycles regardless of
N.

| N | Cycles | Ideal | PE utilization | Sustained GOPS at 83.3 MHz |
|---|---|---|---|---|
| 16 | 84 | 64 | 76.2% | 8.12 |
| 32 | 532 | 512 | 96.2% | 10.26 |
| 64 | 4,116 | 4,096 | 99.5% | 10.61 |
| 128 | 32,788 | 32,768 | 99.9% | 10.66 |

Peak is 10.66 GOPS (64 PEs, one multiply and one add each per cycle).
These exclude the LOAD phase, so they are sustained GEMM throughput
with operands on chip, not end-to-end.

## Next, if revisited

Address-generation pipelining is done (52.6 to 83.3 MHz). The slowest
paths are now buffer BRAM output into the PE MAC. Two options,
neither built: an output register on A_buf/B_buf with a two-cycle
counter head start (cheap), or pipelining the PE itself with DSP
input and product registers and uniformly delayed control (the real
fix).

DAE (decoupled access-execute) is still future work. Real
per-instruction timing
from the earlier two-layer build (LOAD about 9 to 10 us each, MATMUL
about 66 us, STORE_C about 34 us at N=64) suggested MATMUL dominates
total time, which is worth confirming again on the current build
before deciding whether DAE is actually worth the added complexity.