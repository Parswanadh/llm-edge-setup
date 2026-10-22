# Speculative decoding verdict: **NO** for this model on this hardware

Measured on this box with the bundled llama.cpp (f174553e1), RTX 4070 Laptop 8 GB.

The DSpark drafter is real, official, and works. It is still the **wrong tool here**.

---

## What exists

| Item | Detail |
|---|---|
| Drafter repo | `LiquidAI/LFM2.5-24B-A2B-DSpark-GGUF` (official LiquidAI) |
| File | `LFM2.5-24B-A2B-DSpark-F16.gguf`, 663 691 296 B (633 MiB) |
| SHA256 | `0cd847ca049aeabf53cb41d62091ae20eb50245cf89594c75af204784a1b1a0f` ✔ verified |
| Local path | `/home/parshu/.ollama/models/draft/LFM2.5-24B-A2B-DSpark-F16.gguf` |
| Metadata | `general.architecture = dflash`, `dflash.block_size = 9`, `dflash.target_layers = [3,11,19,27,35]`, `dflash.block_count = 5`, `has_confidence_head = 1`, `sample_from_anchor = 1`, vocab 128000, tokenizer `gpt2`/`lfm2` |
| Params | 327.7 M draft (BF16) — Markov head rank 256 + confidence head |
| Sidecar | token embeddings + LM head are **shared from the target** at load time |

**Not SGLang-only.** Liquid ships a llama.cpp command in its own README, and upstream
llama.cpp PR #27383 ("spec : support DSpark for LFM2 models") merged 20 Aug 2026.
The bundled 0.40.8 build's `--spec-type` list contains `draft-dspark`.

**Auto-detection:** llama.cpp reads the draft GGUF — `general.architecture == "dflash"`
plus a `markov_w1.weight` tensor ⇒ `draft-dspark`. So `--spec-type` can be omitted.

### Ollama support — better than expected
Ollama 0.40.8 `api/types.go` has `Options.DraftNumPredict` (default **4**) and
`parser/parser.go` supports a **`DRAFT <path>`** Modelfile directive. Confirmed in the
service journal:
```
llama_model_loader: - kv 25: dflash.block_size u32 = 9
load_arch_tensors: DFlash with DSpark markov head (rank = 256)
common_speculative_impl_draft_dflash: adding speculative implementation 'draft-dspark'
slot print_timing: draft acceptance = 0.56410 ( 88 accepted / 156 generated), mean len = 3.26
```

---

## Measurements

Because the 24B blob was still downloading, the 8B-A1B Q4_K_M (same `lfm2moe` arch,
same tokenizer/vocab, same drafter family, same build) was used as a hardware-faithful
proxy. Prompt: reasoning question, `temperature=0`, `n_predict=128`, `-c 4096 -fa on -t 8`.

### Config A — `-ngl 16` (16/24 layers + experts on GPU)

| case | r1 | r2 | r3 | steady | vs baseline |
|---|---|---|---|---|---|
| baseline | 60.6 | 70.8 | 72.2 | **71.5** | — |
| baseline (repeat) | 73.3 | 72.7 | 71.8 | **72.2** | — |
| DSpark `n_max=4` | 60.7 | 63.1 | 62.7 | 62.9 | **−12 %** |
| DSpark `n_max=6` | 31.9 | 69.7 | 71.7 | 70.7 | −2 % |
| DSpark `n_max=9` | 13.1 | 35.8 | 37.0 | 36.4 | **−49 %** |
| DSpark `n_max=10`→clamped 9 | – | – | 33.9 | ~34 | −53 % |

### Config B — `-ngl 16 --n-cpu-moe 22` (mirrors the live service)

| case | r1 | r2 | r3 | steady | vs baseline |
|---|---|---|---|---|---|
| baseline | 43.6 | 44.1 | 43.4 | **43.7** | — |
| DSpark `n_max=4` | 35.6 | 42.4 | 43.3 | 42.8 | −2 % |
| DSpark `n_max=6` | 35.4 | 29.3 | 26.5 | 28.0 | −36 % |
| DSpark `n_max=9` | 21.8 | 22.6 | 22.7 | 22.7 | **−48 %** |

