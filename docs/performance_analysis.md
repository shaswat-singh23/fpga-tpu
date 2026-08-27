# Performance

Perf notes for the current instruction-driven accelerator. The older
fixed-function N=8 design's numbers live in
`docs/archive/perf_optimization_n8_design.md`, that's a different
architecture and a different metric (raw memory throughput, not
end-to-end inference), so it's kept separate rather than merged in
here.

## End-to-end result

Batched MNIST inference, 3-layer MLP (784 to 64 to 64 to 10),
batch=64, on PYNQ-Z2.

| | Accelerator | Software (same ARM core) |
|---|---|---|
| Total runtime | 1,646 us | 296,187 us |
| Speedup | about 180x | baseline |

Both sides ran the identical quantized int8 arithmetic, same trained
weights, same input batch. The only variable that changes is whether
the matmuls ran on the systolic array or as a plain C loop on the ARM
core. Output matched a Python golden model bit-for-bit on both sides.

See `mnist/vitis/` for the driver code and `docs/quantization_pipeline.md`
for how the model gets to int8 in the first place.

## Not yet profiled

The 1,646 us total hasn't been broken down into per-instruction or
per-stage timing (how much is LOAD, how much is the 13-chunk K-tile
accumulate chain, how much is ACTIVATE/QUANTIZE, how much is STORE_C)
for this specific 3-layer, 50 MHz build. Earlier per-instruction
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

## Next, if revisited

DAE (decoupled access-execute) and further pipelining were both
flagged as future work rather than built. Real per-instruction timing
from the earlier two-layer build (LOAD about 9 to 10 us each, MATMUL
about 66 us, STORE_C about 34 us at N=64) suggested MATMUL dominates
total time, which is worth confirming again on the current build
before deciding whether DAE is actually worth the added complexity.