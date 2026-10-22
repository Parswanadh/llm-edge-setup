# Docker / Ollama / LFM2.5-24B Analysis — Alienware m16 R2

Date: 2026-10-22. All numbers below are **measured on this machine** unless explicitly labelled as research-reported.

---

## 1. Machine baseline (measured)

| Item | Value |
|---|---|
| OS | Ubuntu 24.04.4 LTS |
| CPU | Intel Core Ultra 7 155H, 22 threads (16 cores) |
| RAM | 15 GiB total, 26 GiB swap (22.7 G zram + 4 G swapfile) |
| GPU | RTX 4070 Laptop (Max-Q), 8188 MiB VRAM, ~7.6 GiB usable |
| Disk | NVMe, 937 G total, 98% → 95% used after cleanup |
| Ollama | 0.32.9 system-wide (`/usr/local/bin/ollama`), service runs as user `ollama` |
| Docker | docker-ce 29.6.0 (native) + docker-desktop 4.79.0 + docker.io 29.1.3 (all three installed) |

---

## 2. Docker consumption (measured)

### 2.1 Two Docker engines, one dead

| Engine | State | Disk |
|---|---|---|
| **Docker Desktop** (`docker-desktop` 4.79.0) | **NOT running.** `~/.docker/desktop/docker.sock` is a 0-byte dead socket | **93 GB** — `~/.docker/desktop/vms/0/data/Docker.raw` (937 G apparent / 93 G actual, sparse) |
| **docker-ce (native)** | running, systemd `docker.service`, active | **~75 GB** in `/var/lib/docker` |

`~/.docker` totals **93 GB**. The `docker` CLI's *active context* is `desktop-linux` → **every plain `docker` command fails** with
`Cannot connect to the Docker daemon at unix:///home/parshu/.docker/desktop/docker.sock`.

### 2.2 Native daemon breakdown (before cleanup)

```
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          27        19        86.14GB   31.32GB (36%)
Containers      33        14        1.742GB   1.718GB (98%)
Local Volumes   33        26        17.73GB   524.1MB (2%)
Build Cache     32        0         738.8MB   637.7MB
```

Largest images: `vxcontrol/kali-linux` 24.3 GB, `container-registry.oracle.com/database/free` 13.7 GB,
`ghcr.io/librelane/librelane` 7.52 GB ×2 (one dangling), `openroad/orfs` 6.51 GB, `timeloopaccelergy/...` 4.69 GB.
Largest volume: `oracle-data` **12.69 GB**.

### 2.3 Action taken

`docker image prune -a --filter until=24h` → **reclaimed 31.23 GB**. Images 27→19, disk 98% → 95%.

