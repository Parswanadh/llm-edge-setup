#!/bin/bash
# ============================================================================
# colab-connect.sh — Connect local OpenCode to Colab-deployed LFM2.5-24B
#
# Usage:
#   bash colab-connect.sh <base_url> <api_key>
#
# Example:
#   bash colab-connect.sh https://abc123.trycloudflare.com/v1 sk-xxx
# ============================================================================

set -euo pipefail

BASE_URL="${1:-}"
API_KEY="${2:-}"

if [ -z "$BASE_URL" ] || [ -z "$API_KEY" ]; then
    echo "Usage: $0 <base_url> <api_key>"
    echo "Example: $0 https://abc123.trycloudflare.com/v1 sk-xxx"
    exit 1
fi

# Update OpenCode config
CONFIG_FILE="/home/parshu/ornith/config/opencode.json"

python3 - <<PYEOF
import json
path = "$CONFIG_FILE"
with open(path) as f:
    cfg = json.load(f)

cfg.setdefault("provider", {})
cfg["provider"]["lfm25-colab"] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": "LFM2.5-24B (Colab llama.cpp)",
    "options": {
        "baseURL": "$BASE_URL",
        "apiKey": "$API_KEY"
    },
    "models": {
        "lfm25-24b": {
            "name": "LFM2.5-24B-A2B (Colab, continuous batching + DSpark)",
            "limit": {"context": 131072, "output": 8192}
        }
    }
}

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\\n")
print("OpenCode config updated with lfm25-colab provider")
PYEOF

echo ""
echo "=== Connected! ==="
echo "  Base URL:  $BASE_URL"
echo "  API Key:   $API_KEY"
echo ""
echo "  Test with:"
echo "  opencode run -m \"lfm25-colab/lfm25-24b\" \"What is 2+2?\""
echo ""
echo "  Or direct curl:"
echo "  curl -s $BASE_URL/chat/completions -H 'Content-Type: application/json' -H 'Authorization: Bearer $API_KEY' -d '{\"model\":\"lfm25-24b\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":128}'"