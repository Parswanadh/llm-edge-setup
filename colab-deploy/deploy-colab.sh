#!/bin/bash
# ============================================================================
# deploy-colab.sh — One-command deployment from local machine
#
# Usage:
#   bash deploy-colab.sh [--gpu T4|L4|A100|H100] [--api-key KEY]
#
# What it does:
#   1. Creates a Colab session with the specified GPU
#   2. Uploads the deploy script
#   3. Runs the deployment
#   4. Prints API key + base URL
#
# Prerequisites:
#   - colab CLI installed (uv tool install google-colab-cli --with "jupyter-kernel-client<1.0")
#   - Authenticated (colab new once to set up OAuth)
# ============================================================================

set -euo pipefail

GPU="${1:-T4}"
API_KEY="${2:-}"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --gpu) GPU="$2"; shift 2 ;;
        --api-key) API_KEY="$2"; shift 2 ;;
        *) shift ;;
    esac
done

SESSION_NAME="lfm25-colab"

echo "=== Creating Colab session ($GPU GPU) ==="
colab new -s "$SESSION_NAME" --gpu "$GPU" 2>&1 | tail -3

echo "=== Uploading deploy script ==="
colab upload -s "$SESSION_NAME" /home/parshu/llm-edge-setup/colab-deploy/colab-deploy.sh /content/colab-deploy.sh

echo "=== Running deployment ==="
if [ -n "$API_KEY" ]; then
    colab exec -s "$SESSION_NAME" "API_KEY=$API_KEY bash /content/colab-deploy.sh"
else
    colab exec -s "$SESSION_NAME" "bash /content/colab-deploy.sh"
fi

echo ""
echo "=== Deployment complete! ==="
echo "Check the output above for your Base URL + API Key"
echo ""
echo "To connect locally:"
echo "  bash /home/parshu/llm-edge-setup/colab-deploy/colab-connect.sh <base_url> <api_key>"