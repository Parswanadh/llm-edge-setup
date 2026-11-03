#!/bin/bash
# ============================================================================
# colab-deploy.sh — One-command LFM2.5-24B deployment on Google Colab
#
# Uses llama.cpp with TurboQuant (validated safe at head_dim=64) + cloudflared
# tunnel. On Colab T4 (16GB VRAM), the model fits entirely on GPU.
#
# Usage (on Colab):
#   bash colab-deploy.sh
#
# Environment variables (optional):
#   MODEL_URL      - Direct GGUF download URL (default: QAD-Q4_0 from HuggingFace)
#   PORT           - Server port (default: 8080)
#   API_KEY        - Custom API key (default: auto-generated)
#   MAX_CTX        - Max context length (default: 32768, or 131072 with enough VRAM)
#   N_CPU_MOE      - Expert layers on CPU (default: 0, all on GPU for T4)
#   USE_TURBOQUANT - Use TurboQuant KV cache (default: 1)
# ============================================================================

set -euo pipefail

PORT="${PORT:-8080}"
API_KEY="${API_KEY:-lfm25-$(openssl rand -hex 16)}"
export API_KEY="$API_KEY"

# Auto-detect GPU
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1 | tr -d ' MiB')

echo "=== GPU: $GPU_NAME ($GPU_MEM MiB) ==="

# Choose settings based on GPU
if [ -z "${MAX_CTX:-}" ]; then
    if echo "$GPU_NAME" | grep -qi "A100\|H100"; then
        MAX_CTX=131072
    elif echo "$GPU_NAME" | grep -qi "L4\|RTX 4090\|RTX 3090"; then
        MAX_CTX=65536
    else
        MAX_CTX=32768
    fi
fi

N_CPU_MOE="${N_CPU_MOE:-0}"
USE_TURBOQUANT="${USE_TURBOQUANT:-1}"

echo "=== Max context: $MAX_CTX ==="
echo "=== Expert layers on CPU: $N_CPU_MOE ==="

# ── Install dependencies ───────────────────────────────────────────────────
echo "=== Installing llama.cpp (TurboQuant) + cloudflared ==="

# Download prebuilt llama-tq (TurboQuant) CUDA build
if [ ! -f /tmp/llama-tq/llama-v2026.10.19/llama-server ]; then
    echo "Downloading llama-tq (TurboQuant)..."
    wget -q https://github.com/LL4nc33/llama-tq/releases/download/v2026.10.19/llama-v2026.10.19-bin-ubuntu-cuda-12.8-sm89-x64.tar.gz -O /tmp/llama-tq.tar.gz
    mkdir -p /tmp/llama-tq && tar xzf /tmp/llama-tq.tar.gz -C /tmp/llama-tq
    # Fix AVX-512 SIGILL: swap CPU backend for AVX2 (haswell) variant
    cp /tmp/llama-tq/llama-v2026.10.19/libggml-cpu-haswell.so /tmp/llama-tq/llama-v2026.10.19/libggml-cpu.so
    cp /tmp/llama-tq/llama-v2026.10.19/libggml-cpu-haswell.so /tmp/llama-tq/llama-v2026.10.19/libggml-cpu.so.0
    echo "✅ llama-tq ready"
fi

TQ="/tmp/llama-tq/llama-v2026.10.19"

# Install cloudflared
if ! command -v cloudflared &>/dev/null; then
    echo "Installing cloudflared..."
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
fi

# ── Download model ─────────────────────────────────────────────────────────
MODEL_URL="${MODEL_URL:-https://huggingface.co/LiquidAI/LFM2.5-24B-A2B-GGUF/resolve/main/LFM2.5-24B-A2B-QAD-Q4_0.gguf}"
MODEL_PATH="/content/models/LFM2.5-24B-A2B-QAD-Q4_0.gguf"

if [ ! -f "$MODEL_PATH" ]; then
    echo "=== Downloading model (13.58 GB) ==="
    mkdir -p /content/models
    pip install -q huggingface_hub 2>&1 | tail -1
    python3 -c "
from huggingface_hub import hf_hub_download
path = hf_hub_download(repo_id='LiquidAI/LFM2.5-24B-A2B-GGUF', filename='LFM2.5-24B-A2B-QAD-Q4_0.gguf', local_dir='/content/models')
print('Downloaded to:', path)
"
fi

echo "=== Model: $MODEL_PATH ==="

