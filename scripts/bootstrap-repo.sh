#!/bin/bash
# One-shot bootstrap: create the GitHub repo and push.
# Idempotent — safe to re-run.
set -uo pipefail

REPO_DIR="${REPO_DIR:-/home/parshu/llm-edge-setup}"
REPO_NAME="${REPO_NAME:-llm-edge-setup}"
VISIBILITY="${VISIBILITY:-private}"
BRANCH="${BRANCH:-main}"

cd "$REPO_DIR" || exit 1

git init -q 2>/dev/null
git checkout -B "$BRANCH" 2>/dev/null || true

git config user.name "${GIT_NAME:-Parswanadh}"
git config user.email "${GIT_EMAIL:-balchaparshu@gmail.com}"

git add -A
git commit -q -m "chore: initial import — LFM2.5-24B edge setup (Docker/Ollama/TurboQuant/DSpark)" 2>&1 | head -2

# Create the remote if it does not exist yet.
if ! gh repo view "$GIT_OWNER/$REPO_NAME" >/dev/null 2>&1; then
  gh repo create "$REPO_NAME" --"$VISIBILITY" --description \
    "Reproducible setup for running LFM2.5-24B-A2B (MoE) on an 8GB-VRAM consumer laptop: Docker/Ollama housekeeping, expert-level CPU offload, TurboQuant KV, DSpark speculative decoding." \
    --source=. --remote=origin --push 2>&1 | tail -3
else
  echo "remote exists, pushing"
  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "https://github.com/$GIT_OWNER/$REPO_NAME.git"
  fi
  git push -u origin "$BRANCH" 2>&1 | tail -3
fi

echo "--- status ---"
git log --oneline -3
git remote -v
