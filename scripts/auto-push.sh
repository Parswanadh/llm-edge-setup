#!/bin/bash
# Auto-commit and push changes to the llm-edge-setup repo.
# Safe to run repeatedly; no-op when the tree is clean.
set -uo pipefail

REPO_DIR="${REPO_DIR:-/home/parshu/llm-edge-setup}"
BRANCH="${BRANCH:-main}"
REMOTE="${REMOTE:-origin}"

cd "$REPO_DIR" || { echo "not a repo: $REPO_DIR"; exit 1; }

# Never let the repo track weights or binaries.
if [ -n "$(git status --porcelain --untracked-files=all | grep -iE '\.(gguf|safetensors|zst|tar\.gz)$' )" ]; then
  echo "refusing: model/binary files staged — check .gitignore"
  exit 1
fi

if [ -z "$(git status --porcelain)" ]; then
  echo "clean — nothing to do"
  exit 0
fi

MSG="${1:-chore: auto-sync $(date +%Y-%m-%dT%H:%M:%S%z)}"

git add -A
git -c user.name="${GIT_NAME:-Parswanadh}" \
    -c user.email="${GIT_EMAIL:-balchaparshu@gmail.com}" \
    commit -m "$MSG" || exit 1

git push "$REMOTE" "$BRANCH" || {
  echo "push failed — will retry next run"
  exit 1
}
echo "pushed: $MSG"
