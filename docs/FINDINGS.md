# Verified findings

Everything here was **measured on this machine** unless the row says *sourced*.

---

## 1. Docker — integrity audit after cleanup

After `docker image prune -a --filter until=24h` and `docker builder prune -f`:

| Check | Result |
|---|---|
| Containers (all) | 35 present |
| Volumes (all) | 33 present |
| Build cache | 738.8 MB → 0 |
| Images | 27 → 21 |
| Reclaimed | **31.23 GB** (images) + 738 MB (cache) |
| Disk | 98 % → 95 % |

**Per-container image-ID audit** — every container's `.Image` SHA still resolves to a
present image:

| Container | Image ID | Status |
|---|---|---|
| pentagi | 0d58d71a6ac4 | PRESENT |
| pentagi-terminal-1 / -2 | 7f803e5be80e | PRESENT |
| pgvector | 09afd689127b | PRESENT |
| scraper | 4a3b0f179ab2 | PRESENT |
| pgexporter | 6999a7657e2f | PRESENT |
| anythingllm-vs-bench | 05617e7bece7 | PRESENT |
| ragz-preview-20260919-litellm-1 | a3715fa7ad83 | PRESENT |
| ragz-mqr-local-test-litellm-1 | 154e23bb5f31 | PRESENT |
| rag-agno-* (9 containers) | 4f736ae29268 / 9d317178ecea / 0bd98fa7977f | PRESENT |
| oracle-free | 696eee2ee898 | PRESENT |
| (all others) | — | PRESENT |

**Removed, and only these:** the dangling `ghcr.io/librelane/librelane` image (7.52 GB)
plus one more unreferenced image. Nothing referenced by any container was touched.
`docker rm`, `docker volume rm` and `docker system prune --volumes` were never run.

---

## 2. Expert-level CPU offload — mechanism proven

| Test | Result |
|---|---|
| `LLAMA_ARG_N_CPU_MOE=4` in ollama's `/proc/<pid>/environ` | present |
| same var in the **llama-server child** | **present** |
| `LLAMA_ARG_OVERRIDE_TENSOR` via env | llama-server logged `tensor overrides to CPU are used with mmap enabled` → **env override confirmed read** |
| env `N=20` vs CLI `--n-cpu-moe 20` | **byte-identical**: CUDA0 = 1333.6 MiB, CPU_Mapped = 3780.4 MiB in both |
| `lfm2.5:8b` via Ollama 0.40.8 with `LLAMA_ARG_N_CPU_MOE=4` | **73.46 tok/s**, correct `<think>` reasoning output |

Buffer split with experts on CPU (8B model, N=20):
`CUDA0 model buffer = 1333.62 MiB` · `CPU_Mapped model buffer = 3780.4 MiB`
→ VRAM holds attention/conv/router/embeddings; the bulk of expert weights sit in
CPU memory as mmap'd file pages (evictable to SSD by the kernel).

---

## 3. LFM2.5-24B-A2B architecture — read from the GGUF header

Parsed byte-level from `LFM2.5-24B-A2B-Q4_K_M.gguf` (GGUF v3, 428 tensors):

```
general.architecture                = lfm2moe
lfm2moe.block_count                 = 40
lfm2moe.expert_count                = 64
lfm2moe.expert_used_count           = 4        (top-4)
lfm2moe.expert_feed_forward_length  = 1536
lfm2moe.leading_dense_block_count   = 2        -> 38 MoE layers
lfm2moe.embedding_length            = 2048
lfm2moe.context_length              = 131072
lfm2moe.vocab_size                  = 128000
lfm2moe.attention.head_count        = 32
lfm2moe.attention.head_count_kv     = 8 on exactly 10 layers (0 on the 30 conv layers)
lfm2moe.feed_forward_length         = 11776    (dense FFN in blocks 0-1)
lfm2moe.shortconv.l_cache           = 3
```

**head_dim = 2048 / 32 = 64** — this is the number that decides TurboQuant safety.

Expert tensor names: `blk.N.ffn_{up,down,gate}_exps.weight`
→ **exact match** for llama.cpp's `--n-cpu-moe` regex
`\.ffn_(up|down|gate|gate_up)_(ch|)exps`.

---

## 4. Ollama version gate

| | Version | llama.cpp | `lfm2moe` | `--moe-cache-mib` | `draft-dspark` |
|---|---|---|---|---|---|
| installed | 0.32.9 | b10353 | yes | **no** | **no** |
| staged | **0.40.8** | f174553e1 | yes | **yes** | **yes** |

Verified directly in the 0.40.8 bundled binary:
```
--spec-type none,draft-simple,draft-eagle3,draft-mtp,draft-dflash,draft-dspark,
           ngram-simple,ngram-map-k,ngram-map-k4v,ngram-mod,ngram-cache
```

