# DSpark vs DFlash — verdict for LFM2.5-24B-A2B on this laptop

## What each is

| | DSpark | DFlash |
|---|---|---|
| Upstream spec type | `draft-dspark` (PR #27383, merged 20 Aug 2026) | `draft-dflash` (PR #27383 family, merged 20 Aug 2026) |
| Architecture | Liquid's own: 5 full-attention layers, hidden 2048, GQA 32/8, head_dim 64, Markov head (rank 256) + confidence head, **block size 9** | A separate small model (EAGLE-3-like draft head). Drafts are published as standalone GGUFs for other architectures |
| Draft size for 24B | **633 MiB** (F16 sidecar, shares target's embeddings + LM head) | A separate draft model — typically 0.3–1.5 GB |
| LFM2.5-24B drafter? | ✅ `LiquidAI/LFM2.5-24B-A2B-DSpark-GGUF` (official, sha256-verified) | ❌ **None exists.** DFlash drafters found for Qwen3.6-35B, MiMo-V2.5-Pro, Ornith-397B, DeepSeek-V4-Flash, Qwen3.8-27B — **none for LFM2.5-24B** |
| LFM2.5 family DFlash? | N/A (DSpark is the official drafter) | Only for `LFM2.5-1.2B-Instruct` (safetensors, 524 MB) and `LFM2.5-VL-3B` (GGUF 1527 MB) — **neither matches the 24B target** |
| Ollama support | ✅ via `DRAFT <path>` in Modelfile (verified) | ❌ not in Ollama 0.40.8's spec-type list (it IS in upstream llama.cpp's list) |
| VRAM cost | 633 MiB (shares embeddings/LM head) | Would be a full separate model's VRAM cost |

## Verdict

**For LFM2.5-24B-A2B: DSpark is the only official option. DFlash is not applicable.**

There is no DFlash drafter for the 24B, and DFlash drafters for other architectures
(Qwen3.6, MiMo, DeepSeek V4, etc.) use different tokenizers/vocabs and cannot be
paired with an LFM2.5 target. DFlash is a separate speculative decoding method
(EAGLE-3-style trained draft head) that requires a model-specific drafter — and
Liquid AI has not published one for the 24B.

## DSpark — should you use it?

**Measured on this box: NO (net loss).**

| config | decode t/s | vs baseline |
|---|---|---|
| baseline (no draft) | 71.5 | — |
| DSpark n_max=4 | 62.9 | −12 % |
| DSpark n_max=9 | 36.4 | **−49 %** |
| Through Ollama service | +1.1 % | noise |

**Why it loses:** verifying K+1 tokens reads the *union* of active experts — up to
4(K+1) per layer. LFM2.5 has 64 experts (vs the 8B's 32), so the union is larger.
Cost grows ~linearly in K while acceptance only reaches ~3.5 tokens. On a MoE,
spec-decode multiplies your bandwidth problem instead of solving it.

**Plus:** the 633 MiB drafter steals ~2 of your 40 target layers of VRAM, and the
Ollama service shows +1.1% (noise) when alternating baseline vs drafter.

## Recommendation

**Do not enable DSpark on this hardware for this model.** The drafter is installed
and checksum-verified, wired into Ollama via the `DRAFT` directive, and ready to
test with `n_max=4` (the only roughly-neutral setting) — but the evidence says it
loses. Spend the VRAM on the target instead.

If you want to try it on the 24B specifically (the 8B is a proxy, and the 24B's
64-expert union is larger — it could be worse), use `--spec-draft-n-max 4` and
measure `draft_n` / `draft_n_accepted` from the server's `timings` response. Do NOT
use the recommended `n_max=9` (−49%).

The far bigger win: **direct `llama-server` is 4.6× faster than Ollama** on identical
weights (71–72 tok/s vs 15.7 tok/s), because Ollama's runner adds a 32768 default
context and its own ngl heuristic.

## Commands (for reference)

**Direct llama-server with DSpark (if you want to test):**
```bash
export LD_LIBRARY_PATH=/home/parshu/.local/lib/ollama-new:/home/parshu/.local/lib/ollama-new/cuda_v13
export GGML_BACKEND_PATH=/home/parshu/.local/lib/ollama-new/cuda_v13/libggml-cuda.so
/home/parshu/.local/lib/ollama-new/llama-server \
  -m /home/parshu/.ollama/models/blobs/sha256-89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa \
  -md /home/parshu/.ollama/models/draft/LFM2.5-24B-A2B-DSpark-F16.gguf \
  --spec-type draft-dspark --spec-draft-n-max 4 --spec-draft-n-min 0 \
  -ngl 99 -ngld 99 -fa on -c 8192 --n-cpu-moe 26 -t 8 \
  --host 127.0.0.1 --port 11436 --no-webui
```

**Ollama (with DSpark):**
```bash
printf 'FROM lfm2.5:24b\nDRAFT /home/parshu/.ollama/models/draft/LFM2.5-24B-A2B-DSpark-F16.gguf\nRENDERER lfm2\nPARSER lfm2-thinking\n' > Modelfile.dspark
ollama create lfm25-24b-dspark -f Modelfile.dspark
# per-request: options {"draft_num_predict": 4}
```
EOF
echo "written"; wc -l /home/parshu/llm-edge-setup/benchmarks/DSpark-vs-DFlash.md