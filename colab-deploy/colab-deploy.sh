#!/bin/bash
# ============================================================================
# colab-deploy.sh — One-command LFM2.5-24B deployment on Google Colab (free tier)
#
# Usage (on Colab):
#   bash colab-deploy.sh
#
# What it does:
#   1. Installs vLLM + dependencies
#   2. Downloads LFM2.5-24B-A2B (AWQ-INT4 for T4, or FP8 for A100/H100)
#   3. Starts vLLM server with continuous batching + DSpark speculative decoding
#   4. Sets up cloudflared tunnel (free, no auth needed)
#   5. Generates API key
#   6. Prints base URL + API key
#
# Environment variables (optional):
#   MODEL_ID       - HuggingFace model ID (default: cyankiwi/LFM2.5-24B-A2B-AWQ-INT4)
#   DRAFT_MODEL    - DSpark drafter (default: LiquidAI/LFM2.5-24B-A2B-DSpark)
#   GPU_TYPE       - T4, L4, A100, H100 (auto-detected)
#   PORT           - Server port (default: 8000)
#   API_KEY        - Custom API key (default: auto-generated)
#   MAX_MODEL_LEN  - Max context length (default: auto)
# ============================================================================

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
PORT="${PORT:-8000}"
API_KEY="${API_KEY:-lfm25-$(openssl rand -hex 16)}"
export VLLM_API_KEY="$API_KEY"

# Auto-detect GPU
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | tr ' ' '_')
GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1 | tr -d ' MiB')

echo "=== GPU: $GPU_NAME ($GPU_MEM MiB) ==="

# Choose model based on GPU
if [ -z "${MODEL_ID:-}" ]; then
    if echo "$GPU_NAME" | grep -qi "A100\|H100\|L4"; then
        MODEL_ID="LiquidAI/LFM2.5-24B-A2B-FP8"
        echo "Using FP8 model (high-end GPU)"
    else
        MODEL_ID="cyankiwi/LFM2.5-24B-A2B-AWQ-INT4"
        echo "Using AWQ-INT4 model (T4/low VRAM)"
    fi
fi

DRAFT_MODEL="${DRAFT_MODEL:-LiquidAI/LFM2.5-24B-A2B-DSpark}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-}"

# ── Install dependencies ───────────────────────────────────────────────────
echo "=== Installing vLLM + dependencies ==="
pip install -q vllm>=0.12.0 2>&1 | tail -3
pip install -q cloudflared 2>&1 | tail -1 || pip install -q pycloudflared 2>&1 | tail -1

# Install cloudflared binary if not present
if ! command -v cloudflared &>/dev/null; then
    echo "Installing cloudflared..."
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
fi

# ── Determine max model len ─────────────────────────────────────────────────
if [ -z "$MAX_MODEL_LEN" ]; then
    if echo "$GPU_NAME" | grep -qi "A100\|H100"; then
        MAX_MODEL_LEN=131072
    elif echo "$GPU_NAME" | grep -qi "L4"; then
        MAX_MODEL_LEN=65536
    else
        MAX_MODEL_LEN=32768
    fi
fi

echo "=== Model: $MODEL_ID ==="
echo "=== Draft: $DRAFT_MODEL ==="
echo "=== Max context: $MAX_MODEL_LEN ==="
echo "=== Port: $PORT ==="

# ── Build vLLM command ─────────────────────────────────────────────────────
VLLM_CMD="vllm serve $MODEL_ID"
VLLM_CMD="$VLLM_CMD --port $PORT"
VLLM_CMD="$VLLM_CMD --max-model-len $MAX_MODEL_LEN"
VLLM_CMD="$VLLM_CMD --enable-auto-tool-choice"
VLLM_CMD="$VLLM_CMD --tool-call-parser hermes"
VLLM_CMD="$VLLM_CMD --gpu-memory-utilization 0.90"
VLLM_CMD="$VLLM_CMD --enable-prefix-caching"

# Speculative decoding (DSpark)
VLLM_CMD="$VLLM_CMD --speculative-config '{\"method\":\"dspark\",\"model\":\"$DRAFT_MODEL\",\"num_speculative_tokens\":9}'"

# Continuous batching (vLLM default, but ensure max batch size)
VLLM_CMD="$VLLM_CMD --max-num-seqs 256"
VLLM_CMD="$VLLM_CMD --max-num-batched-tokens 8192"

echo "=== Starting vLLM server ==="
echo "$VLLM_CMD"

# Start vLLM in background
eval "$VLLM_CMD" > /tmp/vllm-server.log 2>&1 &
VLLM_PID=$!
echo "vLLM PID: $VLLM_PID"

# Wait for server to be ready
echo "Waiting for vLLM to start..."
for i in $(seq 1 120); do
    if curl -s http://localhost:$PORT/health 2>/dev/null | grep -q "ok\|healthy"; then
        echo "vLLM is ready!"
        break
    fi
    if ! kill -0 $VLLM_PID 2>/dev/null; then
        echo "vLLM died! Check /tmp/vllm-server.log"
        cat /tmp/vllm-server.log | tail -20
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
echo "  Model:     $MODEL_ID"
echo ""
echo "  Test with:"
echo "  curl -s $TUNNEL_URL/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Authorization: Bearer $API_KEY' \\"
echo "    -d '{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":128}'"
echo ""
echo "  OpenCode:"
echo "  opencode run -m \"lfm25-colab/lfm25-24b\" \"your prompt\""
echo ""
echo "  vLLM PID: $VLLM_PID"
echo "  Tunnel PID: $CF_PID"
echo "=========================================="

# Save config for later use
cat > /tmp/lfm25-colab-config.json <<EOF
{
  "base_url": "$TUNNEL_URL/v1",
  "api_key": "$API_KEY",
  "model": "$MODEL_ID",
  "port": $PORT,
  "vllm_pid": $VLLM_PID,
  "tunnel_pid": $CF_PID
}
EOF

echo ""
echo "Config saved to /tmp/lfm25-colab-config.json"