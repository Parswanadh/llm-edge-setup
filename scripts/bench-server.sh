#!/bin/bash
# bench-server.sh — single-config llama-server benchmark with swap/VRAM/RAM accounting.
#
# Usage:
#   bench-server.sh --label NAME [--model PATH] [--runs N] [--port N]
#                   [--portfile F] [--env "K=V K=V"] [--server-bin PATH]
#                   [-- "--extra llama-server args..."]
#
# Emits one JSON object per line on stdout, plus a human-readable summary on stderr.
set -uo pipefail

OLLAMA_HOME="${OLLAMA_HOME:-/home/parshu/.local/lib/ollama-new}"
export LD_LIBRARY_PATH="$OLLAMA_HOME:$OLLAMA_HOME/cuda_v13"
export GGML_BACKEND_PATH="$OLLAMA_HOME/cuda_v13/libggml-cuda.so"

MODEL="${MODEL:-/home/parshu/.ollama/models/blobs/sha256-63c9be0cc3d5d7b0377161064a74c82b1a5a6ee9ba4a9a3cf034293d6dd09282}"
LABEL=""
RUNS=3
PORT=""
PORTFILE=""
EXTRA_ENV=""
SERVER_BIN="$OLLAMA_HOME/llama-server"
SERVER_ARGS=()
WARMUP=1
NPRED=128
SEED=42

while [ $# -gt 0 ]; do
  case "$1" in
    --label)     LABEL="$2"; shift 2;;
    --model)     MODEL="$2"; shift 2;;
    --runs)      RUNS="$2"; shift 2;;
    --port)      PORT="$2"; shift 2;;
    --portfile)  PORTFILE="$2"; shift 2;;
    --env)       EXTRA_ENV="$2"; shift 2;;
    --server-bin) SERVER_BIN="$2"; shift 2;;
    --warmup)    WARMUP="$2"; shift 2;;
    --npredict)  NPRED="$2"; shift 2;;
    --) shift; SERVER_ARGS=("$@"); break;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$LABEL" ] || { echo "--label required" >&2; exit 2; }

# ---------- exclusive GPU lock ---------------------------------------------
# Exactly ONE llama-server at a time on this box (shared with other workers).
wait_for_gpu() {
  local waited=0
  while :; do
    local others
    others=$(pgrep -af "llama-server" | grep -v "bench-server.sh" || true)
    if [ -z "$others" ]; then return 0; fi
    if [ $((waited % 60)) -eq 0 ]; then
      echo "[$LABEL] waiting for GPU: another llama-server is up" >&2
      echo "$others" | sed 's/^/    /' >&2
    fi
    sleep 15
    waited=$((waited+15))
    if [ $waited -ge 2400 ]; then
      echo "[$LABEL] TIMEOUT waiting for GPU (40 min)" >&2
      return 1
    fi
  done
}

need_ram() {
  local avail
  avail=$(free -m | awk '/Mem:/{print $7}')
  if [ "${avail:-0}" -lt 2000 ]; then
    echo "[$LABEL] only ${avail}MB available RAM — refusing (OOM risk)" >&2
    return 1
  fi
  return 0
}

# ---------- prompt -----------------------------------------------------------
# Fixed prompt, long enough to exercise prefill but short enough to fit
# comfortably in a 4096 context alongside 128 generated tokens.
read -r -d '' PROMPT <<'EOF'
You are a helpful coding assistant. Analyze the following Python function and explain its time complexity, then suggest one optimization.

def find_pairs(nums, target):
    seen = {}
    for i, n in enumerate(nums):
        if target - n in seen:
            yield (seen[target - n], i)
        seen[n] = i

Explain step by step, then give the optimized version.
EOF
PROMPT_JSON=$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$PROMPT")

# ---------- swap accounting --------------------------------------------------
# pswpin and pswpout are 2-field counters (name + value). Emit "<in> <out>".
vmstat_get() {
  local i o
  i=$(awk '/^pswpin /{print $2; exit}' /proc/vmstat)
  o=$(awk '/^pswpout /{print $2; exit}' /proc/vmstat)
  echo "${i:-0} ${o:-0}"
}

cleanup() {
  if [ -n "${SRV_PID:-}" ]; then
    kill -TERM "$SRV_PID" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$SRV_PID" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$SRV_PID" 2>/dev/null
    wait "$SRV_PID" 2>/dev/null
  fi
  # make sure nothing of ours survives
  pkill -f "llama-server.*--port $PORT" 2>/dev/null
  sleep 1
}
trap cleanup EXIT

wait_for_gpu || exit 1
need_ram || exit 1

# ---------- pick a port ------------------------------------------------------
if [ -z "$PORT" ]; then
  if [ -n "$PORTFILE" ]; then
    PORT=$(cat "$PORTFILE" 2>/dev/null || echo "")
  fi
  if [ -z "$PORT" ]; then
    for p in $(seq 19950 19959); do
      if ! ss -ltn 2>/dev/null | grep -q ":$p "; then PORT=$p; break; fi
    done
  fi
