# TurboQuant on LFM2.5 — validated

**Verdict: `ktq*`/`vtq*` (llama-tq) is SAFE and useful at head_dim=64, provided you
pass `--no-tq-deferred-k`.** This corrects the initial pessimistic read of
TurboQuant's own docs.

---

## The binaries

| Fork | Linux CPU | Linux **CUDA** | Verdict |
|---|---|---|---|
| **LL4nc33/llama-tq** v2026.10.19 | ✅ | ✅ **sm89** | **use this** |
| TheTom/llama-cpp-turboquant | ✅ | ❌ none | builds only from source (36 GB+ ptxas RAM documented) |
| TorranceTech/llama-cpp-turboquant | ❌ no releases | ❌ | unusable |
| openalchemy/llama.cpp | ❌ no releases | ❌ | unusable |
| upstream ggml-org/llama.cpp | — | — | PR #21089 (`tbq3_0`/`tbq4_0`) **closed unmerged**; only the Hadamard rotation (#21038) + WHT kernels (#22631/#23615/#23687) landed |

```
https://github.com/LL4nc33/llama-tq/releases/download/v2026.10.19/llama-v2026.10.19-bin-ubuntu-cuda-12.8-sm89-x64.tar.gz
```
159 MB, sha256 `58355b65647bf3c589ffaf9f6a9c02c0d378952aeb21a60e5807be8e4f4cbe8d` ✔

Sibling assets: `cuda-12.8-sm75`, `cuda-12.8-sm86`, `cuda-12.9-sm120`, `vulkan`, `x64` (CPU).

### The AVX-512 SIGILL (and the fix)
The official CUDA archive's `libggml-cpu.so` is compiled **with AVX-512** (its CI host
had it) — 10,026 `zmm` references. The Core Ultra 7 155H has **no AVX-512**
(`avx avx2 avx_vnni fma f16c bmi2 gfni`), so the archive dies at startup:

```
Illegal instruction (core dumped)
vmovdqa32 0xfe6a9(%rip),%zmm0      # inside ggml_cpu_init
```

The whole file is AVX-512, so it cannot be patched. **Fix without compiling:** take the
*same release's* portable AVX2 CPU backend (`libggml-cpu-haswell.so` from the CPU-only
archive of the same tag — same commit `b807e5c`, same ggml 0.9.11 ABI) and swap it in.
`libggml.so` only needs `ggml_backend_cpu_reg` from it, so the ABI matches.

Reproducible: `scripts/setup-llama-tq.sh` (idempotent, verifies sha256).

```bash
export LD_LIBRARY_PATH=$ROOT/merged:$CUDART
export GGML_BACKEND_PATH=$ROOT/merged
$ROOT/merged/llama-server --version
# llama-tq v2026.10.19 / version 10083 (b807e5cff)
$ROOT/merged/llama-server --list-devices
# CUDA0: NVIDIA GeForce RTX 4070 Laptop GPU (7782 MiB, 7240 MiB free)   sm_89 ✔
```

---

## head_dim = 64 — auto-downgrade, and it is safe

llama.cpp refuses the block-128 trellis variants at d=64 and silently downgrades to the
Hadamard+codebook `_1` class:

```
head size 64 is not a multiple of the ktq3_3s block (128), using ktq3_1
```

So the trellis path is **never** used on LFM2.5 — you get the safer class. Verified on
CPU and CUDA, **no crash, no WHT/CLT degradation**.

Type aliases that parse: `ktq3`→`ktq3_3s`, `vtq3`→`vtq3_2s`, `ktq4`→`ktq4_3s`,
`vtq4`→`vtq4_2s`.

### Quality evidence (8B proxy, identical arch `lfm2moe` and head_dim 64)
Temperature 0, same prompts, side-by-side against a `q8_0` control:

| prompt | q8_0 control | turbo3 | turbo4 |
|---|---|---|---|
| "Pride and Prejudice" author/year | "Jane Austen, 1813" ✅ | identical ✅ | identical ✅ |
| primes + `17+24` | `2, 3, 5, 7, 11 / 17+24 = 41` ✅ | identical ✅ | identical ✅ |
| Python reverse-string function | correct ✅ | identical ✅ | identical ✅ |
| **20,844-token needle** (`ORANGE-7741-MOTH`) | recalled ✅ | **recalled ✅** | — |

