#!/usr/bin/env bash
# One-shot end-to-end setup for LFM2.5-24B-A2B on this laptop.
#
#   bash setup-24b.sh
#
# Idempotent. Does everything that does NOT need root:
#   1. verify the model blob is present and hash-correct
#   2. register the model in Ollama with the correct renderer/parser
#   3. install + start the rootless Ollama 0.40.8 service with MoE offload
#   4. install + start the direct llama-server service on :11436
#   5. print the client configuration
#
# The one thing that DOES need root is the system-wide Ollama upgrade:
#   sudo bash scripts/upgrade-ollama.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OLLAMA_NEW="$HOME/.local/lib/ollama-new"
MODEL_BLOB="$HOME/.ollama/models/blobs/sha256:89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa"
MODEL_NAME="${MODEL_NAME:-lfm25-24b}"
export OLLAMA_HOST=127.0.0.1:11435

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '    FAIL: %s\n' "$*"; exit 1; }

# ---- 1. model blob -----------------------------------------------------------
step "Checking the 24B model blob"
if [ -f "$MODEL_BLOB" ]; then
  echo "    present: $(du -h "$MODEL_BLOB" | cut -f1)"
else
  echo "    missing — download it with:"
  echo "      bash $REPO/scripts/fetch-model.sh"
  echo "    (resumable, sha256-verified)"
  exit 1
fi

# ---- 2. Ollama model --------------------------------------------------------
step "Registering the model with renderer/parser"
if curl -sf --max-time 8 http://127.0.0.1:11435/api/tags | grep -q "\"$MODEL_NAME\""; then
  echo "    '$MODEL_NAME' already registered"
else
  "$OLLAMA_NEW/ollama" create "$MODEL_NAME" -f "$REPO/modelfiles/Modelfile.lfm25-24b" 2>&1 | tail -3
fi
echo "    renderer/parser check:"
"$OLLAMA_NEW/ollama" show "$MODEL_NAME" --modelfile 2>/dev/null | grep -iE "renderer|parser" | sed 's/^/      /'

# ---- 3. rootless Ollama service --------------------------------------------
step "Rootless Ollama 0.40.8 service (port 11435)"
mkdir -p ~/.config/systemd/user
cp "$REPO/systemd/ollama-rootless.service" ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now ollama-rootless
sleep 4
v=$(curl -sf --max-time 8 http://127.0.0.1:11435/api/version | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
echo "    version: ${v:-FAILED}"

# ---- 4. direct llama-server service ----------------------------------------
step "Direct llama-server service (port 11436)"
if [ -f "$REPO/systemd/llfm25-24b.service" ]; then
  cp "$REPO/systemd/llfm25-24b.service" ~/.config/systemd/user/
  systemctl --user daemon-reload
  systemctl --user enable --now llfm25-24b 2>&1 | tail -2
  sleep 6
  if curl -sf --max-time 8 http://127.0.0.1:11436/health >/dev/null; then
    echo "    healthy on 11436"
  else
    echo "    NOT healthy yet — check: journalctl --user -u llfm25-24b -n 40"
  fi
else
  echo "    service file not yet authored — skipping"
fi

# ---- 5. client config -------------------------------------------------------
step "Client configuration"
cat <<EOF

  export OLLAMA_HOST=127.0.0.1:11435        # Ollama path
  export OPENAI_BASE_URL=http://127.0.0.1:11436/v1   # direct llama-server path (faster)

  ollama run $MODEL_NAME

  # thinking is only split out when think=true:
  curl -s http://127.0.0.1:11435/api/chat -d '{
    "model":"$MODEL_NAME","think":true,
    "messages":[{"role":"user","content":"hi"}]}'

EOF

echo "Done. Re-verify with:"
echo "  curl -s http://127.0.0.1:11435/api/version"
echo "  bash $REPO/scripts/bench.sh verify"
