# Operations runbook

Everything measured on this machine. Commands are copy-pasteable.

---

## Current state

| Service | Endpoint | Store | Notes |
|---|---|---|---|
| `ollama.service` (system) | `127.0.0.1:11434` | `/usr/share/ollama/.ollama/models` | v0.32.9 → upgrade pending sudo |
| `ollama-rootless.service` (user) | `127.0.0.1:11435` | `~/.ollama/models` | **v0.40.8, has the MoE offload env** |
| `llm-edge-setup-autopush.timer` | — | — | commits + pushes this repo every 10 min |

**Use the rootless instance for MoE models.** Only it has `LLAMA_ARG_N_CPU_MOE` and
`GGML_OP_OFFLOAD_MIN_BATCH` set, without which a 24B MoE on 8 GB VRAM falls back to
whole-layer CPU offload and is far slower.

```bash
export OLLAMA_HOST=127.0.0.1:11435
```

---

## Why `--n-cpu-moe` works in Ollama at all

Ollama has no `num_cpu_moe` option — PR #16688 was **closed unmerged**. But:

1. Ollama serves GGUF via a `llama-server` subprocess.
2. `llm/llama_server.go` → `SetupLlamaServerCommandEnv` → `cmd.Env = os.Environ()`.
3. llama-server reads `LLAMA_ARG_*` for every flag.

So `LLAMA_ARG_N_CPU_MOE=22` in the service environment reaches the runner. Verified:
the var appears in the llama-server child's `/proc/<pid>/environ`, and
`LLAMA_ARG_OVERRIDE_TENSOR` via env produces llama-server's tensor-override warning.
Env and CLI `--n-cpu-moe 20` gave byte-identical buffer splits.

### Environment variables that work this way

| Env var | Effect |
|---|---|
| `LLAMA_ARG_N_CPU_MOE` | expert FFN of layers 0..N-1 → CPU |
| `LLAMA_ARG_OVERRIDE_TENSOR` | regex tensor placement (comma-separated, one flag) |
| `LLAMA_ARG_MOE_CACHE_MIB` | VRAM LRU cache of host-resident experts |
| `LLAMA_ARG_CACHE_TYPE_K` / `_V` | KV cache dtype |
| `LLAMA_ARG_FLASH_ATTN` | `on`/`off`/`auto` |
| `LLAMA_ARG_SPEC_TYPE` | `draft-dspark` / `draft-dflash` / … |
| `LLAMA_ARG_FIT` | auto layer placement |
| `LLAMA_ARG_LAZY_MODE` | on-demand tensor row reads |
| `GGML_OP_OFFLOAD_MIN_BATCH` | CPU-resident expert matmul → GPU threshold (default 32) |

---

## TurboQuant: what is and isn't safe for this model

LFM2.5-24B has **head_dim = 64** (2048 / 32 heads).

