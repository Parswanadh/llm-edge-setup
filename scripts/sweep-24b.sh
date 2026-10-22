#!/bin/bash
# sweep-24b.sh — Task 2: find the optimal direct-llama-server config for LFM2.5-24B-A2B.
#
# Sweeps: --n-cpu-moe, -c, -t, KV type.
# Measures: decode tok/s, prefill tok/s, VRAM, CPU RSS, and SWAP ACTIVITY (si/so).
#
# Safety: exactly one llama-server at a time (shared box), refuses to start if
# available RAM < 2 GB, and kills the server between every config.
set -uo pipefail

OLLAMA_HOME=/home/parshu/.local/lib/ollama-new
export LD_LIBRARY_PATH="$OLLAMA_HOME:$OLLAMA_HOME/cuda_v13"
export GGML_BACKEND_PATH="$OLLAMA_HOME/cuda_v13/libggml-cuda.so"
LS="$OLLAMA_HOME/llama-server"
MODEL="${MODEL:-/home/parshu/.ollama/models/blobs/sha256-89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa}"
OUT="${OUT:-/tmp/opencode/sweep24}"
PORT="${PORT:-19950}"
NPRED="${NPRED:-96}"
mkdir -p "$OUT"

PROMPT="You are a senior software engineer explaining a production incident. A service that normally serves 4200 requests per second suddenly drops to 380 requests per second for eleven minutes and then recovers on its own without any deploy or configuration change. The service is a Go API server behind an nginx ingress, talking to a Postgres primary in a different availability zone. The only related change in the previous week was that a background analytics job that scans the orders table every six hours was moved from a cron pod to a Kubernetes CronJob with a slightly different query plan. Explain, step by step, your ranked hypothesis list for the root cause, the specific metrics, logs and traces you would inspect to confirm or eliminate each hypothesis in order, and the exact mitigation you would apply first plus the permanent fix you would propose to engineering. Be concrete, cite specific PostgreSQL, nginx, connection pool and kernel level knobs where relevant, and explain the reasoning behind each step rather than just listing tools. End with a short ordered runbook of the first five commands an on-call engineer should run in the first ten minutes."

PJ=$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$PROMPT")
RESULT="$OUT/results.jsonl"

wait_gpu() {
  local w=0
  while :; do
    local others
    others=$(pgrep -af llama-server | grep -v "pgrep" || true)
    [ -z "$others" ] && return 0
    if [ $((w % 60)) -eq 0 ]; then
      echo "  [wait] another llama-server is up, waiting..." >&2
      echo "$others" | sed 's/^/     /' >&2
    fi
    sleep 15; w=$((w+15))
    [ $w -ge 2400 ] && { echo "  [wait] TIMEOUT"; return 1; }
  done
}

check_ram() {
  local avail; avail=$(free -m | awk '/Mem:/{print $7}')
  if [ "${avail:-0}" -lt 2000 ]; then
    echo "  [ram] only ${avail}MB available — SKIPPING this config (OOM risk)" >&2
    return 1
  fi
  return 0
}

# vmstat counters
vmstat_get() { awk '/^pswpin /{print $2} /^pswpout /{print $3}' /proc/vmstat | tr '\n' ' '; }