# ── Download DSpark drafter (optional) ─────────────────────────────────────
DRAFT_PATH="/content/models/LFM2.5-24B-A2B-DSpark-F16.gguf"
if [ ! -f "$DRAFT_PATH" ]; then
    echo "=== Downloading DSpark drafter (633 MB) ==="
    python3 -c "
from huggingface_hub import hf_hub_download
path = hf_hub_download(repo_id='LiquidAI/LFM2.5-24B-A2B-DSpark-GGUF', filename='LFM2.5-24B-A2B-DSpark-F16.gguf', local_dir='/content/models')
print('Downloaded to:', path)
" 2>&1 | tail -2
fi

# ── Build llama-server command ──────────────────────────────────────────────
export LD_LIBRARY_PATH="$TQ:/usr/local/lib/ollama/cuda_v12"
export GGML_BACKEND_PATH="$TQ/libggml-cuda.so"

SERVER_CMD="$TQ/llama-server -m $MODEL_PATH"
SERVER_CMD="$SERVER_CMD -ngl 99"
if [ "$N_CPU_MOE" -gt 0 ]; then
    SERVER_CMD="$SERVER_CMD --n-cpu-moe $N_CPU_MOE"
fi
SERVER_CMD="$SERVER_CMD -c $MAX_CTX"
SERVER_CMD="$SERVER_CMD -fa on --jinja -t 4"
if [ "$USE_TURBOQUANT" = "1" ]; then
    SERVER_CMD="$SERVER_CMD -ctk ktq3 -ctv vtq3 --no-tq-deferred-k"
else
    SERVER_CMD="$SERVER_CMD -ctk q8_0 -ctv q8_0"
fi
SERVER_CMD="$SERVER_CMD --host 0.0.0.0 --port $PORT --no-webui"
SERVER_CMD="$SERVER_CMD --api-key $API_KEY --alias lfm25-24b"

echo "=== Starting llama-server ==="
echo "$SERVER_CMD"

eval "$SERVER_CMD" > /tmp/llama-server.log 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# Wait for server to be ready
echo "Waiting for server to start..."
for i in $(seq 1 120); do
    if curl -s http://localhost:$PORT/health 2>/dev/null | grep -q "ok"; then
        echo "Server is ready!"
        break
    fi
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "Server died! Check /tmp/llama-server.log"
        cat /tmp/llama-server.log | tail -20
        exit 1
    fi
    sleep 2
done

# ── Start cloudflared tunnel ───────────────────────────────────────────────
echo "=== Starting cloudflared tunnel ==="
cloudflared tunnel --url http://localhost:$PORT 2>&1 | tee /tmp/cloudflared.log &
CF_PID=$!

# Wait for tunnel URL
echo "Waiting for tunnel URL..."
for i in $(seq 1 60); do
    TUNNEL_URL=$(grep -o 'https://[^ ]*\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -1)
    if [ -n "$TUNNEL_URL" ]; then
        break
    fi
    sleep 2
done

if [ -z "$TUNNEL_URL" ]; then
    echo "Failed to get tunnel URL. Check /tmp/cloudflared.log"
    TUNNEL_URL="http://localhost:$PORT (local only)"
fi

# ── Print results ──────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  LFM2.5-24B Deployment Ready!"
echo "=========================================="
echo ""
echo "  Base URL:  $TUNNEL_URL/v1"
echo "  API Key:   $API_KEY"
echo "  Model:     lfm25-24b"
echo "  Context:   $MAX_CTX"
echo "  TurboQuant: $USE_TURBOQUANT"
echo ""
echo "  Test with:"
echo "  curl -s $TUNNEL_URL/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Authorization: Bearer $API_KEY' \\"
echo "    -d '{\"model\":\"lfm25-24b\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":128}'"
echo ""
echo "  OpenCode (local):"
echo "  opencode run -m \"lfm25-colab/lfm25-24b\" \"your prompt\""
echo ""
echo "  Server PID: $SERVER_PID"
echo "  Tunnel PID: $CF_PID"
echo "=========================================="

# Save config
cat > /tmp/lfm25-colab-config.json <<EOF
{
  "base_url": "$TUNNEL_URL/v1",
  "api_key": "$API_KEY",
  "model": "lfm25-24b",
  "port": $PORT,
  "max_ctx": $MAX_CTX,
  "server_pid": $SERVER_PID,
  "tunnel_pid": $CF_PID
}
EOF

echo ""
echo "Config saved to /tmp/lfm25-colab-config.json"