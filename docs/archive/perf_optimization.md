# Tiled Matmul — Perf Notes

64x64, 512 tiles, ARM Global Timer, bit-exact vs golden model.

| | Baseline | Current |
|---|---|---|
| Total runtime | 10096 us | 7774 us |
| Throughput | 13.0 MB/s | 16.9 MB/s |
| extract | 2428 us | 172 us |
| accumulate | 2376 us | 1817 us |

Fix 1 — tile-major layout (memcpy instead of per-elem extract)
Fix 2 — tile-local accumulation (flush once/tile not once/k-step)

Combined: -23% runtime, +30% throughput

Bottleneck now: DMA arm (AXI-Lite writes), 41% of total.
~1-2% of theoretical HP-port bandwidth.

Next: scatter-gather DMA, hardware k-accumulation, APM. Deferred until engine finalized.