run_cfg() {
  local label="$1"; shift
  local ncmoe="$1"; shift
  local ctx="$1"; shift
  local nthr="$1"; shift
  local kvk="$1"; shift
  local kvv="$1"; shift
  shift  # extra args (unused placeholder for symmetry)

  wait_gpu || return 1
  check_ram || return 1

  local logf="$OUT/$label.server.log"
  # shellcheck disable=SC2086
  timeout 600 "$LS" -m "$MODEL" --host 127.0.0.1 --port "$PORT" --no-webui --offline \
    --jinja -lv 4 \
    -c "$ctx" -np 1 -t "$nthr" -tb "$nthr" \
    --cache-type-k "$kvk" --cache-type-v "$kvv" \
    --n-cpu-moe "$ncmoe" -ngl 99 \
    -fa on -b 1024 -ub 512 \
    "$@" > "$logf" 2>&1 &
  local pid=$!

  local ok=0
  for _ in $(seq 1 180); do
    curl -s --max-time 2 "http://127.0.0.1:$PORT/health" | grep -q '"status":"ok"' && { ok=1; break; }
    kill -0 $pid 2>/dev/null || break
    sleep 2
  done
  if [ $ok -ne 1 ]; then
    echo "{\"label\":\"$label\",\"status\":\"load-fail\",\"err\":\"$(grep -aoE 'out of memory|failed to allocate[^,]{0,60}|CUDA error[^,]{0,60}|error[^,]{0,80}' "$logf" | head -1 | tr -d '"')\"}" | tee -a "$RESULT"
    kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 3
    return 1
  fi

  local cubuf kvb cpubuf
  cubuf=$(grep -aoE "CUDA0 model buffer size = *[0-9.]+ MiB" "$logf" | tail -1 | grep -oE "[0-9.]+" | head -1)
  cpubuf=$(grep -aoE "CPU_Host model buffer size = *[0-9.]+ MiB" "$logf" | tail -1 | grep -oE "[0-9.]+" | head -1)
  kvb=$(grep -aoE "CUDA0 KV buffer size = *[0-9.]+ MiB" "$logf" | tail -1 | grep -oE "[0-9.]+" | head -1)
  local ngl
  ngl=$(grep -aoE "n_gpu_layers = *[0-9]+" "$logf" | tail -1 | grep -oE "[0-9]+")
  local nctx
  nctx=$(grep -aoE "n_ctx += *[0-9]+" "$logf" | tail -1 | grep -oE "[0-9]+")

  # warmup + 2 measured runs
  local run=0
  while [ $run -lt 3 ]; do
    local swb swa sw_in sw_out
    swb=$(vmstat_get)
    local resp
    resp=$(curl -s --max-time 280 "http://127.0.0.1:$PORT/completion" \
      -H 'Content-Type: application/json' \
      -d "{\"prompt\":$PJ,\"n_predict\":$NPRED,\"stream\":false,\"temperature\":0,\"seed\":42,\"cache_prompt\":false,\"timings_per_token\":true}")
    swa=$(vmstat_get)
    sw_in=$(( ${swa%% *} - ${swb%% *} )); sw_out=$(( ${swa##* } - ${swb##* } ))
    local rss vram
    rss=$(awk '/VmRSS/{print int($2/1024)}' /proc/$pid/status 2>/dev/null)
    vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    echo "$resp" | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin); t=d.get('timings',{})
  print(json.dumps({'label':'$label','run':$run,'warmup':$run==0,
    'n_cpu_moe':$ncmoe,'ctx':$ctx,'threads':$nthr,'kv_k':'$kvk','kv_v':'$kvv',
    'n_gpu_layers':${ngl:-0},'n_ctx_actual':${nctx:-0},
    'decode_tps':round(t.get('predicted_per_second',0),2),
    'prefill_tps':round(t.get('prompt_per_second',0),2),
    'pred_n':t.get('predicted_n',0),'prompt_n':t.get('prompt_n',0),
    'cuda_model_mib':${cubuf:-0},'cpu_host_model_mib':${cpubuf:-0},'cuda_kv_mib':${kvb:-0},
    'vram_mb':$vram,'rss_mb':${rss:-0},
    'swap_in_pages':$sw_in,'swap_out_pages':$sw_out}))
except Exception as e:
  print(json.dumps({'label':'$label','run':$run,'error':str(e)[:120]}))
" | tee -a "$RESULT"
    run=$((run+1))
    sleep 2
  done

  kill -TERM $pid 2>/dev/null
  for _ in $(seq 1 20); do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
  kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
  sleep 3
}

case "${1:-all}" in
  ncmoe)
    for n in 18 20 22 24 26 28 30; do
      echo "=== n-cpu-moe=$n ctx=4096 t=8 kv=q8_0 ==="
      run_cfg "nc${n}_c4096_t8_q8" "$n" 4096 8 q8_0 q8_0
    done ;;
  ctx)
    for c in 4096 8192 16384 32768; do
      echo "=== n-cpu-moe=${NCMOE:-24} ctx=$c t=8 kv=q8_0 ==="
      run_cfg "nc${NCMOE:-24}_c${c}_t8_q8" "${NCMOE:-24}" "$c" 8 q8_0 q8_0
    done ;;
  threads)
    for t in 6 8 12 16; do
      echo "=== n-cpu-moe=${NCMOE:-24} ctx=${CTX:-4096} t=$t kv=q8_0 ==="
      run_cfg "nc${NCMOE:-24}_c${CTX:-4096}_t${t}_q8" "${NCMOE:-24}" "${CTX:-4096}" "$t" q8_0 q8_0
    done ;;
  kv)
    for kv in q8_0 q4_0; do
      echo "=== n-cpu-moe=${NCMOE:-24} ctx=${CTX:-4096} t=8 kv=$kv ==="
      run_cfg "nc${NCMOE:-24}_c${CTX:-4096}_t8_${kv}" "${NCMOE:-24}" "${CTX:-4096}" 8 "$kv" "$kv"
    done ;;
  all)
    bash "$0" ncmoe; bash "$0" ctx; bash "$0" threads; bash "$0" kv ;;
  *) echo "usage: $0 {ncmoe|ctx|threads|kv|all}"; exit 2;;
esac

echo "=== sweep done, results in $RESULT ==="
pgrep -af llama-server || echo "no llama-server running (clean)"