### Config C — `-ngl 0` (all CPU): baseline 24.6/23.9/32.5 vs DSpark n4 25.6/27.7/25.4 → wash.

### Through the live Ollama 0.40.8 service (port 11435, `LLAMA_ARG_N_CPU_MOE=22`), warm, alternating

| model | r1 | r2 | r3 | steady |
|---|---|---|---|---|
| `lfm2.5:8b` (no drafter) | 15.71 | 15.71 | 15.58 | **15.67 tok/s** |
| `lfm25-dspark-test` (DRAFT) | 15.93 | 15.88 | 15.70 | **15.84 tok/s** |

→ **+1.1 %, i.e. noise.**

**Draft acceptance:** `n_max=4` → 52–56 %; `n_max=6` → 41–47 %; `n_max=9` → 29–35 %.
Mean accepted length only **3.1–3.8** tokens.

---

## Why it loses

1. **The target's verify pass is memory-bound on the *union* of active experts.**
   LFM2.5 routes 4 of 64 experts per token (24B). Verifying K+1 tokens in one batch
   touches up to `min(64, 4(K+1))` distinct experts per layer — so the verify pass reads
   roughly **K× more expert weight bytes** than a single-token step, while acceptance
   only climbs to ~3.5 tokens. Cost grows linearly in K; benefit does not. Hence
   `n_max=9` → −49 %.
2. **Acceptance is low** (29–56 %, mean len ≈ 3.3): a 328 M drafter against a 2.45 B-active
   MoE target.
3. **The recommended setting is the worst one.** Liquid's README recommends
   `--spec-draft-n-max 9` (24B) / `10` (8B, clamped to 9) — precisely the −49 % case.
   llama.cpp logs: `requested draft size (n_max=10, n_min=0) exceeds the trained block
   size 9 -- clamping to 9`.
4. **VRAM is the binding constraint and the drafter steals from it.** 633 MiB of F16
   drafter ≈ **two of the 40 target layers** of GPU residency — and target GPU residency
   is the single biggest throughput lever for a 13.58 GB model on a 7.6 GiB card.
5. **RAM is worse.** The target needs ~13.6 GB resident; the box has 15.5 GiB total with
   ~10 GiB already used. The drafter adds 633 MiB against 26 GiB of swap — and
   **swap-backed random expert reads are the worst possible access pattern**.

DSpark is tuned for H100/B300/MacBook-class, FP8, batch-offloaded, fully-HBM-resident
targets. Here the 24B is RAM/swap-bandwidth-bound and MoE-expert-union-bound, so
spec-decode converts a bandwidth problem into a worse bandwidth problem.

---

## Keeping it in place anyway

The drafter is installed, checksum-verified, and wired into Ollama via the `DRAFT`
directive, so it is one flag away:

```
FROM lfm2.5:24b-a2b-q4_0
DRAFT /home/parshu/.ollama/models/draft/LFM2.5-24B-A2B-DSpark-F16.gguf
RENDERER lfm2
PARSER lfm2-thinking
```
```bash
# per-request: options {"draft_num_predict": 4}   # max effective 9
```
Direct llama-server equivalent:
```bash
llama-server -m "$M" -md "$D" --spec-type draft-dspark --spec-draft-n-max 9 --spec-draft-n-min 0 \
  -ngl 99 -ngld 99 -fa on --host 127.0.0.1 --port 11436
```

**If you want to try it on the 24B specifically**, use `--spec-draft-n-max 4` (not 9) —
that was the only roughly-neutral setting. Re-measure on the 24B before trusting it;
the 8B is a proxy, and the 24B's 64-expert union is larger, so it could be worse.

---

## The far bigger win found alongside: bypass Ollama

Direct `llama-server` gave **71–72 tok/s** on the identical 8B model and quant that the
Ollama service served at **15.7 tok/s** — a **4.6× gap**.

The drafter work was worth it: it surfaced that the Ollama runner, not the model, was
the bottleneck. Suspected causes, to be attributed: Ollama's default 32768 context, its
own `-ngl` heuristic, and runner overhead. See `docs/OPERATIONS.md` and the
`llfm25-24b.service` unit.