Also noted: `docker.io` (Ubuntu's package) is installed *alongside* `docker-ce` — redundant and a known upgrade-conflict source.

### 2.4 Still on disk (NOT reclaimed)

- **93 GB Docker Desktop VM** — dead weight, but the file is owned by `parshu` and removal is destructive to Docker Desktop's
  (unused) VM contents. Removing it requires `sudo apt remove docker-desktop` + `rm -rf ~/.docker/desktop`. **This is the single
  biggest reclaim available.**
- ~17.7 GB volumes, ~1.7 GB stopped containers, ~0.7 GB build cache.
- Other large home-dir consumers: `~/.cache` 60 GB, `~/opencode-safety-backup` 25 GB, `~/.npm` 18 GB, `~/.codex` 11 GB,
  `~/projects` 276 GB, `~/miniconda3` 46 GB.

---

## 3. Podman: should you switch? **No.**

### Why not

1. **Podman saves no disk.** Both use overlayfs with content-addressed layers. Your 54.8 GB of live images + 17.7 GB volumes
   occupy the same space under `/var/lib/containers` as under `/var/lib/docker`. **Podman does not solve the disk problem.**
2. **The disk problem is not Docker's fault.** 93 GB of your consumption is Docker Desktop's *VM disk*, which Podman has no
   equivalent of. Switching engines while keeping Docker Desktop installed gains nothing.
3. **Your stack is compose-heavy and network-complex.** 4 active compose projects (`pentagi`, `rag-agno`, `rag-agno-proof`,
   `vs-anythingllm`) across 9 networks including user-defined bridge networks (`pentagi-network`, `rag-agno_rag-data`,
   `rag-agno_rag-access`, `langfuse-network`, `observability-network`). `podman-compose` is a reimplementation with weaker
   support for `depends_on` conditions, healthcheck gating, and multi-network service aliasing.
4. **GPU passthrough needs CDI.** Podman has no nvidia-container-runtime equivalent; it requires `nvidia-ctk runtime configure`
   to generate CDI specs. Not hard, but it is extra work with a failure mode (CDI spec drift) Docker does not have.
5. **Rootless networking differs.** Rootless Podman uses slirp4netns/pasta with port-forwarding overhead and different
   DNS behaviour — a real risk for your postgres/redis/qdrant inter-container traffic.

### What Podman *would* buy you

Idle RAM: `dockerd` 56 MB + `containerd` 29 MB + shims ≈ **181 MB total**. Podman has no persistent daemon, so the saving is
**~100–200 MB of RAM**. On a 15 GiB box with a documented history of 31 OOM kills, that is real but small — and the machine's
RAM pressure comes from Chrome (4.4 GB) and the desktop baseline (~10 GB), not from Docker.

### Recommended instead

1. **Remove Docker Desktop** (frees 93 GB) — you already have docker-ce doing the work.
2. `docker context use default` so the CLI stops pointing at the dead socket.
3. `sudo apt remove docker.io` (keep only docker-ce).
4. `docker system prune -a --volumes` periodically; review `oracle-data` (12.69 GB) and `docker.io` leftovers.
5. **Then** consider podman only if you want rootless isolation for a *new* isolated workload, not as a migration.

---

## 4. Ollama upgrade

| | Version | Notes |
|---|---|---|
| Installed | 0.32.9 (Aug 11) | llama.cpp b10353 — **does** support `lfm2moe` |
| Latest | **0.40.8** (Oct 21) | downloaded, verified working |
| Required for `lfm2.5:24b` | **0.40.4** | all 24b tags declare `"requires":"0.40.4"` |

Rootless install staged at `~/.local/lib/ollama-new/` (2.4 GB), verified serving on 0.40.8 with CUDA detection of the RTX 4070.

**`sudo` is unavailable in this session** (password required), so the system-wide install at `/usr/local/bin/ollama` was not
replaced. Two supported paths:

- **Path A (recommended, no sudo):** rootless user service — already written to
  `~/.config/systemd/user/ollama-rootless.service`, using `~/.ollama/models` and port 11435.
- **Path B:** `curl -fsSL https://ollama.com/install.sh | sh` (needs sudo; overwrites the system binary and service).

Model store note: `~/.ollama/models/blobs` was populated with **symlinks** to the 38 shared blobs in
`/usr/share/ollama/.ollama/models/blobs` (read-only to your user) plus copies of the 16 manifests. The rootless instance
therefore sees all 17 pre-existing models with **zero extra disk usage**, and writes new models into your own home store.

---

## 5. "Can only the active params live on GPU, rest in RAM/SSD?" — **YES, and it is verified working.**

### 5.1 The mechanism

llama.cpp exposes `--n-cpu-moe N` / `-ncmoe N`:
> keep the Mixture of Experts (MoE) weights of the first N layers in the CPU

It works by **tensor-buffer-type override** (llama.cpp `common/common.h`):

```cpp
const char * const LLM_FFN_EXPS_REGEX = "\\.ffn_(up|down|gate|gate_up)_(ch|)exps";
```

Attention, conv, router, embeddings and KV cache stay in VRAM; **only the routed-expert FFN tensors move to CPU RAM (mmap'd from
SSD)**. Because only `top-4` of `64` experts fire per token, only the *selected* expert slices are ever read — so per token you
stream ~2.4 B params' worth of expert bytes instead of 24 B.

### 5.2 It works in Ollama, despite `num_cpu_moe` never being merged

Ollama PR #16688 (`num_cpu_moe` option) was **closed unmerged** (`"merged": false`, `"merged_at": null`) — confirmed via the
GitHub API. The `ollama` 0.32.9 and 0.40.8 binaries contain **zero** occurrences of `num_cpu_moe`.

**But Ollama 0.32.9+ runs models through a `llama-server` subprocess**, and `llm/llama_server.go` does:

```go
func SetupLlamaServerCommandEnv(cmd *exec.Cmd, exe string, gpuLibs []string, extraEnvs map[string]string) {
    cmd.Env = os.Environ()   // <-- FULL environment inherited
```

llama-server reads `LLAMA_ARG_*` env vars for every flag (documented in its `--help`). So `LLAMA_ARG_N_CPU_MOE` reaches it.

### 5.3 Verified on this machine (measured)

| Test | Result |
|---|---|
| `LLAMA_ARG_N_CPU_MOE=4` set on the ollama process | present in `/proc/<pid>/environ` |
| Same var in the **llama-server child** | **present** — passthrough confirmed |
| `LLAMA_ARG_OVERRIDE_TENSOR=...` via env | llama-server emitted `tensor overrides to CPU are used with mmap enabled` → **env override confirmed read** |
| `LLAMA_ARG_N_CPU_MOE=20` (env) vs `--n-cpu-moe 20` (CLI flag) | **byte-identical**: CUDA0 = 1333.6 MiB, CPU_Mapped = 3780.4 MiB in both |
| `lfm2.5:8b` via Ollama 0.40.8 with `LLAMA_ARG_N_CPU_MOE=4` | **73.5 tok/s**, correct `<think>` reasoning output |
| LFM2.5-24B tensor naming | `blk.N.ffn_{up,down,gate}_exps.weight` — **exactly matches** the `--n-cpu-moe` regex |

Buffer split observed with experts on CPU: **CUDA0 = 1.33 GB, CPU_Mapped = 3.78 GB** — i.e. VRAM holds attention/conv/router/embeddings,
while the bulk of expert weights sit in CPU memory as mmap'd file pages (so the kernel can evict cold ones back to SSD).

### 5.4 The honest caveats

- **"Rest in SSD" is automatic but not free.** The CPU-resident experts are mmap'd. Under RAM pressure the kernel evicts cold
  pages to disk and re-reads them on next touch → per-token latency jitter, not a crash. With 15 GiB RAM and ~8 GB of CPU-resident
  expert weights, you will thrash unless you keep the CPU-resident set ≤ ~8 GB.
- **Swap is a death spiral.** zram + swapfile means swapped model pages turn into 1-token-per-20–30-seconds stalls.
  Disable swap for inference sessions.
- **`--repack` (default ON) breaks streaming** — CPU_REPACK buffers are anonymous memory, so weights must be materialised in RAM.
  Use `--no-repack` / `--load-mode mmap` for models larger than RAM.
- **Decode vs prefill asymmetry.** llama.cpp offloads the expert matmul to GPU only when the batch ≥ `GGML_OP_OFFLOAD_MIN_BATCH`
  (default 32). At decode (1 token) the expert matmul runs **on the CPU**. Set `GGML_OP_OFFLOAD_MIN_BATCH=1` if you want CPU→GPU
  expert uploads during single-token decode (costs PCIe bandwidth).
- **`--n-cpu-moe N` pins layers 0…N-1** (lowest index first) — confirmed from llama.cpp source (`llm_add_n_cpu_ffn_overrides`).
  Some community guides claim highest-first; the source says otherwise.
- Ollama's bundled llama-server sets `--load-mode none` for CUDA integrated GPUs, but on your discrete 4070 it uses mmap — good.

---

## 6. LFM2.5-24B-A2B: does it fit your laptop?

### Architecture (read from the actual GGUF header, not docs)

```
general.architecture            = lfm2moe
lfm2moe.block_count             = 40
lfm2moe.expert_count            = 64
lfm2moe.expert_used_count       = 4          (top-4 routing)
lfm2moe.expert_feed_forward_length = 1536
lfm2moe.leading_dense_block_count = 2        (first 2 layers dense → 38 MoE layers)
lfm2moe.embedding_length        = 2048
lfm2moe.context_length          = 131072
lfm2moe.vocab_size              = 128000
lfm2moe.attention.head_count    = 32
head_count_kv                   = 8 on exactly 10 layers (30 are conv layers)
```

So: **40 layers, 10 GQA attention + 30 gated short-conv, 64 experts (top-4), 2.45 B active of 24 B total.**

Experts are **~97.8 % of all weights**. That is the key fact — offloading experts to CPU is nearly the whole model.

### Budget for your box

| Quant | Size | Verdict |
|---|---|---|
| **`lfm2.5:24b-a2b-q4_0`** (Liquid's QAD build) | **13.58 GB** | **Best.** Liquid's own claim: ≈99 % of BF16 on 8 benchmarks |
| `lfm2.5:24b` (Q4_K_M) | 14.53 GB | Omega-Factory measured **DEGRADED**: MATH-500 **−8.0 pp** vs BF16 |
| `q2_k` | 8.81 GB | **DEGRADED**: ARC-C −17.5 pp, GSM8K −24.0 pp — unusable for a reasoning model |
| Q8_0 | 25.49 GB | does not fit your disk/RAM |

Rule of thumb from two independent measurement sets: the 4→3 bit step roughly **doubles** divergence on this model. **Stay at 4-bit.**

Suggested split with the 13.58 GB QAD build:

- `--n-cpu-moe 22` → CPU holds 22 × ~340 MB ≈ **7.5 GB**; GPU holds 16 × 340 MB + 0.67 GB non-expert ≈ **6.1 GB**
  → fits in 7.6 GB VRAM with ~1 GB spare.
- `--n-cpu-moe 24` is safer (GPU ≈ 5.4 GB, CPU ≈ 8.2 GB).
- Keep CPU-resident expert weights ≤ ~8 GB so they stay in RAM rather than thrashing to your SSD.

### KV cache (calculated from the GGUF header)

Only 10 of 40 layers are attention → KV grows slowly with context. Per token: 512 (K+V per layer) × 10 layers.

| Context | f16 | q8_0 | q4_0 |
|---|---|---|---|
| 32 K | 671 MB | 357 MB | 189 MB |
| 65 K | 1.34 GB | 713 MB | 377 MB |
| 131 K | 2.68 GB | 1.43 GB | 755 MB |

Conv recurrent state is a constant ~480 KB regardless of context.
→ **Use q8_0 KV at ≤32 K context.** f16 KV at 131 K would not fit alongside the weights.

### Known issues to expect

1. `lfm2.5:24b` tags declare **no renderer/parser** → thinking is not split out and tool calls are not parsed.
   Fix with a Modelfile:
   ```
   FROM lfm2.5:24b-a2b-q4_0
   RENDERER lfm2
   PARSER lfm2-thinking
   ```
   (The `lfm2.5:8b` tag *does* declare them; only the 24b ones are missing.)
2. **Do not re-quantize the QAD build with imatrix** — Liquid AI: *"imatrix scales make it worse."*
3. `--jinja` is mandatory in llama.cpp, else the chat template breaks.
4. Known upstream issue: LFM2.5-24B intermittently emits Qwen3-Coder-style `<tool_call>` XML that the LFM2.5 parser drops
   (llama.cpp #30490, open).
5. Do **not** build llama.cpp with `-DGGML_AMX=ON` — it breaks LFM2 CPU-only inference (#19184). Your 155H has no AMX anyway.

---

## 7. The 500B-on-a-laptop question (research summary)

Four parallel research agents were dispatched: (a) llama.cpp layer-streaming mechanics, (b) academic out-of-core systems,
(c) real 500B+ consumer-hardware reports, (d) LFM2.5-24B specifically on your box.

### How it actually works

llama.cpp does **not** implement "load one transformer layer at a time from SSD" as a user-space loop. Three real mechanisms:

| Mechanism | What moves | Notes |
|---|---|---|
| `mmap` (default) | Whole file mapped; kernel pages in/out on demand | The OS decides residency. Works for models >> RAM. |
| `--n-cpu-moe` / `--cpu-moe` | Expert FFN tensors pinned to CPU buffers | **The mechanism you want.** Only routed experts are read per token. |
| `--moe-cache-mib N` | VRAM LRU cache of individual experts | New (llama.cpp PR #29887, Oct 2026). Only *misses* cross PCIe. |

True user-space layer streaming exists in other projects: **AirLLM** (one layer resident in VRAM at a time; DeepSeek-V3 671B in
~12 GB VRAM), **colibri**, **LLM in a Flash** (Apple, ACL 2024 — no code released), **FlexGen** (archived Dec 2024),
**PowerInfer** (hot/cold *neurons* in dense FFNs — needs ReLU-family sparsity, so not Llama/Qwen/Mistral).

### The physics wall

SSD-LLaMA (arXiv 2609.18110) measured **8.89 GB of SSD reads per generated token** for a 284B model with 8 active experts
(→ 5.93 GB with rANS compression). Scale to 500B–1T: ~5–9 GB/token. On a PCIe 4.0 NVMe at 2 GB/s that is **0.5–1.4 tok/s
before any compute**.

Measured reference points:

| Setup | Model | Result |
|---|---|---|
| 128 GB RAM + 24 GB VRAM + 7.3 GB/s NVMe | Kimi K2 1T | **0.42 tok/s** |
| 25 GB laptop, ~1 GB/s disk | GLM-5.2 744B | **0.05–0.1 tok/s** |
| 8 GB VRAM + 16 GB RAM (RTX 5060) | DeepSeek-V4.1-Flash 552B | **2.4 tok/s** |
| 8 GB VRAM + 64 GB RAM | gpt-oss-120b | **25.6 tok/s** (needs 64 GB RAM) |
| 8 GB VRAM laptop GPU + 32 GB RAM | Qwen3.8-27B IQ2_XXS | **13.1 tok/s** |
| 8 GB VRAM + 15 GB RAM (**your box**) | 500B MoE | **~0.05–0.3 tok/s — demo only** |

**Verdict:** a 500B model on your box is a *demo*, not a tool — roughly 1 token per 3–20 seconds. The reason is not disk speed
but **RAM capacity**: at 16 GB you hold ~6 % of a 250 GB model, so essentially every token is a cold read. The 2024–2026
consensus is that the "cold" tier should be **CPU DRAM**, not SSD, because PCIe is 10–30× faster than any SSD.

**The best use of your 8 GB VRAM + 15 GB RAM:** a 100–120B MoE (gpt-oss-120b MXFP4, 61 GB) if you can add RAM, or a 27–35B
MoE at 13–40 tok/s as-is. LFM2.5-24B-A2B is a good fit for your box because its 97.8 % expert weight fraction makes
`--n-cpu-moe` split it cleanly.

---

## 8. Recommended commands

### LFM2.5-24B on your 4070 (Ollama path)

```bash
# one-time: build a model with the right renderer/parser
cat > ~/Modelfile.lfm25 <<'EOF'
FROM lfm2.5:24b-a2b-q4_0
RENDERER lfm2
PARSER lfm2-thinking
EOF
ollama create lfm25-24b -f ~/Modelfile.lfm25

# run with expert offload (24b has 38 MoE layers; 22 on CPU ≈ 7.5 GB RAM, ≈ 6.1 GB VRAM)
export LLAMA_ARG_N_CPU_MOE=22
export GGML_OP_OFFLOAD_MIN_BATCH=1
export OLLAMA_KV_CACHE_TYPE=q8_0
export OLLAMA_CONTEXT_LENGTH=32768
ollama run lfm25-24b
```

### Same thing via llama.cpp directly (more control, better perf)

```bash
llama-server \
  -m LFM2.5-24B-A2B-QAD-Q4_0.gguf \
  -ngl 99 --n-cpu-moe 22 \
  -c 16384 -b 2048 -ub 512 \
  -ctk q8_0 -ctv q8_0 \
  -fa on --jinja \
  --temp 0.1 --top-k 50 --repeat-penalty 1.05 \
  --host 127.0.0.1 --port 8080
```

Add `--no-repack` if the model ever exceeds RAM.

### Enabling the rootless Ollama 0.40.8

```bash
systemctl --user daemon-reload
systemctl --user enable --now ollama-rootless
export OLLAMA_HOST=127.0.0.1:11435
```

---

## 9. Open items

- System-wide Ollama still 0.32.9 (needs sudo to replace). Rootless 0.40.8 is ready and working.
- `lfm2.5:24b-a2b-q4_0` pull was in progress at 9.6 MB/s (~20 min remaining) at time of writing.
- 93 GB Docker Desktop VM not removed (destructive; needs sudo for the apt part).
