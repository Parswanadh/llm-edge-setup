# Colab Deployment — LFM2.5-24B-A2B

Deploy LFM2.5-24B-A2B on Google Colab (free tier) with vLLM, continuous batching, and DSpark speculative decoding. Get an API key + base URL to connect to any harness.

## Quick Start

### 1. On Google Colab

Open a new Colab notebook (free tier, T4 GPU) and run:

```bash
# Install colab CLI (local machine)
uv tool install google-colab-cli --with "jupyter-kernel-client<1.0"

# Authenticate (one-time, opens browser)
colab new --gpu T4

# Upload and run the deploy script
colab upload colab-deploy.sh /content/colab-deploy.sh
colab exec "bash /content/colab-deploy.sh"
```

Or use the one-liner:

```bash
# Clone repo and deploy
colab exec "git clone https://github.com/Parswanadh/llm-edge-setup.git /content/llm-edge-setup && bash /content/llm-edge-setup/colab-deploy/colab-deploy.sh"
```

### 2. Get your API key + base URL

The script prints:
```
  Base URL:  https://abc123.trycloudflare.com/v1
  API Key:   lfm25-xxxxxxxxxxxxxxxx
```

### 3. Connect locally

```bash
bash colab-connect.sh https://abc123.trycloudflare.com/v1 lfm25-xxxxxxxxxxxxxxxx
```

Or test directly:
```bash
curl -s https://abc123.trycloudflare.com/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer lfm25-xxxxxxxxxxxxxxxx' \
  -d '{"model":"cyankiwi/LFM2.5-24B-A2B-AWQ-INT4","messages":[{"role":"user","content":"hello"}],"max_tokens":128}'
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Google Colab (Free Tier - T4 GPU, 15GB VRAM)      │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │  vLLM Server (port 8000)                    │   │
│  │  - Continuous batching (max 256 seqs)       │   │
│  │  - DSpark speculative decoding (9 tokens)   │   │
│  │  - Prefix caching                           │   │
│  │  - Auto tool choice (hermes parser)         │   │
│  │  - AWQ-INT4 quantization (T4)               │   │
│  │  - FP8 quantization (A100/H100)             │   │
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

| GPU | VRAM | Model | Quantization | Context | Speculative |
|-----|------|-------|-------------|---------|-------------|
| T4 (free) | 15 GB | AWQ-INT4 | INT4 | 32K | DSpark (reduced gain) |
| L4 (free/pro) | 24 GB | AWQ-INT4 or FP8 | INT4/FP8 | 64K | DSpark |
| A100 (pro) | 40 GB | FP8 | FP8 | 131K | DSpark (full gain) |
| H100 (pro) | 80 GB | FP8/BF16 | FP8/BF16 | 131K | DSpark (full gain) |

## Optimizations

1. **Continuous batching**: vLLM's default scheduler, max 256 concurrent sequences, 8192 batched tokens
2. **DSpark speculative decoding**: 9 draft tokens per step (block size trained with)
3. **Prefix caching**: Reuses KV cache for shared prefixes
4. **Auto tool choice**: Hermes parser for agentic workflows
5. **GPU memory utilization**: 90% of available VRAM
6. **Quantization**: AWQ-INT4 on T4 (fits 24B in 15GB), FP8 on A100/H100

## Notes

- Free Colab sessions timeout after ~90 min of inactivity or ~12h max
- The tunnel URL changes each session (cloudflared free tier)
- API key is regenerated each session (or set via `API_KEY` env var)
- DSpark gives smaller speedup on quantized targets (Liquid docs note this)
- For best results, use A100/H100 with FP8 model

## Troubleshooting

### vLLM won't start
Check `/tmp/vllm-server.log` for errors. Common issues:
- Out of memory: reduce `MAX_MODEL_LEN` or `--gpu-memory-utilization`
- Model not found: check HuggingFace access

### Tunnel not working
Check `/tmp/cloudflared.log`. Try restarting cloudflared.

### Speculative decoding not working
vLLM may not support DSpark for LFM2.5-24B text models yet. The script will fall back to standard decoding. Check logs for "speculative" messages.