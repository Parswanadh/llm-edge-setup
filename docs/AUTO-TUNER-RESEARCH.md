# Existing Auto-Tuner / Optimizer Projects — Research

Full report at `/home/parshu/research-open-source-llm-tools.md` (40+ tools).
This is the condensed version relevant to our project.

## What exists today

| Project | URL | Auto-tunes? | Handles `--n-cpu-moe`? | Handles KV cache type? | MoE cache? | Batch/threads? | Relevance |
|---|---|---|---|---|---|---|
| **llmfit** | https://github.com/AlexsJones/llmfit | No (recommender) | No | No | No | No | Medium (hardware detection) |
| **whichllm** | https://github.com/whichllm/whichllm | No (recommender) | No | No | No | No | Medium (benchmark ranking) |
| **local-llm-autotune** | https://github.com/... | Yes (middleware) | No | Yes (F16→Q8) | No | num_batch=1024 | High |
| **llm-autotune** | https://github.com/... | Yes | No | Yes | No | Yes | High |
| **llama-optimus** | https://github.com/... | Yes (Optuna) | No | No | No | Yes (llama.cpp flags) | High |
| **Optimal Ollama** | https://github.com/... | Yes (context sweep) | No | No | No | No | Medium |
| **ollama-accelerate** | https://github.com/... | Yes (external) | No | Yes (KV) | No | Partial | High |
| **finetuna** | https://github.com/... | Partial (residency search) | No | No | No | num_batch | High |
| **llama.cpp `--fit`** | upstream | Partial (memory fit only) | No | No | No | No | High (layer offload + ctx) |
| **Ollama PR #15081** | github.com/ollama/ollama/pull/15081 | In progress | TBD | TBD | TBD | TBD | Watch |
| **TurboLLM** | https://github.com/... | Yes (llama.cpp GPU/MoE) | Yes (toggle) | No | No | Partial | High |
| **OpenJet** | https://github.com/... | Yes (auto-config) | Yes | No | No | Yes | High |
| **KTransformers** | https://github.com/kvcache-ai/ktransformers | Partial (dynamic expert update) | Indirect | No | No | No | High (MoE placement) |
| **colibri** | https://github.com/JustVugg/colibri | Partial (adaptive cache) | N/A | No | No | No | Med-High (huge MoE) |
| **LM Studio** | https://lmstudio.ai | No | Manual slider | Manual | Manual | Manual | Medium |
| **lmstudio-config-wizard** | https://github.com/... | Partial (config gen) | No | No | No | No | Medium |
| **llamafile** | https://github.com/mozilla-ai/llamafile | No (inherits --fit) | No | No | No | No | Low-Med |
| **ExLlamaV2/V3 + TabbyAPI** | https://github.com/turboderp/exllamav2 | No | N/A (EXL) | cache_mode manual | No | chunk_size manual | Low |
| **vLLM** | https://github.com/vllm-project/vllm | Partial (backend/NUMA) | No | No | No | No | Low-Med |
| **BentoML llm-optimizer** | https://github.com/bentoml/llm-optimizer | Yes (benchmark+optimize) | No | No | No | Yes (batch/TP) | Low (server-grade) |
| **GPT4All** | https://gpt4all.io | No | No | No | No | No | Low |
| **LocalAI** | https://localai.io | No (inherits --fit) | Pass-through | Pass-through | No | Pass-through | Medium |
| **llmfit** | https://github.com/AlexsJones/llmfit | No (recommender) | No | No | No | No | Medium (hardware detection) |
| **whichllm** | https://github.com/whichllm/whichllm | No (recommender) | No | No | No | No | Medium (benchmark ranking) |
| **TurboLLM** | https://github.com/... | Yes (llama.cpp GPU/MoE) | Yes (toggle) | No | No | Partial | High |
| **OpenJet** | https://github.com/... | Yes (auto-config) | Yes | No | No | Yes | High |

## Key Takeaways

1. **No single project auto-tunes all of `--n-cpu-moe`, KV cache type, MoE cache size, batch, threads, speculative decoding, and quant selection** for llama.cpp/Ollama. `--fit` (llama.cpp) only handles memory placement of unset args.
2. **Closest matches for our use case (LFM2.5-24B-A2B, 8GB VRAM + 15GB RAM):**
   - **TurboLLM** — auto-tunes llama.cpp GPU layers + MoE offload (toggle), with web UI and exportable launch command.
   - **OpenJet** — auto-configures llama.cpp for max hardware perf.
   - **local-llm-autotune / llm-autotune** — middleware that auto-sizes KV cache, switches F16→Q8 under pressure, sets num_batch=1024, manages context; works with Ollama/LM Studio.
   - **KTransformers** — dynamic expert update for MoE placement (relevant since LFM2.5 is MoE).
   - **colibri** — adaptive expert cache (relevant for huge MoE; overkill but conceptually useful).
   - **ollama-accelerate** and **finetuna** — Ollama-specific tuning (KV cache, residency search).
3. **Gap / opportunity:** A tool that combines llama.cpp `--fit` + auto-selects KV cache type (q8_0), `--n-cpu-moe`, MoE cache size, batch, threads, and speculative decoding, then benchmarks and picks best config, **does not exist yet** in open source. This is the niche.
4. **OpenCode/Claude Code integration** is manual wiring today (env vars + tool-call parsers); `ollama launch claude/opencode` and guides exist but no auto-optimization layer. `llmfit` ships an OpenClaw skill that auto-configures providers.

## Recommended Architecture for Our Tool

Reuse `--fit` for base placement; layer on top:
- KV cache type selection (q8_0 / ktq3)
- `--n-cpu-moe` sweep
- MoE cache size (or skip — PCIe x4 makes it marginal)
- Batch/threads sweep
- Speculative decoding (DSpark — test n-max=4)
- Then benchmark (like BentoML llm-optimizer / SCOOT) and persist best config
- Use llmfit-style hardware detection for "will it fit" pre-checks
- Consider integrating TurboLLM/OpenJet's MoE offload auto-fit as reference
