# Benchmark results

All numbers measured on this machine (Alienware m16 R2, RTX 4070 Laptop 8 GB,
Core Ultra 7 155H, 15 GiB RAM).

Format: **decode tok/s** / **prefill tok/s**, average of N runs.

---

## 1. DSpark A/B — LFM2.5-**8B** target (24B still downloading)

Measured with `llama-server` (llama.cpp f174553e1, Ollama 0.40.8 bundled build) using a
fixed ~200-token prompt, `n_predict` 64, `temperature 0.1`, `top_k 50`,
`repeat_penalty 1.05`, `cache_prompt false`.

| config | runs | decode t/s | prefill t/s | note |
|---|---|---|---|---|
| `base` | 3 | **67.84** | 219.48 | baseline |
| `base_gpu2` | 2 | **76.05** | 136.61 | baseline, 2nd placement |
| `base_r2` | 3 | 72.56 | 233.34 | baseline, 3rd repeat |
| `base_cpu` | 3 | 26.98 | 59.24 | experts forced to CPU |
| `dspark_gpu` | 2 | 70.28 | 139.42 | DSpark, drafter on GPU |
| `dspark_n4` | 3 | 62.17 | 171.92 | DSpark, `--spec-draft-n-max 4` |
| `dspark_n6` | 3 | 57.76 | 227.91 | DSpark, n-max 6 |
| `dspark_n9` | 3 | **28.63** | 150.90 | DSpark, n-max 9 (trained block size) |
| `moecpu_base` | 3 | 43.69 | 116.84 | moe-cache + CPU experts, no draft |
| `moecpu_dspark_n4` | 3 | 40.41 | 107.51 | moe-cache + CPU experts + DSpark n4 |
| `moecpu_dspark_n6` | 3 | 30.41 | 105.08 | moe-cache + CPU experts + DSpark n6 |
| `moecpu_dspark_n9` | 3 | 22.37 | 81.56 | moe-cache + CPU experts + DSpark n9 |

### What this shows

1. **DSpark is NOT a win when the target already fits in VRAM.** `dspark_gpu` (70.28) is
   *slower* than `base_gpu2` (76.05). The drafter forward pass costs more than the
   verification saves when the target is not the bottleneck.
2. **`--spec-draft-n-max 9` is dramatically slower** (28.63 vs 67.84 baseline) — a ~2.4×
   *regression*. This is the trained block size, but a 9-token verify batch multiplies
   the expert-selection work. On this box, **n-max 4 is the only viable setting**, and
   even that is a net loss on an 8B target that fits in VRAM.
3. **The CPU-expert regime helps but still doesn't flip DSpark positive here**:
   `moecpu_base` 43.69 → `moecpu_dspark_n4` 40.41 (still a loss).
4. The mechanism is therefore **target-dependent**: speculative decoding only pays when
   the *target* forward is the bottleneck AND the drafter is cheap. On the 8B (target
   fully resident, 1.5B active) the target is fast, so the drafter dominates.

> **These are 8B numbers.** The 24B target is the case that matters — 2.45B active
> params with ~7.5 GB of experts in CPU RAM is a genuinely different regime, where a
> 9-token verify batch can share the same cold expert reads that a single token would.
> Re-run this matrix on the 24B before concluding.

### Caveat on the drafter/target pairing

The DSpark sidecar must match the target's tokenizer and shared embedding/LM head.
The worker verified this by extracting the head tensors from both
(`dspark_head.gguf` / `target_head.gguf`, 3 MB each) — a mismatch here produces
garbage output, not an error. **Always pair the 24B drafter with the 24B target.**

---

## 2. Recorded but not yet summarized

`/tmp/opencode/spec_ab/*.res*.json` holds the raw per-run records for the table above.

---

## 3. Still to measure (24B target)

| Sweep | Command |
|---|---|
| `--n-cpu-moe` | `./scripts/bench.sh sweep-n` |
| `--moe-cache-mib` | `./scripts/bench.sh sweep-cache` |
| KV type vs max context | `./scripts/bench.sh sweep-kv` |
| DSpark on the 24B | `./scripts/bench.sh bench-dspark` |
| Quality verification | `./scripts/bench.sh verify` |

The harness refuses to run with under 2 GB available RAM and kills the server between
runs.