| Implementation | head_dim 64 | Verdict here |
|---|---|---|
| TheTom `turbo3`/`turbo4` | zero-pads 64→128 → **KV doubles** → turbo4 ≡ q8_0 | **AVOID** — risk with zero memory benefit; upstream PR #21089 closed unmerged |
| llama-tq `ktq*`/`vtq*` | auto-falls-back trellis→codebook, logs a warning | **SAFE** — `ktq4_1`/`vtq4_1` = 5.0 bpw, KLD 0.025 (better than `q4_0`'s 0.034) |
| upstream `q8_0` | n/a | **SAFE** — at the model's noise floor |
| upstream `q4_0`/`q4_1` | n/a | SAFE — 4.5 bpw, KLD 0.034 |
| `iq4_nl` | n/a | **SKIP** — same size as `q4_0`, worse quality, slower CPU LUT decode |
| `ktq2`/`vtq2` | n/a | **UNSAFE** — 0/36 long-context retrieval (complete failure) |

llama-tq prebuilt for sm_89:
```
https://github.com/LL4nc33/llama-tq/releases/download/v2026.10.19/llama-v2026.10.19-bin-ubuntu-cuda-12.8-sm89-x64.tar.gz
```
Needs `libcudart.so.12` + `libcublas.so.12` (present in Ollama's `cuda_v12/`).

```bash
export LD_LIBRARY_PATH=/tmp/opencode/tq/merged:$OLLAMA_HOME:$OLLAMA_HOME/cuda_v12
export GGML_BACKEND_PATH=$OLLAMA_HOME/cuda_v12/libggml-cuda.so
/tmp/opencode/tq/merged/llama-server -m "$MODEL" -ngl 99 -fa on \
  -ctk ktq4 -ctv vtq4 --n-cpu-moe 26 -c 131072
```
Expect: `head size 64 is not a multiple of the 128 block, using vtq4_1` — that is **correct and safe**.

**llama-tq has no `--moe-cache-mib` and no `draft-dspark`.** It is an alternative KV
layer, not a replacement for the Ollama/upstream runner.

---

## Speculative decoding

The DSpark drafter for this exact model:
`LiquidAI/LFM2.5-24B-A2B-DSpark-GGUF` → `LFM2.5-24B-A2B-DSpark-F16.gguf` (664 MB).

It is a **draft sidecar**: embeddings and the LM head are shared from the target at
load time, so 664 MB is the entire extra cost. 327.7 M draft params, 5 attention
layers, hidden 2048, GQA 32/8, **head_dim 64**, Markov head (rank 256) + confidence
head, **block size 9**.

```bash
llama-server \
  -m  LFM2.5-24B-A2B-QAD-Q4_0.gguf \
  -md LFM2.5-24B-A2B-DSpark-F16.gguf \
  --spec-type draft-dspark --spec-draft-n-max 9 --spec-draft-n-min 0 \
  -ngl 99 -ngld 99 -fa on --jinja -c 131072 \
  --n-cpu-moe 26 -t 16
```

`--spec-draft-n-max` is clamped to 9 (the trained block size).

**Ollama does not wire `-md`**, so DSpark must be run via `llama-server` directly.
Ollama *can* still use `LLAMA_ARG_*` for the non-draft flags.

**Caveat from Liquid's own card:** *"Floating-point differences between batched
verification and plain decoding can produce different text, including under greedy
sampling."* Output is near-identical, not bit-identical, for the 24B target.

Measured upstream: 2.12× mean on an **RTX 4070 Laptop** (with the 1.2B target),
2.38× on a B300 (24B target, SGLang). No published number exists for the 24B on
consumer hardware — measure it yourself.

Why DSpark should do well here: it verifies up to 9 tokens per target forward, and
**LFM2's routing is concentrated** (`use_expert_bias: true` deliberately biases
toward a stable expert set), so the CPU-side expert work for a 9-token verify batch
can approach that of a single token.

**Known interaction:** the MoE expert cache may need to be disabled inside
speculative draft contexts (llamadart#113, unresolved). Test them separately, then
together.

---

## `--moe-cache-mib` sizing (not the naive 10% rule)

Upstream PR #29887 says "10 % of the total expert size is good". For LFM2.5 that is
~1,231 MiB — **but the budget is a single global bank of (layer, expert) slots**:

- each slot = 3 tensors × 5.0625 MiB = **15.19 MiB**
- 1,231 MiB buys only **~80 slots**
- shared across all host-resident layers → ~3.6 slots per layer out of 64 → **5.6 % coverage**
- minimum viable: `slots ≥ top-k (4)` per group, else the group is **silently disabled**

So for a useful hit rate you want **10–20 slots per layer**, i.e. ~1,700–3,000 MiB,
traded against GPU-resident expert layers.

LFM2 is the **best-case workload** for this cache (concentrated routing → high hit
rate). But your link is **PCIe 4.0 x4 (~6.2 GB/s)**, half the x8 reference where the
cache breaks even at ~85 % hit rate. **Read the live hit rate** (`-lv 4`) — if it isn't
above ~90 %, drop this lever.

---

## VRAM budget (7,779 MiB usable)

```
VRAM = 335 MiB  (non-expert weights: embeddings + attention + conv + 2 dense FFN)
     + (38 - N) × 324 MiB   (GPU-resident expert layers)
     + ~500-700 MiB         (CUDA context + compute buffer)
     + KV cache
     + expert cache (optional)
     + 664 MiB              (DSpark drafter, if used)
```

| Goal | N | KV | Expert cache | Drafter |
|---|---|---|---|---|
| max speed | 22 | q8_0 | 0 | no |
| max speed + cache | 26 | q4_0 | ~1.8 GiB | no |
| **max speed + cache + DSpark** | 28 | q4_0 | ~1.6 GiB | yes (664 MB) |
| **max context** | 22 | q8_0 | 0 | no |
| **max context + DSpark** | 30 | q4_0 | ~1.2 GiB | yes |

The KV cache is **not** the constraint at 131 072 ctx — q4_0 KV is only 705 MiB there.
The expert layers are.

---

## KV cache sizes at 131 072 ctx (10 attention layers × 8 KV heads × 64 dims × 2)

| type | bpw | size |
|---|---|---|
| f16 | 16 | 2.684 GB (will not fit) |
| q8_0 | 8.5 | 1.426 GB |
| q4_0 / q4_1 | 4.5 | 0.755 GB |
| ktq4_1 / vtq4_1 | 5.0 | ~0.84 GB |

Conv recurrent state is a constant ~480 KB regardless of context.

---

## Disk and swap discipline

- Model does **not** fit in RAM (12.65 GiB model, 15 GiB RAM) → keep `--load-mode auto`
  (mmap). `--load-mode none` and `--mlock` will thrash.
- `--repack` (default on) is a CPU-side k-quant optimization — keep it on.
- Watch for swap thrash: `vmstat 1` and look at `si`/`so`. Sustained `so` means the
  CPU expert path is being starved and tok/s will collapse.
- Chrome is using ~1.2–4.4 GB. Close it before benchmarking.

---

## Docker housekeeping

- CLI context was `desktop-linux` (dead socket) → every `docker` command failed.
  Fixed: `docker context use default`.
- `docker-desktop` 4.79.0 is installed but not running; its VM disk is 93 GB of dead
  weight at `~/.docker/desktop/vms/0/data/Docker.raw`.
- `docker.io` 29.1.3 is installed alongside `docker-ce` 29.6.0 — redundant.
- Reclaimed so far: 31.23 GB of unused images + 738 MB build cache.

**Podman is not worth it** — same overlayfs storage (no disk saving), breaks the 4
active compose projects across 9 networks, needs CDI for the GPU.

---

## Benchmarking

```bash
cd ~/llm-edge-setup
./scripts/bench.sh sweep-n        # --n-cpu-moe sweep
./scripts/bench.sh sweep-cache    # --moe-cache-mib sweep
./scripts/bench.sh sweep-kv       # KV type vs max context
./scripts/bench.sh bench-dspark   # baseline vs DSpark
./scripts/bench.sh verify         # quality check
```

The harness refuses to run below 2 GB available RAM and kills the server between runs.