### ⚠️ The gotcha: `--no-tq-deferred-k` is REQUIRED
Without it the ktq types allocate an **f16 K staging buffer** and the "compressed" KV
ends up **bigger** than q8_0:

```
CUDA0 KV buffer = 36.75 MiB (turbo3, staging on)  vs  25.50 MiB (q8_0 control)
```
With `--no-tq-deferred-k`: turbo3 = 102 MiB vs q8_0 = 204 MiB at 32 K ctx. ✅

---

## Measured footprint and speed (8B proxy, 6 attention layers, head_dim 64)

KV size:

| KV type | @32 K ctx | @128 K ctx |
|---|---|---|
| f16 | 384 MiB | — |
| **q8_0** | **204 MiB** | **816 MiB** |
| q4_0 | 108 MiB | — |
| **turbo3 (ktq3+vtq3, `--no-tq-deferred-k`)** | **102 MiB** | **408 MiB** |
| turbo4 | 120 MiB | — |
| turbo2 | 72 MiB | — |

→ **turbo3 = 2.0× smaller than q8_0 at 128 K ctx.**

Speed:

| config | GPU decode | CPU decode |
|---|---|---|
| `q8_0/q8_0` (control) | 135.6 t/s | **25.4 t/s** |
| `ktq3/vtq3 --no-tq-deferred-k` | **136.6 t/s** | 22.3 t/s (−12 %) |
| `ktq3/vtq3` (staging on) | 134.5 t/s | 22.3 t/s |
| `q8_0/vtq3` (**V-only turbo**) | 133.5 t/s | **7.9 t/s (−69 %) ⚠️** |

Prefill (20 K tokens, layers split CPU/GPU): control 1698 t/s vs turbo3 1063 t/s —
**turbo prefill is slower when layers sit on CPU.**

### Rules
- ✅ `ktq3`/`vtq3` + `--no-tq-deferred-k` — safe, 2× smaller, GPU-neutral.
- ❌ **Never `q8_0` K + turbo V** if any layers are CPU-resident → 3× slower CPU decode.
- Prefer turbo on **K and V together**.

---

## Invocation for LFM2.5-24B

```bash
export LD_LIBRARY_PATH=$ROOT/merged:$CUDART
export GGML_BACKEND_PATH=$ROOT/merged
$ROOT/merged/llama-server \
  -m <24b blob> \
  -ngl 99 --n-cpu-moe 22 -c 131072 -fa on -t 8 -tb 8 \
  -ctk ktq3 -ctv vtq3 --no-tq-deferred-k \
  --jinja --host 127.0.0.1 --port 19977 --no-webui
```

Helper: `scripts/run-llama-tq.sh <model.gguf> [port] [ctx] [n_cpu_moe]`
(omit `n_cpu_moe` to let `--fit on` auto-place).

---

## llama-tq's two gaps

- **No `--moe-cache-mib`** — removed in llama-tq on 2026-10-09 ("no gain in our setups").
  That lever lives in the upstream/Ollama build.
- **No `draft-dspark`** — the DSpark path is `#if 0`'d out in `src/models/dflash.cpp`
  and `COMMON_SPECULATIVE_TYPE_DRAFT_DSPARK` is not in the fork's enum.

→ **llama-tq is an alternative KV layer, not a replacement for the Ollama/upstream runner.**
Use the Ollama-bundled llama-server for `--moe-cache-mib` and DSpark; use llama-tq when
KV size is the binding constraint.

---

## Unverified on the 24B (stated plainly)

The 24B blob was not available when this was tested, so `--n-cpu-moe` fit and full-offload
behaviour are **unverified** on 24B. 13.58 GB of weights vs 7.24 GB free VRAM ⇒ ~6.4 GB
must be RAM-resident, and only ~5–6 GiB of RAM was available alongside 26 GB of swap.
**Swap thrash is the real risk for the 24B — not the KV type.**

---

## Fallback if turbo is undesirable

`-ctk q8_0 -ctv q8_0` (135.6 t/s GPU, best CPU speed, 204 MiB @32 K) or
`-ctk q4_0 -ctv q4_0` (108 MiB, 24.2 t/s CPU, quality ≈ q8_0 per the TurboQuant tables).