fi
[ -n "$PORT" ] || { echo "no free port in 19950-19959" >&2; exit 1; }
[ -n "$PORTFILE" ] && echo "$PORT" > "$PORTFILE"

echo "[$LABEL] port=$PORT bin=$SERVER_BIN model=$MODEL" >&2
echo "[$LABEL] extra env: $EXTRA_ENV" >&2
echo "[$LABEL] server args: ${SERVER_ARGS[*]}" >&2

# ---------- launch -----------------------------------------------------------
LOG="/tmp/opencode/bench/${LABEL}.server.log"
mkdir -p /tmp/opencode/bench

# shellcheck disable=SC2086
env $EXTRA_ENV timeout 600 "$SERVER_BIN" \
  -m "$MODEL" --host 127.0.0.1 --port "$PORT" --no-webui --offline \
  -fa on --jinja -lv 4 "${SERVER_ARGS[@]}" > "$LOG" 2>&1 &
SRV_PID=$!

ok=0
for _ in $(seq 1 150); do
  if curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"status":"ok"'; then ok=1; break; fi
  kill -0 "$SRV_PID" 2>/dev/null || break
  sleep 2
done

if [ "$ok" -ne 1 ]; then
  err=$(grep -aoE 'out of memory|failed to allocate|CUDA error[^"]*|error loading model[^"]*|invalid[^"]*' "$LOG" | head -2 | tr '\n' ';')
  echo "{\"label\":\"$LABEL\",\"status\":\"load-fail\",\"error\":\"${err}\"}"
  exit 0
fi

# ---------- static measurements ---------------------------------------------
VRAM_MB=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
SRV_RSS_KB=$(awk '/VmRSS/{print $2}' /proc/$SRV_PID/status 2>/dev/null)
CUDA_BUF=$(grep -aoE "CUDA0 model buffer size = *[0-9.]+ MiB" "$LOG" | tail -1)
HOST_BUF=$(grep -aoE "CPU(_Host|_Mapped)? model buffer size = *[0-9.]+ MiB" "$LOG" | tail -1)
KV_BUF=$(grep -aoE "CUDA0 KV buffer size = *[0-9.]+ MiB" "$LOG" | tail -1)
CTX=$(grep -aoE "n_ctx *= *[0-9]+" "$LOG" | tail -1)
NTHR=$(grep -aoE "n_threads = *[0-9]+" "$LOG" | tail -1)
NGPU=$(grep -aoE "n_gpu_layers = *[0-9]+" "$LOG" | tail -1)

echo "[$LABEL] loaded. vram=${VRAM_MB}MB rss=$((SRV_RSS_KB/1024))MB $CUDA_BUF | $HOST_BUF | $KV_BUF | $CTX | $NTHR | $NGPU" >&2

# ---------- run --------------------------------------------------------------
for i in $(seq 1 $((RUNS+WARMUP))); do
  SW_BEFORE=$(vmstat_get)
  T0=$(date +%s.%N)
  RESP=$(curl -s --max-time 280 "http://127.0.0.1:$PORT/completion" \
    -H 'Content-Type: application/json' \
    -d "{\"prompt\":$PROMPT_JSON,\"n_predict\":$NPRED,\"stream\":false,\"temperature\":0,\"seed\":$SEED,\"cache_prompt\":false,\"timings_per_token\":true}")
  T1=$(date +%s.%N)
  SW_AFTER=$(vmstat_get)
  SWAP_IN=$(( ${SW_AFTER%% *} - ${SW_BEFORE%% *} ))
  SWAP_OUT=$(( ${SW_AFTER##* } - ${SW_BEFORE##* } ))

  if ! echo "$RESP" | grep -q '"timings"'; then
    echo "[$LABEL] run $i FAILED: $(echo "$RESP" | head -c 200)" >&2
    continue
  fi

  echo "$RESP" | python3 -c "
import json,sys
d=json.load(sys.stdin); t=d.get('timings',{})
sw_in=$SWAP_IN; sw_out=$SWAP_OUT
print(json.dumps({
 'label':'$LABEL','run':$i,'warmup':$i<=$WARMUP,
 'decode_tps':round(t.get('predicted_per_second',0),2),
 'prefill_tps':round(t.get('prompt_per_second',0),2),
 'predicted_n':t.get('predicted_n',0),
 'prompt_n':t.get('prompt_n',0),
 'wall_s':round($T1-$T0,3),
 'swap_in_pages':sw_in,'swap_out_pages':sw_out,
 'vram_mb':$VRAM_MB,'rss_mb':${SRV_RSS_KB:-0},
}))
"
  sleep 1
done

echo "[$LABEL] done" >&2
