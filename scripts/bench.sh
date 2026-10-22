#!/bin/bash
# Benchmark harness for LFM2.5-24B-A2B on this box.
# Sweeps the levers that actually matter and prints a table.
#
#   ./bench.sh sweep-n        # --n-cpu-moe sweep
#   ./bench.sh sweep-cache    # --moe-cache-mib sweep
#   ./bench.sh sweep-kv       # KV type vs max context
#   ./bench.sh bench-dspark   # baseline vs DSpark speculative decoding
#   ./bench.sh verify         # quality verification
set -uo pipefail

OLLAMA_HOME="${OLLAMA_HOME:-/home/parshu/.local/lib/ollama-new}"
export LD_LIBRARY_PATH="$OLLAMA_HOME:$OLLAMA_HOME/cuda_v13"
export GGML_BACKEND_PATH="$OLLAMA_HOME/cuda_v13/libggml-cuda.so"
LS="$OLLAMA_HOME/llama-server"

MODEL="${MODEL:-/home/parshu/.ollama/models/blobs/sha256-89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa}"
DRAFTER="${DRAFTER:-/home/parshu/llm-edge-setup/models/LFM2.5-24B-A2B-DSpark-F16.gguf}"
PORT="${PORT:-19990}"

PROMPT="You are a helpful coding assistant. Analyze the following Python function and explain its time complexity, then suggest one optimization.

def find_pairs(nums, target):
    seen = {}
    for i, n in enumerate(nums):
        if target - n in seen:
            yield (seen[target - n], i)
        seen[n] = i

Explain step by step, then give the optimized version."

log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

check_preconditions() {
  if [ ! -f "$MODEL" ]; then
    echo "model missing: $MODEL"; return 1
  fi
  case "$MODEL" in *-partial*) echo "model still downloading"; return 1;; esac
  avail=$(free -m | awk '/Mem:/{print $7}')
  if [ "$avail" -lt 2000 ]; then
    echo "only ${avail}MB RAM available — refusing to run (OOM risk)"; return 1
  fi
  return 0
}

cleanup() { pkill -f "llama-server.*--port $PORT" 2>/dev/null; sleep 2; }

# Run one config, print: decode_tps prefill_tps vram_mb wall_s
run_one() {
  local label="$1"; shift
  cleanup
  local logf="/tmp/opencode/bench.$$.log"
  timeout 300 "$LS" -m "$MODEL" --host 127.0.0.1 --port "$PORT" --no-webui \
      -fa on --jinja -lv 4 "$@" > "$logf" 2>&1 &
  local srv=$!

  # wait for healthy
  local ok=0
  for _ in $(seq 1 90); do
    if curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"status":"ok"'; then ok=1; break; fi
    kill -0 $srv 2>/dev/null || break
    sleep 2
  done
  if [ "$ok" -ne 1 ]; then
    printf "%-46s LOAD-FAIL: %s\n" "$label" "$(grep -aoE 'error loading model[^"]*|out of memory|failed to allocate[^"]*' "$logf" | head -1)"
    cleanup; rm -f "$logf"; return 1
  fi

  local vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)
  local resp=$(curl -s --max-time 200 "http://127.0.0.1:$PORT/completion" \
      -H 'Content-Type: application/json' \
      -d "{\"prompt\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$PROMPT"),\"n_predict\":128,\"stream\":false,\"timings_per_token\":true}")
  local tps=$(echo "$resp" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin); t=d.get('timings',{})
    print('%.2f %.2f %d %d %d' % (t.get('predicted_per_second',0), t.get('prompt_per_second',0),
          t.get('draft_n',0), t.get('draft_n_accepted',0), t.get('predicted_n',0)))
except Exception: print('0 0 0 0 0')" 2>/dev/null)
  printf "%-46s decode=%-7s prefill=%-8s draft=%s/%s vram=%sMB\n" "$label" \
      "$(echo $tps|cut -d' ' -f1)" "$(echo $tps|cut -d' ' -f2)" \
      "$(echo $tps|cut -d' ' -f4)" "$(echo $tps|cut -d' ' -f3)" "$vram"
  cleanup; rm -f "$logf"
}

