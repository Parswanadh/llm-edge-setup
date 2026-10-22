# llm-edge-setup

Reproducible setup for running **LFM2.5-24B-A2B** (MoE, 24B total / 2.45B active) on a
consumer laptop with 8 GB VRAM, plus the Docker/Ollama housekeeping that goes with it.

Target machine (all values measured, not assumed):

| Component | Value |
|---|---|
| OS | Ubuntu 24.04.4 LTS |
| CPU | Intel Core Ultra 7 155H (16 cores / 22 threads, AVX2, **no AVX-512, no AMX**) |
| RAM | 15 GiB (+ 26 GiB swap: 22.7 G zram + 4 G swapfile) |
| GPU | RTX 4070 Laptop (Max-Q), 8188 MiB VRAM, compute capability **8.9** |
| Disk | NVMe, 937 G |
| Ollama | 0.32.9 system → **0.40.8** rootless |

---

## The core trick: expert-level CPU offload

LFM2.5-24B-A2B is `lfm2moe`: 40 blocks, **64 experts (top-4)**, 10 GQA attention layers +
30 short-conv layers, hidden 2048, 131 072 ctx.

**~97.8 % of all weights are routed-expert FFN tensors.** So splitting the model between
VRAM and RAM is nearly free in quality terms.

llama.cpp exposes `--n-cpu-moe N` / `-ncmoe N`:

> keep the Mixture of Experts (MoE) weights of the **first N layers** in the CPU

It is implemented as a tensor-buffer-type override matching
`\.ffn_(up|down|gate|gate_up)_(ch|)exps` — and LFM2.5's tensors are named
`blk.N.ffn_{up,down,gate}_exps.weight`, so they match exactly.

Only the **top-4 of 64** experts fire per token, so only the selected expert slices are
ever read. Attention, conv, router, embeddings and the KV cache stay in VRAM.

### Why this works in Ollama even though `num_cpu_moe` was never merged

Ollama PR #16688 (`num_cpu_moe`) was **closed unmerged** (`merged: false`). Neither
0.32.9 nor 0.40.8 contains that string.

But Ollama serves every GGUF through a `llama-server` **subprocess**, and
`llm/llama_server.go` does:

```go
func SetupLlamaServerCommandEnv(cmd *exec.Cmd, exe string, gpuLibs []string, extraEnvs map[string]string) {
    cmd.Env = os.Environ()   // full environment inherited
}
```

llama-server reads `LLAMA_ARG_*` for every flag. So the mechanism is available anyway.

**Verified on this machine:**

| Test | Result |
|---|---|
| `LLAMA_ARG_N_CPU_MOE=4` in ollama's `/proc/<pid>/environ` | present |
| same var in the `llama-server` child's `/proc/<pid>/environ` | **present** |
| `LLAMA_ARG_OVERRIDE_TENSOR` via env → llama-server logged its tensor-override warning | **confirmed** |
| env `N=20` vs CLI `--n-cpu-moe 20` | **byte-identical** (CUDA0 = 1333.6 MiB, CPU_Mapped = 3780.4 MiB) |
| `lfm2.5:8b` via Ollama 0.40.8 | **73.5 tok/s**, correct `<think>` output |

---

## Layout

```
systemd/ollama-rootless.service   rootless Ollama 0.40.8 with MoE offload env baked in
modelfiles/                       Modelfiles (renderer/parser + sampling)
scripts/upgrade-ollama.sh         0.32.9 -> 0.40.8 system upgrade (sudo, has rollback)
scripts/fetch-model.sh            resumable chunked GGUF downloader with sha256 verify
scripts/test-harness.sh           unit tests for the upgrade script
scripts/e2e-test.sh               end-to-end tests for the upgrade script
scripts/auto-push.sh              continuous commit+push loop
benchmarks/                       measured results
llama-tq/                         TurboQuant KV-cache fork notes
docs/                             full analysis write-up
```

---

## Quick start

```bash
# 1. Rootless Ollama 0.40.8 with MoE expert offload
cp systemd/ollama-rootless.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now ollama-rootless
export OLLAMA_HOST=127.0.0.1:11435

# 2. Fetch the model (13.58 GB, resumable, hash-verified)
bash scripts/fetch-model.sh

# 3. Build a model with the correct renderer/parser
#    (the lfm2.5:24b* registry tags ship with NONE, so thinking is not
#     split out and tool calls are not parsed)
ollama create lfm25-24b -f modelfiles/Modelfile.lfm25-24b

# 4. Run
ollama run lfm25-24b
```

### System-wide upgrade (needs sudo)

```bash
bash scripts/upgrade-ollama.sh --dry-run     # plan
sudo bash scripts/upgrade-ollama.sh           # do it
sudo bash scripts/upgrade-ollama.sh --rollback
```

The script snapshots the model store, backs up the binary + systemd unit, stages and
**pre-flight tests** the new build before swapping, verifies the store is byte-identical
afterwards, and auto-rolls-back on any failure. The official `install.sh` is worse here:
it `rm -rf`s `lib/ollama` *before* downloading and blindly overwrites the unit.

---

## Why the system-wide upgrade is optional

The rootless instance is the recommended path for MoE models because only it has
`LLAMA_ARG_N_CPU_MOE` and `GGML_OP_OFFLOAD_MIN_BATCH` set. The system service has no
such env, so a MoE model there falls back to whole-layer CPU offload.

| Instance | Port | Store | MoE env |
|---|---|---|---|
| system `ollama.service` | 11434 | `/usr/share/ollama/.ollama/models` | no |
| rootless `ollama-rootless` | 11435 | `~/.ollama/models` | **yes** |

The rootless store is seeded with **symlinks** to the 38 shared blobs, so it sees every
existing model at zero extra disk cost.

---

## TurboQuant KV cache

`llama-tq` (LL4nc33 fork) adds TurboQuant+ KV cache types on top of upstream llama.cpp:

```
ktq1_1 ktq2_1 ktq3_1 ktq4_1        (Hadamard rotation + codebook)
vtq1_1 vtq2_1 vtq2_2 vtq2_3 ...    (trellis variants: vtq*_2s, vtq*_3s)
```

TurboQuant's own docs warn that **head_dim = 64** models may crash or degrade with turbo V
compression (the Walsh-Hadamard transform needs d >= 128). **LFM2.5-24B has head_dim = 64**
(2048 / 32 heads), so turbo3/turbo4 must be validated on this model before use — see
`benchmarks/`.

See `llama-tq/` for the build notes and the exact working invocation.

---

## Docker notes

The machine runs **three** Docker packages: `docker-ce` 29.6.0 (live), `docker-desktop`
4.79.0 (not running, 93 GB of dead VM disk), and `docker.io` 29.1.3 (redundant).

The Docker CLI's active context was `desktop-linux` — a dead socket — so **every plain
`docker` command failed**. Fixed with `docker context use default`.

**Podman is not worth migrating to:** it stores images with the same overlayfs layout, so
it saves no disk; the 93 GB problem is Docker Desktop's VM, which Podman has no equivalent
of. It would also break the 4 active compose projects across 9 networks.

See `docs/DOCKER_OLLAMA_ANALYSIS.md` for the full consumption breakdown and reclamation plan.
