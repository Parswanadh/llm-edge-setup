# Prompt Caching, Batching & Context Optimization — Research Summary

Full report at `/home/parshu/research-prompt-caching.md` (sources cited).

## 1. Prompt Caching / KV Cache Reuse in llama.cpp

**Three layers of reuse:**
1. **Per-slot prompt cache** (`--cache-prompt`, default on): slot compares tokens to the previous completion; evaluates only the unseen suffix.
2. **Host-RAM prompt cache** (`--cache-ram N`, default 8192 MiB; PR #16391): when a slot goes idle, its prompt + checkpoints are saved to RAM and can be restored into another slot. `--cache-idle-slots` (default on) publishes idle slots to RAM.
3. **Context checkpoints** (`--ctx-checkpoints`, default 32): intermediate KV snapshots so a partial prefix match can be restored without full re-prefill. `--cache-reuse N` (default 0) sets min chunk size to attempt reuse via KV shifting.

**Prefix caching across requests:** Yes, but via host-RAM cache + slot affinity, not a global radix tree (that's SGLang). Checkpoints are slot-local under `-np > 1`; `--cache-idle-slots` publishes idle slots to RAM.

**Measured impact:** Hermes measured **346k cached vs 78k newly-prefilled tokens** with a byte-stable prefix. ADR 007 (LlamaCppEx) benchmarked 4-turn chat: **1.23× avg / 1.31× median** speedup with same-slot prefix cache.

**⚠️ LFM2 caveat (issue #16491):** LFM2/LFM2-MoE KV cache "doesn't support restoring the cache to arbitrary positions"; the server logs `forcing full prompt re-processing due to lack of cache data` on every turn. Workaround: split the prompt and run a pre-completion with `n_predict=1` to seed checkpoints. PRs #24785 and #26198 add recurrent shrink/expand + `--cache-reuse-hybrid` for hybrid models. **Must verify on LFM2.5-24B.**

## 2. Continuous Batching — Not Applicable

Iteration-level scheduling (vLLM/SGLang) helps concurrency ≥2. At 1 user there's nothing to batch. OpenCode/Claude Code send one request at a time → set `-np 1`. The one indirect relevance: multi-slot is needed for cross-slot prefix reuse.

## 3. Semantic Caching — Weakly Applicable

Cache LLM responses by embedding similarity (GPTCache, RedisVL SemanticCache). Risks: false positives on near-miss code prompts; adds embedding model + Redis dependency; does **not** reduce prefill of shared system prompt (that's prefix caching). Could only help for genuinely repeated identical questions. **Not recommended as primary lever; untested by us.**

## 4. Token Batching (`-b` / `-ub`)

- `-b` = logical max batch (default 2048); `-ub` = physical micro-batch (default 512). Physical ≤ logical.
- For CPU+GPU MoE: prompt processing is the bottleneck and is sensitive to batch size. Recommendation: set `-b` and `-ub` equal and higher than defaults (e.g., 4096/4096) for large MoE models, accepting more compute-buffer VRAM.
- **Untested for LFM2.5 — must sweep.**

## 5. Prefix Caching / Shared Prefix Optimization (coding agents)

**The problem:** OpenCode/Claude Code send an identical system prompt + tool schemas every request (10–20k+ tokens). Re-prefilling dominates latency.

**Proven rules:** (1) keep model loaded (`keep_alive -1`); (2) keep `num_ctx` identical across requests; (3) byte-stable prefix — no dynamic timestamps; (4) stable tool-schema ordering; (5) stable prefix first, variable user content last.

**Open-source solutions:** vLLM automatic prefix caching (hash-based block cache); SGLang (radix attention, ~29% faster on shared prefixes); Hermes "keep prefix warm" watcher.

## 6. Prompt Compression (LLMLingua)

Microsoft's coarse-to-fine compression: up to **20× compression with ~1.5-point loss** on GSM8K/BBH. Usable for compressing long RAG/repo context before sending to the local model. Requires running a small compressor model alongside; token-level compressed prompts are unreadable and may hurt code correctness. **Untested on LFM2.5 or coding tasks.**

## 7. Ollama-Specific Caching

- `OLLAMA_KEEP_ALIVE` / `keep_alive`: controls model residency (default 5 min). Set `-1` to keep loaded indefinitely.
- KV cache across requests: implicit exact-prefix match while model loaded.
- `num_ctx`: default 2048; must be consistent across requests; parallel requests multiply it.
- KV quantization (`q8_0`/`q4_0`) requires Flash Attention enabled.

## Summary: Proven vs. Untested

| Lever | Status | Expected impact |
|---|---|---|
| Keep model loaded (`keep_alive -1`) | Proven (Ollama) | Avoids reload; enables implicit prefix cache |
| Byte-stable prefix | Proven pattern | Largest TTFT win for coding agents |
| `num_ctx` consistency | Proven (Ollama) | Prevents silent recompute |
| llama.cpp `--cache-ram` + checkpoints | Proven on dense models; **LFM2 affected (#16491)** | 1.2–1.3×+ on multi-turn; must test |
| KV quantization q8_0/q4_0 + flash attn | Proven | ~50–75% KV VRAM |
| MoE expert offload to CPU | Proven (benchmarks) | Fits 24B in 8 GB VRAM |
| `-b`/`-ub` tuning | **Untested for LFM2.5** | Sweep needed |
| Continuous batching | Not applicable (single user) | None |
| Semantic caching (GPTCache/RedisVL) | **Untested; risky for code** | Only exact-repeat questions |
| LLMLingua compression | **Untested on coding tasks** | Could help long context; accuracy risk |
| `--cache-reuse-hybrid` | New (PR #29918) | Potentially fixes LFM2 hybrid cache; test |

**Bottom line:** The biggest, lowest-risk wins are (a) byte-stable prefixes + keeping the model loaded, (b) KV quantization + MoE expert offloading to fit in 8 GB, and (c) verifying whether LFM2.5's hybrid cache actually reuses (issue #16491 lineage). Everything else is speculative until measured on this hardware.

---

## 9. What's Actually Configured in the Service

The direct llama-server service (`systemd/llfm25-24b.service`) currently runs with:

```
-c 131072 -fa on --jinja -t 8 -ctk ktq3 -ctv vtq3 --no-tq-deferred-k
```

**Not yet explicitly set (using defaults):**
- `--cache-prompt` → default `on` (per-slot prompt cache, only unseen suffix re-evaluated)
- `--cache-ram` → default `8192` MiB (host-RAM prompt cache for idle slots)
- `--ctx-checkpoints` → default `32` (intermediate KV snapshots)
- `--cache-reuse` → default `0` (disabled — min chunk size for prefix reuse via KV shifting)
- `-b` / `-ub` → defaults `2048` / `512`
- `--cache-idle-slots` → default `on` (publishes idle slots to RAM cache)

**To enable prefix caching more aggressively, add to the service:**
```
--cache-ram 16384 --ctx-checkpoints 64 --cache-reuse 256
```

**To optimize batch throughput (MoE prefill), add:**
```
-b 4096 -ub 2048
```

**For the LFM2 hybrid cache issue (#16491), try:**
```
--cache-reuse-hybrid
```
This is new (PR #29918) and may fix the "forcing full prompt re-processing" problem for hybrid/recurrent models. **Untested on LFM2.5-24B.**

## 10. Recommended Service Update

```ini
ExecStart=/home/parshu/.local/lib/llama-tq/merged/llama-server \
  -m /home/parshu/.ollama/models/blobs/sha256-89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa \
  -ngl 99 --n-cpu-moe 24 -c 131072 -fa on --jinja -t 8 \
  -ctk ktq3 -ctv vtq3 --no-tq-deferred-k \
  --cache-prompt --cache-ram 16384 --ctx-checkpoints 64 --cache-reuse 256 \
  -b 4096 -ub 2048 \
  --host 127.0.0.1 --port 11436 --no-webui \
  --api-key lfm25-secret --alias lfm25-24b
```

**Status:** Configured but not yet benchmarked. The `--cache-reuse` and `--cache-reuse-hybrid` flags are the most promising for coding agents (system prompt + tool schemas are identical every request). Must verify that LFM2.5's hybrid cache actually reuses (issue #16491 lineage) — if it doesn't, the workaround is seeding checkpoints via a pre-completion with `n_predict=1`.
