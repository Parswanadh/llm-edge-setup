# Colab Deployment — LFM2.5-24B-A2B

Deploy LFM2.5-24B-A2B on Google Colab (free tier) with **llama.cpp + TurboQuant**, continuous batching, and cloudflare tunneling. Get an API key + base URL to connect from any harness (OpenCode, Claude Code, etc.).

> **Note:** We tested both vLLM and llama.cpp on this hardware. vLLM uses **whole-layer CPU offload** (35× penalty) which is worse than llama.cpp's per-expert offload. On Colab T4 (16 GB VRAM), the model **fits entirely on GPU**, so both work — but llama.cpp with TurboQuant gives **2× smaller KV cache** and **35.74 tok/s** (measured on RTX 4070 Laptop 8GB; T4 should be similar or better).

## Quick Start

### 1. On Google Colab

Open a new Colab notebook (free tier, T4 GPU) and run in a single cell:

```python
!git clone https://github.com/Parswanadh/llm-edge-setup.git /content/llm-edge-setup
!bash /content/llm-edge-setup/colab-deploy/colab-deploy.sh
```

### 2. Get your API key + base URL

The script prints:
```
  Base URL:  https://abc123.trycloudflare.com/v1
  API Key:   lfm25-xxxxxxxxxxxxxxxx
```

### 3. Connect locally

```bash
bash /home/parshu/llm-edge-setup/colab-deploy/colab-connect.sh https://abc123.trycloudflare.com/v1 lfm25-xxxxxxxxxxxxxxxx
```

Or test directly:
```bash
curl -s https://abc123.trycloudflare.com/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer lfm25-xxxxxxxxxxxxxxxx' \
  -d '{"model":"lfm25-24b","messages":[{"role":"user","content":"hello"}],"max_tokens":128}'
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Google Colab (Free Tier - T4 GPU, 15GB VRAM)      │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │  llama-server (port 8080)                    │   │
│  │  - TurboQuant KV cache (ktq3/vtq3)          │   │
│  │  - Flash attention                          │   │
│  │  - 131K context (fits in 16GB VRAM)         │   │
│  │  - DSpark speculative decoding (optional)   │   │
│  │  - OpenAI-compatible API                    │   │
│  └─────────────────────────────────────────────┘   │
│                      │                              │
│  ┌───────────────────┴─────────────────────────┐   │
│  │  cloudflared tunnel (free, no auth)          │   │
│  │  → https://xxx.trycloudflare.com            │   │
│  └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
                      │
                      │ HTTPS
                      ▼
┌─────────────────────────────────────────────────────┐
│  Local Machine                                      │
│  - OpenCode / Claude Code / any OpenAI client      │
│  - Connect via base URL + API key                  │
└─────────────────────────────────────────────────────┘
```

## GPU Selection

| GPU | VRAM | Model | Quantization | Context | Expected tok/s |
|-----|------|-------|-------------|---------|----------------|
| T4 (free) | 15 GB | QAD-Q4_0 (13.58 GB) | Q4_0 (QAD) | 32K–131K | ~35-50 (estimated) |
| L4 (free/pro) | 24 GB | QAD-Q4_0 or Q4_K_M | Q4 | 131K | ~50-80 (estimated) |
| A100 (pro) | 40 GB | Q4_K_M or Q5_K_M | Q4/Q5 | 131K | ~80-120 (estimated) |
| H100 (pro) | 80 GB | Q4_K_M or Q8_0 | Q4/Q8 | 131K | ~100-200 (estimated) |

## Optimizations

1. **TurboQuant KV cache**: `ktq3/vtq3` — 2× smaller than q8_0, safe at head_dim=64 (auto-downgrades to codebook)
2. **Flash attention**: `-fa on` — required for quantized KV cache
3. **Full 131K context**: fits in 16GB VRAM with TurboQuant KV
4. **Direct llama-server**: bypasses Ollama's 4.6× overhead
5. **DSpark speculative decoding**: available but measured as net loss on CPU-offload setups; may help on full-GPU Colab (untested)
6. **Prefix caching**: `--cache-prompt --cache-ram 16384 --ctx-checkpoints 64`
7. **Batch sizes**: `-b 4096 -ub 512` (tuned for MoE)

## DSpark Speculative Decoding

DSpark (Liquid AI's official drafter, 328M params, 633 MiB F16) is available:
```
- md LFM2.5-24B-A2B-DSpark-F16.gguf --spec-type draft-dspark --spec-draft-n-max 4
```

**Caveat:** Measured as a net loss on our 8GB laptop (−12% at n-max 4, −49% at n-max 9) because the verify pass reads the union of active experts. On Colab T4 with the full model on GPU, it may perform differently — test it.

## Notes

- Free Colab sessions timeout after ~90 min of inactivity or ~12h max
- The tunnel URL changes each session (cloudflared free tier)
- API key is regenerated each session (or set via `API_KEY` env var)
- For best quality, use the QAD-Q4_0 quant (99% of BF16) — not AWQ-INT4
- Use `--no-repack` if you want to stream from disk (model doesn't fit in RAM on free tier)

## Troubleshooting

### Server won't start
Check `/tmp/llama-server.log`. Common issues:
- Out of memory: reduce `-c` (context) or use `--n-cpu-moe 8` to offload some experts to CPU
- CUDA not found: check `nvidia-smi`

### Tunnel not working
Check `/tmp/cloudflared.log`. Try restarting cloudflared.

### Slow performance
- Ensure `-ngl 99` (all layers on GPU)
- Try `-ctk ktq3 -ctv vtq3 --no-tq-deferred-k` for 2× smaller KV
- Reduce `-c` if VRAM is tight
- Check `nvidia-smi` for GPU utilization