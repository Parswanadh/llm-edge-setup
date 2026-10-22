#!/usr/bin/env bash
# Launch llama-tq (TurboQuant KV cache) for LFM2.5-24B-A2B on this box.
#
#   usage: run-llama-tq.sh <model.gguf> [port] [ctx] [n_cpu_moe]
#
# Why llama-tq at all:
#   - TurboQuant KV types (ktq*/vtq*) give ~2.0x smaller KV than q8_0 at the same
#     measured quality, which matters because the full 131072 ctx KV at q8_0 is
#     1.43 GB of the 7.6 GiB VRAM budget.
#   - llama.cpp auto-downgrades the block-128 trellis variants at head_dim=64
#     (LFM2.5's head_dim IS 64): log says
#       "head size 64 is not a multiple of the ktq3_3s block (128), using ktq3_1"
#     so you silently get the Hadamard+codebook class. Verified quality-identical
#     to q8_0 including a 20,844-token needle test.
#
# GOTCHA: --no-tq-deferred-k is REQUIRED here. Without it the ktq types allocate an
# f16 K staging buffer and the "compressed" cache ends up BIGGER than q8_0
# (measured 36.75 MiB vs 25.50 MiB at 32K ctx).
set -euo pipefail

MODEL=${1:?usage: run-llama-tq.sh <model.gguf> [port] [ctx] [n_cpu_moe]}
PORT=${2:-19977}
CTX=${3:-131072}
NCMOE=${4:-0}          # 0 = let llama.cpp --fit decide

ROOT="${TQ_ROOT:-$HOME/.local/lib/llama-tq}/merged"
CUDART=""
for c in "$HOME/.local/lib/ollama-new/cuda_v12" "/usr/local/lib/ollama/cuda_v12"; do
  if [ -f "$c/libcudart.so.12" ]; then CUDART="$c"; break; fi
done

export LD_LIBRARY_PATH="$ROOT:$CUDART"
export GGML_BACKEND_PATH="$ROOT"

ARGS=(-m "$MODEL" --host 127.0.0.1 --port "$PORT"
      -c "$CTX" -b 2048 -ub 512 -fa on -t 8 -tb 8 -ngl 99
      -ctk ktq3 -ctv vtq3 --no-tq-deferred-k
      --jinja
      --no-webui)

if [ "$NCMOE" != "0" ]; then
  ARGS+=(--n-cpu-moe "$NCMOE")
else
  ARGS+=(--fit on)
fi

exec "$ROOT/llama-server" "${ARGS[@]}"