sweep_n() {
  log "--n-cpu-moe sweep (ctx 8192, kv q8_0)"
  for n in 0 8 16 20 22 24 26 28 30 32; do
    run_one "n-cpu-moe=$n" -ngl 99 --n-cpu-moe "$n" -c 8192 \
      --cache-type-k q8_0 --cache-type-v q8_0 -t 16
  done
}

sweep_cache() {
  log "--moe-cache-mib sweep (n-cpu-moe=26, ctx 8192, kv q4_0)"
  for m in 0 256 512 1024 1536 2048 3072; do
    run_one "moe-cache-mib=$m" -ngl 99 --n-cpu-moe 26 --moe-cache-mib "$m" \
      -c 8192 --cache-type-k q4_0 --cache-type-v q4_0 -t 16
  done
}

sweep_kv() {
  log "KV type vs context (n-cpu-moe=26)"
  for kv in "q8_0 q8_0" "q4_0 q4_0" "q4_1 q4_1" "q5_0 q5_0"; do
    set -- $kv
    for ctx in 8192 32768 65536 131072; do
      run_one "ctk=$1 ctv=$2 ctx=$ctx" -ngl 99 --n-cpu-moe 26 -c "$ctx" \
        --cache-type-k "$1" --cache-type-v "$2" -t 16
    done
  done
}

bench_dspark() {
  log "Baseline vs DSpark speculative decoding"
  [ -f "$DRAFTER" ] || { echo "drafter missing: $DRAFTER"; return 1; }
  run_one "baseline (no draft)" -ngl 99 --n-cpu-moe 26 -c 8192 \
    --cache-type-k q4_0 --cache-type-v q4_0 -t 16
  for nm in 4 6 9 12; do
    run_one "dspark n-max=$nm" -ngl 99 -ngld 99 --n-cpu-moe 26 \
      --model-draft "$DRAFTER" --spec-type draft-dspark \
      --spec-draft-n-max "$nm" --spec-draft-n-min 0 \
      -c 8192 --cache-type-k q4_0 --cache-type-v q4_0 -t 16
  done
  run_one "dspark n-max=9 + moe-cache=1024" -ngl 99 -ngld 99 --n-cpu-moe 26 \
    --moe-cache-mib 1024 --model-draft "$DRAFTER" --spec-type draft-dspark \
    --spec-draft-n-max 9 --spec-draft-n-min 0 \
    -c 8192 --cache-type-k q4_0 --cache-type-v q4_0 -t 16
}

verify() {
  log "Quality verification"
  cleanup
  timeout 300 "$LS" -m "$MODEL" --host 127.0.0.1 --port "$PORT" --no-webui \
    -fa on --jinja -lv 4 -ngl 99 --n-cpu-moe 26 -c 16384 \
    --cache-type-k q8_0 --cache-type-v q8_0 -t 16 > /tmp/opencode/verify.log 2>&1 &
  for _ in $(seq 1 90); do
    curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"status":"ok"' && break
    sleep 2
  done
  for p in "What is 17*23? Think step by step." \
           "Write a Python function that reverses a linked list. Explain the approach." \
           "Explain what this does: def f(x): return [y for y in x if y % 2 == 0]"; do
    echo "--- $p"
    curl -s --max-time 120 "http://127.0.0.1:$PORT/completion" -H 'Content-Type: application/json' \
      -d "{\"prompt\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$p"),\"n_predict\":300,\"stream\":false}" \
      | python3 -c "import json,sys;print(json.load(sys.stdin).get('content','')[:600])"
  done
  cleanup
}

case "${1:-}" in
  sweep-n)      check_preconditions && sweep_n ;;
  sweep-cache)  check_preconditions && sweep_cache ;;
  sweep-kv)     check_preconditions && sweep_kv ;;
  bench-dspark) check_preconditions && bench_dspark ;;
  verify)       check_preconditions && verify ;;
  *) echo "usage: $0 {sweep-n|sweep-cache|sweep-kv|bench-dspark|verify}"; exit 1 ;;
esac