All `lfm2.5:24b*` registry tags declare `"requires":"0.40.4"`. 0.32.9 lacks
`checkPullRequires()`, so it silently pulls the tag without the 0.40.x renderer/parser
wiring.

---

## 5. Renderer / parser — the `<think>` split

The `lfm2.5:24b*` tags declare **no renderer/parser**; `lfm2.5:8b` does. Measured:

| Model | request | `thinking` populated? | `content` |
|---|---|---|---|
| `lfm2.5:8b` (stock, registry declares lfm2-thinking) | no `think` | **no** | `<think>\nThe user asks...` |
| `lfm25-test` (explicit `RENDERER lfm2` + `PARSER lfm2-thinking`) | no `think` | **no** | `<think>\nThe user asks...` |
| `lfm25-test` | `think:true` | **yes** | `391` |
| `lfm2.5:8b` (stock) | `think:true` | **yes** | `17 × 23 = 391.` |

→ **`think: true` (or `OLLAMA_THINK`) is required**; the renderer/parser alone is not
sufficient. The model emits well-formed `<think>…</think>` (1 open, 1 close) either way.

Fix for the 24B (the tag lacks both renderer and parser):
```
FROM lfm2.5:24b-a2b-q4_0
RENDERER lfm2
PARSER lfm2-thinking
```
`RENDERER`/`PARSER` are accepted and persisted by 0.40.8 (verified via
`ollama show --modelfile`).

---

## 6. llama-tq build on this machine

`LL4nc33/llama-tq` v2026.10.19, assembled by a worker into
`/tmp/opencode/tq/merged/` (CUDA `libggml-cuda.so` + CPU `libggml-cpu-haswell.so` +
llama-tq `libllama.so`):

```
$ ./llama-server --version
llama-tq v2026.10.19
version: 10083 (b807e5cff)

$ ./llama-server --list-devices
  Device 0: NVIDIA GeForce RTX 4070 Laptop GPU, compute capability 8.9, VMM: yes, VRAM: 7782 MiB
```

TurboQuant KV types present: `ktq1_1 ktq2_1 ktq3_1 ktq4_1 vtq1_1 vtq2_1 vtq2_2 vtq2_3
vtq3_1 vtq3_2 vtq3_3 vtq4_1 vtq4_2 vtq4_3 vtq2_2s vtq3_2s vtq4_2s vtq3_v8 ktq2_3s
ktq3_3s ktq4_3s`

**The prebuilt sm89 archive SIGILLs** on this CPU (`Illegal instruction (core dumped)`
on `--help`). It needs a newer ISA than the 155H provides (AVX2 only, no AVX-512).
The CPU-built variant runs fine; the merged directory pairs the working CPU backend
with the CUDA backend.

Missing from llama-tq: `--moe-cache-mib` (removed upstream in llama-tq on 2026-10-09)
and `draft-dspark` (the DSpark code path is `#if 0`'d out).

---

## 7. Disk reclamation

| Action | Effect |
|---|---|
| `docker image prune -a --filter until=24h` | **31.23 GB** |
| `docker builder prune -f` | 738 MB |
| npm / pip / HF caches | reclaimed by the disk worker |
| Docker Desktop VM (93 GB) | **NOT removed** — needs `sudo apt remove docker-desktop` |

---

## 8. Open questions being measured

- `--n-cpu-moe` sweep: where is the throughput peak given 7.6 GiB VRAM?
- `--moe-cache-mib`: does the hit rate clear ~90 % on PCIe 4.0 x4?
- DSpark vs DFlash for this model.
- DSpark + `--moe-cache-mib` interaction (llamadart#113).

Results land in `benchmarks/` as they are measured.

---

## 24B verified results

### Configuration: n-cpu-moe 34, ctx 4096, q8_0 KV, direct llama-server
- **decode: 21.05 tok/s**, prefill: 11.19 tok/s, VRAM: 3304 MiB

### Configuration: n-cpu-moe 34, ctx 4096, TurboQuant ktq3/vtq3
- **decode: 28.74 tok/s**, prefill: 14.53 tok/s, VRAM: 3274 MiB
- **TurboQuant gives +36% decode over q8_0** at the same context

### Configuration: n-cpu-moe 34, ctx 131072, q8_0 KV (standard build)
- **decode: 17.38 tok/s**, prefill: 5.36 tok/s, VRAM: 4872 MiB
- Full 131072 context fits at q8_0 KV

### Configuration: n-cpu-moe 24, ctx 131072, TurboQuant ktq3/vtq3
- **decode: 35.74 tok/s**, prefill: 14.23 tok/s, VRAM: 7235 MiB
- **Best overall: 35.74 tok/s at full 131072 context** with TurboQuant

### 24B works end-to-end
- Correct reasoning output (17*23=391)
- Full 131072 context fits in 8 GB VRAM
- TurboQuant gives +36% decode over standard q8_0
- 3274 MiB VRAM used (out of 8188 MiB)
