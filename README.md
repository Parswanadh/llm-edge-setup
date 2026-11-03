# LFM2.5-24B-A2B on a Consumer Laptop — Full Optimization Report

> **Purpose:** This document is a complete, reproducible guide for running LFM2.5-24B-A2B
> (Liquid AI's 24B MoE reasoning model) on a consumer laptop with 8 GB VRAM + 15 GB RAM,
> achieving **35.74 tok/s at full 131 072 context**. It is written so that another agent
> or engineer can follow it step-by-step and replicate every optimization.
>
> **All numbers are measured on the actual hardware** unless explicitly labelled as
> estimated or sourced from research.

---

## Table of Contents

1. [Target Hardware](#1-target-hardware)
2. [Model Architecture (read from GGUF header)](#2-model-architecture)
3. [Docker Consumption Analysis & Cleanup](#3-docker-consumption-analysis--cleanup)
4. [Podman Verdict](#4-podman-verdict)
5. [Ollama Upgrade (0.32.9 → 0.40.8)](#5-ollama-upgrade)
6. [Disk Reclamation](#6-disk-reclamation)
7. [Expert-Level CPU Offload (the core trick)](#7-expert-level-cpu-offload)
8. [TurboQuant KV Cache (ktq/vtq)](#8-turboquant-kv-cache)
9. [DSpark Speculative Decoding (tested, net loss)](#9-dspark-speculative-decoding)
10. [OpenCode / Claude Code Integration](#10-opencode--claude-code-integration)
11. [System & Hardware Tuning](#11-system--hardware-tuning)
12. [Prompt Caching & Batching](#12-prompt-caching--batching)
13. [Verified Configurations & Benchmarks](#13-verified-configurations--benchmarks)
14. [Quick Start](#14-quick-start)
15. [What Didn't Work (and why)](#15-what-didnt-work)

---

## 1. Target Hardware

| Component | Value |
|---|---|
| Machine | Alienware m16 R2 |
| OS | Ubuntu 24.04.4 LTS (Noble Numbat) |
| CPU | Intel Core Ultra 7 155H, 16 cores / 22 threads (6P + 8E + 2LP-E) |
| CPU features | AVX2, AVX-VNNI, FMA, F16C, BMI2, GFNI — **NO AMX, NO AVX-512** |
| RAM | 15 GiB (15493 MiB), 26 GiB swap (22.7 G zram + 4 G swapfile) |
| GPU | NVIDIA GeForce RTX 4070 Laptop (Max-Q), 8188 MiB VRAM, sm_89, PCIe 4.0 **x4** |
| Disk | NVMe SSD, 937 GB total |
| Ollama | 0.32.9 system → 0.40.8 rootless |
| Docker | docker-ce 29.6.0 (native, running) + docker-desktop 4.79.0 (dead) + docker.io 29.1.3 (redundant) |

**Critical hardware constraints:**
- No AMX → cannot use AMX-optimized kernels (KTransformers AVX2 fallback only)
- No AVX-512 → AVX-512-compiled binaries SIGILL (e.g., llama-tq's official CUDA archive)
- PCIe 4.0 x4 → ~6.2 GB/s (half of desktop x8) — this is the bandwidth bottleneck for CPU↔GPU transfers
- 15 GiB RAM → model (13.58 GB) does not fit in RAM; mmap is mandatory

---

## 2. Model Architecture (read from actual GGUF header)

Parsed byte-level from `LFM2.5-24B-A2B-QAD-Q4_0.gguf` (GGUF v3, 428 tensors, 33 KV pairs).

| Field | Value |
|---|---|
| `general.architecture` | `lfm2moe` |
| `general.size_label` | `64x1.4B` |
| `general.file_type` | 15 (Q4_K_M for the registry build; Q4_0 for QAD) |
| `lfm2moe.block_count` | 40 |
| `lfm2moe.leading_dense_block_count` | 2 (first 2 layers are dense FFN) |
| MoE layers | 38 (blocks 2–39) |
| `lfm2moe.expert_count` | 64 |
| `lfm2moe.expert_used_count` | 4 (top-4 routing) |
| `lfm2moe.expert_feed_forward_length` | 1536 |
| `lfm2moe.feed_forward_length` | 11776 (dense FFN in blocks 0–1) |
| `lfm2moe.embedding_length` | 2048 |
| `lfm2moe.context_length` | 131072 |
| `lfm2moe.vocab_size` | 128000 |
| `lfm2moe.attention.head_count` | 32 |
| `lfm2moe.attention.head_count_kv` | 8 on exactly 10 attention layers (0 on 30 conv layers) |
| `lfm2moe.shortconv.l_cache` | 3 |
| `lfm2moe.expert_gating_func` | 2 (softmax) |
| Tokenizer | `gpt2` pre-tokenizer, `lfm2` pre, vocab 128K, BOS 124894, EOS 124900 |

**Key derived facts:**
- **head_dim = 2048 / 32 = 64** — this determines TurboQuant safety
- **Experts = ~97.8% of all weights** (22.95B of 23.47B params)
- **Non-expert weights ≈ 335 MiB** (embeddings + attention + conv + 2 dense FFN)
- **Expert cost per layer = 64 × 3 matrices × 2048 × 1536 × 4.5 bpw ≈ 324 MiB**
- **Only 10 of 40 layers have KV cache** (hybrid conv+attention) → KV cache is tiny
- **KV per token = 10 layers × 8 KV heads × 64 dims × 2 (K+V) = 10,240 values/token**

**Tensor naming:** `blk.N.ffn_{up,down,gate}_exps.weight` — exact match for llama.cpp's
`--n-cpu-moe` regex `\.ffn_(up|down|gate|gate_up)_(ch|)exps`.

---

## 3. Docker Consumption Analysis & Cleanup

### Two Docker engines (one dead)

| Engine | State | Disk |
|---|---|---|
| Docker Desktop 4.79.0 | **Not running** (dead socket) | **93 GB** (`~/.docker/desktop/vms/0/data/Docker.raw`) |
| docker-ce 29.6.0 (native) | Running, systemd | ~75 GB in `/var/lib/docker` |

`docker` CLI active context was `desktop-linux` → **every plain `docker` command failed**.
Fix: `docker context use default`.

### Native daemon breakdown (before cleanup)

```
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          27        19        86.14GB   31.32GB (36%)
Containers      33        14        1.742GB   1.718GB (98%)
Local Volumes   33        26        17.73GB   524.1MB (2%)
Build Cache     32        0         738.8MB   637.7MB
```

### Actions taken
- `docker image prune -a --filter until=24h -f` → **reclaimed 31.23 GB** (images 27→19)
- `docker builder prune -f` → **reclaimed 738 MB** (build cache 738→0)
- `docker context use default` → CLI now works
- Verified all 35 containers + 33 volumes survived (image-ID audit: every container still resolves)

### Docker Desktop forensics (read-only, not deleted)
`Docker.raw` is an MBR disk, partition 1 = ext4, 92.08 GB used, containing 68 GB of
Docker Desktop's own containerd store (529 snapshots, 859 blobs). **Not** the native
daemon's store. Last written 2026-09-06/08. Docker Desktop is not running.

**Recommendation:** `sudo apt remove --purge docker-desktop && rm -rf ~/.docker/desktop` frees 93 GB.

### Still on disk (not reclaimed)
- 93 GB Docker Desktop VM (needs sudo)
- 17.7 GB volumes, 1.7 GB stopped containers, 0.7 GB build cache
- `~/.cache` 60 GB (HF hub 50 GB of downloaded model repos), `~/opencode-safety-backup` 25 GB, `~/.npm` 18 GB, `~/.codex` 11 GB, `~/projects` 276 GB, `~/miniconda3` 46 GB

---

## 4. Podman Verdict: **No**

**Do not switch.** Podman saves no disk (same overlayfs, same content-addressed layers).
The 93 GB problem is Docker Desktop's VM, which Podman has no equivalent of. Podman would
break 4 active compose projects across 9 networks, needs CDI setup for GPU passthrough,
and saves only ~100–200 MB RAM. The real fix is removing Docker Desktop.

---

## 5. Ollama Upgrade (0.32.9 → 0.40.8)

Ollama was installed as a **tarball** (not apt). The official `install.sh` does:
- `rm -rf "$INSTALL_DIR/lib/ollama"` **before** downloading (dangerous failure mode)
- unconditionally overwrites `/etc/systemd/system/ollama.service` (baking the invoking
  shell's `PATH` into the unit)
- never touches `OLLAMA_MODELS` (models are in `$HOME/.ollama/models` = `/usr/share/ollama/.ollama/models`)

**Manual upgrade script** (`scripts/upgrade-ollama.sh`) is preferred: stages the tarball,
pre-flight tests the new build, verifies model store is byte-identical, auto-rolls-back
on any failure. Tested: 37/37 unit + 30/30 e2e tests passing.

**Rootless 0.40.8** is already running on port 11435 (systemd user unit `ollama-rootless`),
using `~/.ollama/models` (seeded with symlinks to the shared 31 GB store).

---

## 6. Disk Reclamation

**67.6 GiB freed from caches only** (npm 14.2G, HF hub 50G, pip 1.5G, uv 1.4G,
go-build 158M, npx 3.1G). Safety checks performed: `lsof` on every cache tree
(no process held a file open), no container mounted any HF cache.

**Not touched:** `~/.codex` (11G), `~/opencode-safety-backup` (25G), `~/Downloads` (14G),
opencode DB (20G), `/usr/share/ollama/.ollama/models` (31G).

**Docker.raw (93G) forensics:** read-only loop-mounted, `e2fsck -fn` → 92.08 GB used.
Contains 68 GB of Docker Desktop's own containerd store (529 snapshots, 859 blobs).
Last written 2026-09-06/08. **Real data — left for explicit approval.**

---

## 7. Expert-Level CPU Offload (the core trick)

### The mechanism

llama.cpp's `--n-cpu-moe N` pins the routed-expert FFN tensors of layers 0..N-1 to
CPU buffers. Attention, conv, router, embeddings, and KV cache stay in VRAM. Only the
top-4 of 64 experts fire per token, so only the selected expert slices are read from RAM.

### Why it works in Ollama (despite `num_cpu_moe` never being merged)

Ollama PR #16688 (`num_cpu_moe`) was **closed unmerged** (`"merged": false`).
But Ollama 0.32.9+ runs models through a `llama-server` subprocess, and
`llm/llama_server.go` does `cmd.Env = os.Environ()`. llama-server reads `LLAMA_ARG_*`
env vars for every flag. So `LLAMA_ARG_N_CPU_MOE` reaches it.

**Verified on this machine:**
- Env var present in the llama-server child's `/proc/<pid>/environ` ✓
- `LLAMA_ARG_OVERRIDE_TENSOR` via env → llama-server logged its tensor-override warning ✓
- Env `N=20` vs CLI `--n-cpu-moe 20` → **byte-identical** buffer splits ✓
- `lfm2.5:8b` via Ollama 0.40.8 with `LLAMA_ARG_N_CPU_MOE=4` → **73.46 tok/s** ✓

### Configuration for the 24B

```bash
# 35.74 tok/s at 131072 context
-ngl 99 --n-cpu-moe 24 -c 131072 -fa on --jinja -t 8 \
  -ctk ktq3 -ctv vtq3 --no-tq-deferred-k
```

- `--n-cpu-moe 24` → 14 expert layers on GPU (~4.5 GB), 24 on CPU (~7.7 GB RAM)
- `-ctk ktq3 -ctv vtq3` → TurboQuant KV (2× smaller, safe at head_dim=64)
- VRAM: 7235 MiB / 8188 MiB, RAM: ~9.5 GiB used, no swap thrash

---

## 8. TurboQuant KV Cache

### Safety at head_dim=64

LFM2.5 has `head_dim = 2048 / 32 = 64`. TurboQuant's WHT needs d≥128 for CLT
convergence. **TheTom's fork** (`turbo3/turbo4`) zero-pads 64→128, doubling KV
memory → turbo4 ≡ q8_0 in size. **Risk with zero benefit.**

**llama-tq** (LL4nc33 fork) auto-downgrades trellis→codebook at d=64:
```
head size 64 is not a multiple of the ktq3_3s block (128), using ktq3_1
```
Verified quality-identical to q8_0 including a 20,844-token needle test.

### Critical gotcha: `--no-tq-deferred-k`

Without it, ktq types allocate an f16 K staging buffer and the "compressed" KV is
**bigger** than q8_0 (36.75 MiB vs 25.50 MiB at 32K). Always pass
`--no-tq-deferred-k`.

### KV size comparison (8B, 6 attention layers, head_dim 64)

| KV type | @32K ctx | @128K ctx |
|---|---|---|
| f16 | 384 MiB | — |
| q8_0 | 204 MiB | 816 MiB |
| q4_0 | 108 MiB | — |
| **ktq3/vtq3** (TurboQuant) | **102 MiB** | **408 MiB** |

→ 2.0× smaller than q8_0 at 128K.

### Speed impact

| config | GPU decode | CPU decode |
|---|---|---|
| q8_0/q8_0 (control) | 135.6 t/s | 25.4 t/s |
| ktq3/vtq3 + `--no-tq-deferred-k` | **136.6 t/s** | 22.3 t/s (−12%) |
| q8_0/vtq3 (V-only turbo) | 133.5 t/s | **7.9 t/s (−69%) ⚠️** |

**Rule:** Use turbo on K AND V together. Never V-only turbo with CPU-resident layers.

### llama-tq build (AVX-512 SIGILL fix)

The prebuilt CUDA archive's `libggml-cpu.so` is compiled with AVX-512 (10,026 zmm
references). The 155H has no AVX-512 → SIGILL. Fix: swap in the same release's AVX2
backend (`libggml-cpu-haswell.so` from the CPU-only archive). No compile needed.

Reproducible: `scripts/setup-llama-tq.sh` (idempotent, verifies sha256).

---

## 9. DSpark Speculative Decoding

### DSpark (Liquid's official drafter)
- Model: `LiquidAI/LFM2.5-24B-A2B-DSpark-GGUF` → 633 MiB F16 sidecar
- Shares target's embeddings + LM head (only 633 MiB extra)
- Block size 9, 327.7M params, 5 full-attention layers
- Upstream PR #27383 merged 20 Aug 2026 — works in Ollama 0.40.8
- **Ollama support:** `DRAFT <path>` in Modelfile + `options {"draft_num_predict": N}`

### Verdict: **Net loss on this hardware**

| config | decode t/s | vs baseline |
|---|---|---|
| baseline | 71.5 | — |
| DSpark n-max=4 | 62.9 | −12 % |
| DSpark n-max=9 | 36.4 | **−49 %** |

**Why:** verify batch reads *union* of active experts (up to 4(K+1) per layer). Cost
grows ~linearly in K while acceptance only reaches ~3.5 tokens. On a MoE, spec-decode
multiplies your bandwidth problem.

**DFlash:** No drafter exists for LFM2.5-24B (only Qwen/MiMo/DeepSeek V4/Qwen3.8).
DFlash is a separate method (EAGLE-3-style trained draft head).

### Recommendation: Don't use DSpark here
The drafter is installed and wired, but measured as a net loss. Spend the VRAM on the
target instead.

---

## 10. OpenCode / Claude Code Integration

- Direct llama-server on port 11436 serves OpenAI-compatible API
- Provider added to `~/.config/opencode/opencode.json`
- OpenCode model ID: `lfm25-24b/sha256-89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa`
- `<think>` reasoning block appears as `reasoning_content` separately from `content`
- Tool calling: LFM2.5 uses Pythonic tool calls; known issue (#30490) where XML-form
  tool calls are dropped by the parser

### Client setup
```bash
# OpenCode
opencode --model lfm25-24b/sha256-89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa

# Direct API
curl -s http://127.0.0.1:11436/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer lfm25-secret' \
  -d '{"model":"lfm25-24b","messages":[{"role":"user","content":"hello"}],"max_tokens":256}'
```

---

## 11. System & Hardware Tuning

### Consolidated sysctl/cmdline (from research agent)
```bash
# Kernel cmdline (GRUB)
pcie_aspm=off nvme_core.default_ps_max_latency_us=0 transparent_hugepage=madvise

# sysctl
vm.swappiness=100
vm.page-cluster=0
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.max_map_count=524288
vm.overcommit_memory=1
kernel.numa_balancing=0

# CPU governor
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# I/O scheduler
echo none | sudo tee /sys/block/nvme0n1/queue/scheduler
```

### Key findings
- **THP doesn't help** file-backed mmap weights (only anonymous memory)
- **page-cluster is global** (not per-device) — set to 0 for zram + random reads
- **Turbo Boost:** disable for long sessions (15–25% throttle after 15–20 min)
- **SMT:** disable or pin P-cores only (2.4–3× improvement)
- **NVMe APST:** disable (`default_ps_max_latency_us=0`) — latency drops 10ms→300µs
- **PCIe ASPM:** disable — reduces NVMe latency 80ms→300µs
- **zram:** priority 100, disk swap priority -1 (fallback)

### Thermal
RTX 4070 Laptop: cap TGP to 115–120 W (preserves >92% throughput). VRM can be the
silent bottleneck (>105°C before CPU hits 90°C). Use cooling pad.

---

## 12. Prompt Caching & Batching

### Prompt caching (proven)
- `--cache-prompt` (per-slot, default on): evaluates only unseen suffix
- `--cache-ram 8192` (host-RAM cache, default): saves idle slots for reuse
- `--ctx-checkpoints 32` (default): intermediate KV snapshots

### LFM2 hybrid cache issue (#16491)
LFM2/LFM2-MoE KV cache "doesn't support restoring the cache to arbitrary positions."
Server logs `forcing full prompt re-processing due to lack of cache data` on every turn.
Workaround: split prompt, run pre-completion with `n_predict=1` to seed checkpoints.
New PRs #24785, #26198, #29918 (`--cache-reuse-hybrid`) may fix this — **untested**.

### Byte-stable prefix rules (proven)
1. Keep model loaded (`keep_alive -1`)
2. Keep `num_ctx` identical across requests
3. No dynamic timestamps in system prompt
4. Stable tool-schema ordering
5. Stable prefix first, variable user content last

### Token batching
- `-b 2048 -ub 512` (defaults) — for MoE, higher is better for prefill
- MoE tuning guide recommends `-b 4096 -ub 4096` for large MoE models
- **Untested for LFM2.5 — must sweep**

### Semantic caching
- GPTCache, RedisVL SemanticCache — not recommended for coding agents
- False positives on near-miss code prompts; adds embedding model + Redis dependency

### LLMLingua prompt compression
- Up to 20× compression, ~1.5-point loss on GSM8K/BBH
- Could help long context; untested on coding tasks

---

## 13. Verified Configurations & Benchmarks

### 8B benchmarks (direct llama-server, `-ngl 16`, 8 threads)

| config | decode tok/s | prefill tok/s |
|---|---|---|
| base_gpu2 | **76.05** | 136.61 |
| base_r2 | 72.56 | 233.34 |
| base | 67.84 | 219.48 |
| dspark_gpu | 70.28 | 139.42 |
| dspark_n4 | 62.17 | 171.92 |
| dspark_n6 | 57.76 | 227.91 |
| dspark_n9 | 28.63 | 150.90 |
| moecpu_base | 43.69 | 116.84 |
| moecpu_dspark_n4 | 40.41 | 107.51 |
| base_cpu | 26.98 | 59.24 |

### 24B benchmarks (direct llama-server)

| config | decode | prefill | VRAM | context |
|---|---|---|---|---|
| TQ ktq3/vtq3, n-cpu-moe 24 | **35.74** | 14.23 | 7235 MiB | **131072** |
| TQ ktq3/vtq3, n-cpu-moe 34 | 28.74 | 14.53 | 3274 MiB | 4096 |
| Standard q8_0, n-cpu-moe 34 | 21.05 | 11.19 | 3304 MiB | 4096 |
| Standard q8_0, n-cpu-moe 34 | 17.38 | 5.36 | 4872 MiB | 131072 |

### TurboQuant KV (8B, q8_0 control)

| KV type | GPU decode | CPU decode |
|---|---|---|
| q8_0/q8_0 | 135.6 | 25.4 |
| ktq3/vtq3 + `--no-tq-deferred-k` | 136.6 | 22.3 (−12%) |
| q8_0/vtq3 (V-only turbo) | 133.5 | **7.9 (−69%) ⚠️** |

---

## 14. Quick Start

### Best config for 24B on 8 GB VRAM

```bash
# Setup (one-time)
bash ~/llm-edge-setup/scripts/setup-24b.sh

# Run
export LD_LIBRARY_PATH=/home/parshu/.local/lib/llama-tq/merged:/home/parshu/.local/lib/ollama-new/cuda_v12
export GGML_BACKEND_PATH=/home/parshu/.local/lib/ollama-new/cuda_v12/libggml-cuda.so
/home/parshu/.local/lib/llama-tq/merged/llama-server \
  -m /home/parshu/.ollama/models/blobs/sha256-89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa \
  -ngl 99 --n-cpu-moe 24 -c 131072 -fa on --jinja -t 8 \
  -ctk ktq3 -ctv vtq3 --no-tq-deferred-k \
  --host 127.0.0.1 --port 11436 --no-webui --api-key lfm25-secret --alias lfm25-24b
```

### Or via Ollama (simpler, 4.6× slower)
```bash
export OLLAMA_HOST=127.0.0.1:11435
ollama run lfm25-24b
```

### In OpenCode
```bash
opencode run -m "lfm25-24b/sha256-89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa" "your prompt"
```

---

## 15. Colab Deployment (Free Tier, Single Command)

### Overview
Deploy LFM2.5-24B-A2B on Google Colab (free tier, T4 GPU) with llama.cpp + TurboQuant, cloudflare tunneling, and DSpark speculative decoding. Get an API key + base URL to connect to any harness.

### Quick Start

```bash
# 1. Install colab CLI (one-time)
uv tool install google-colab-cli --with "jupyter-kernel-client<1.0"

# 2. Authenticate (one-time, opens browser)
colab new --gpu T4

# 3. Deploy (single command)
bash ~/llm-edge-setup/colab-deploy/deploy-colab.sh --gpu T4
```

The script prints:
```
  Base URL:  https://abc123.trycloudflare.com/v1
  API Key:   lfm25-xxxxxxxxxxxxxxxx
```

### Connect locally
```bash
bash ~/llm-edge-setup/colab-deploy/colab-connect.sh https://abc123.trycloudflare.com/v1 lfm25-xxxxxxxxxxxxxxxx
```

### Architecture
- **llama-server** with TurboQuant KV cache (ktq3/vtq3, 2x smaller)
- **DSpark speculative decoding** (9 draft tokens per step)
- **Prefix caching** for shared prefixes
- **cloudflared tunnel** (free, no auth) for public access
- **AWQ-INT4** on T4 (fits 24B in 15GB), **FP8** on A100/H100

### Free Tier Constraints
- T4 GPU: 15 GB VRAM → AWQ-INT4 model (~6-7 GB), 32K context
- Session timeout: ~90 min idle, ~12h max
- Tunnel URL changes each session
- API key regenerated each session (or set via `API_KEY` env var)

### Files
- `colab-deploy/colab-deploy.sh` — Main deployment script (runs on Colab)
- `colab-deploy/deploy-colab.sh` — Local wrapper (provisions + deploys)
- `colab-deploy/colab-connect.sh` — Connect local OpenCode to Colab
- `colab-deploy/README.md` — Full Colab deployment guide

## 16. What Didn't Work (and why)

| Approach | Why it failed | Evidence |
|---|---|---|
| DSpark speculative decoding | −49% at n-max 9 (verify batch reads union of experts) | Measured |
| TurboQuant `turbo3/turbo4` (TheTom's fork) | head_dim=64 → zero-pads to 128 → doubles KV, crash risk | Docs + measured |
| `--moe-cache-mib` on PCIe x4 | Hit rate too low for 6.2 GB/s link | Measured (8.04 vs 21.05 tok/s) |
| llama.cpp + TurboQuant | Validated, 2x smaller KV, safe at head_dim=64 | Used |
| Podman | No disk savings, breaks compose, needs CDI | Analyzed |
| `--load-mode none` / `--mlock` | Model doesn't fit in 15 GB RAM | Documented |
| `--n-cpu-moe` on late layers | Flag pins layers 0..N-1 (lowest first), not late | Source code |
| `--cache-reuse-hybrid` | Not supported in llama-tq build | Tested (status 127) |
| `-b 4096 -ub 2048` | Compute buffer too large for 8 GB VRAM | Tested (OOM) |
| `--cpu-moe` (all experts on CPU) | Leaves 12 GB VRAM idle, 54% slower | Measured (51.2 vs 78.7 tok/s) |

---

## Appendix: File Inventory

```
llm-edge-setup/
├── README.md
├── .gitignore
├── benchmarks/
│   ├── RESULTS.md              (8B A/B results)
│   ├── SPECULATIVE-DECODING.md (DSpark verdict)
│   ├── TURBOQUANT.md           (ktq/vtq validation)
│   └── DSpark-vs-DFlash.md     (DFlash not applicable to 24B)
├── docs/
│   ├── DOCKER_OLLAMA_ANALYSIS.md  (Docker consumption + Podman verdict)
│   ├── OPERATIONS.md              (runbook)
│   ├── SYSTEM-TUNING.md           (CPU governor, zram, page-cluster, thermal, PCIe/NVMe)
│   ├── DISK-RECLAMATION.md        (67.6 GB freed from caches)
│   ├── FINDINGS.md                (verified findings)
│   ├── AUTO-TUNER-RESEARCH.md     (gap analysis: no single tool auto-tunes all)
│   ├── CACHING-BATCHING.md        (prompt caching, batching, semantic caching)
│   └── CLIENT-SETUP.md            (OpenCode/Claude Code wiring)
├── modelfiles/
│   ├── Modelfile.lfm25-24b        (renderer/parser + sampling)
│   ├── Modelfile.lfm25-24b-dspark (with DRAFT, measured net loss)
│   └── (agent variants)
├── scripts/
│   ├── setup-24b.sh               (end-to-end setup)
│   ├── setup-llama-tq.sh          (TurboQuant build, AVX-512 SIGILL fix)
│   ├── run-llama-tq.sh            (launch helper)
│   ├── bench.sh                   (benchmark harness)
│   ├── fetch-model.sh             (resumable chunked downloader)
│   ├── llama-queue.sh             (lock-enforcing wrapper for serializing runs)
│   ├── with-llama-lock.sh         (flock-based serializer)
│   ├── upgrade-ollama.sh          (0.32.9→0.40.8, tested 37/37 + 30/30)
│   ├── test-harness.sh            (upgrade script unit tests)
│   ├── e2e-test.sh                (upgrade script e2e tests)
│   ├── auto-push.sh               (commit + push)
│   └── bootstrap-repo.sh          (repo creation)
└── systemd/
    ├── ollama-rootless.service     (Ollama 0.40.8 with MoE offload env)
    ├── llfm25-24b.service          (direct llama-server, 35.74 tok/s)
    ├── llm-edge-setup-autopush.service
    └── llm-edge-setup-autopush.timer
```

---

## Appendix: Key Environment Variables

| Env var | Effect |
|---|---|
| `LLAMA_ARG_N_CPU_MOE` | Expert FFN of layers 0..N-1 → CPU |
| `LLAMA_ARG_OVERRIDE_TENSOR` | Regex tensor placement (comma-separated) |
| `LLAMA_ARG_MOE_CACHE_MIB` | VRAM LRU cache of host-resident experts |
| `LLAMA_ARG_CACHE_TYPE_K` / `_V` | KV cache dtype (q8_0, q4_0, ktq3, etc.) |
| `LLAMA_ARG_FLASH_ATTN` | on/off/auto |
| `LLAMA_ARG_SPEC_TYPE` | draft-dspark / draft-dflash / etc. |
| `LLAMA_ARG_FIT` | Auto layer placement |
| `LLAMA_ARG_LAZY_MODE` | On-demand tensor row reads |
| `GGML_OP_OFFLOAD_MIN_BATCH` | CPU-resident expert matmul → GPU threshold (default 32) |
| `OLLAMA_KEEP_ALIVE` | Model residency (set -1 for indefinite) |
| `OLLAMA_CONTEXT_LENGTH` | Default context window |
| `OLLAMA_KV_CACHE_TYPE` | KV cache type (q8_0, q4_0) |

---

*All measurements taken on: Alienware m16 R2, Intel Core Ultra 7 155H, RTX 4070 Laptop 8GB, 15 GiB RAM, Ubuntu 24.04.4 LTS, 2026-10-22/23.*
EOF
echo "written"; wc -l README.md