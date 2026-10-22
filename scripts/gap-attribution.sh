#!/bin/bash
# gap-attribution.sh — Task 1: explain the 71 tok/s (direct) vs 15.7 tok/s (Ollama) gap.
#
# All runs use the SAME model blob and the SAME llama-server binary Ollama itself uses
# (/home/parshu/.local/lib/ollama-new/llama-server, llama.cpp f174553e1).
# The only thing that changes between arms is one knob at a time.
#
# Arms:
#   A_ollama         : the real Ollama service on 11435 (measured via /api/generate)
#   B_direct_fast   : direct llama-server, the "fast" recipe from the prior worker
#                      (-ngl 16 -fa on -t 8 -np 1 -ctk q8_0 -ctv q8_0 -c 4096)
#   C_direct_ollama : direct llama-server with Ollama's EXACT cmdline
#   D_ctx_only      : direct llama-server, Ollama cmdline BUT -c 4096  (isolates context size)
#   E_ngl_only      : direct llama-server, Ollama cmdline BUT -ngl 99   (isolates ngl choice)
#   F_threads_only  : direct llama-server, Ollama cmdline BUT -t 8      (isolates thread count)
#   G_batch_only    : direct llama-server, Ollama cmdline BUT -b 1024 -ub 1024
#   H_draft_only    : direct llama-server, Ollama cmdline + DSpark draft (as Ollama ran)
#   I_nodraft       : direct llama-server, Ollama cmdline MINUS the DSpark draft
#   J_all_fast      : direct llama-server with ALL the fast knobs at once
set -uo pipefail

OLLAMA_HOME=/home/parshu/.local/lib/ollama-new
export LD_LIBRARY_PATH="$OLLAMA_HOME:$OLLAMA_HOME/cuda_v13"
export GGML_BACKEND_PATH="$OLLAMA_HOME/cuda_v13/libggml-cuda.so"
LS="$OLLAMA_HOME/llama-server"
M8=/home/parshu/.ollama/models/blobs/sha256-63c9be0cc3d5d7b0377161064a74c82b1a5a6ee9ba4a9a3cf034293d6dd09282
DRAFT8=/home/parshu/.ollama/models/draft/LFM2.5-8B-A1B-DSpark-Q4_K_M.gguf
OUT=/tmp/opencode/gap
mkdir -p "$OUT"
PORT=19950

PROMPT="You are a helpful coding assistant. Analyze the following Python function and explain its time complexity, then suggest one optimization.

def find_pairs(nums, target):
    seen = {}
    for i, n in enumerate(nums):
        if target - n in seen:
            yield (seen[target - n], i)
        seen[n] = i

Explain step by step, then give the optimized version."

PJ=$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$PROMPT")

# Ollama's runner cmdline, reconstructed verbatim from
# journalctl --user -u ollama-rootless | grep "starting llama-server"
#   --model <blob> --port N --host 127.0.0.1 --no-webui --offline -c 32768 -np 1
#   --log-verbosity 4 --no-log-prefix --no-log-timestamps --no-jinja
#   --chat-template chatml --load-mode none --cache-type-k q8_0 --cache-type-v q8_0
#   --flash-attn auto -b 512 -ub 512 --context-shift --keep 4
# Ollama's env for that runner (inherited via cmd.Env = os.Environ()):
#   LLAMA_ARG_N_CPU_MOE=22 GGML_OP_OFFLOAD_MIN_BATCH=1
# LLAMA_ARG_N_CPU_MOE=22 is the big one: it pulls the MoE expert weights of the
# first 22 layers out of VRAM into host RAM for a 25-layer model.
OLLAMA_ENV="LLAMA_ARG_N_CPU_MOE=22 GGML_OP_OFFLOAD_MIN_BATCH=1"

run_direct() {  # $1=label  $2=extra env (may be empty)  $3..=server args
  local label="$1"; shift
  local envs="$1"; shift
  local logf="$OUT/$label.server.log"
  # Wait for exclusive GPU: exactly ONE llama-server at a time (box is shared).
  # Ollama's own runner (child of `ollama serve`) also matches pgrep. We allow
  # that one to exist (it is the service we are measuring/replacing) but we must
  # not race any OTHER worker-started llama-server.
  local w=0
  while :; do
    local others
    others=$(pgrep -af llama-server 2>/dev/null | grep -v "pgrep" | while read -r line; do
               local pid cmd
               pid=$(echo "$line" | awk '{print $1}')
               cmd=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)
               case "$cmd" in
                 *"llama-server --model "*) ;;   # ollama-service-owned runner -> allowed
                 *) echo "$line" ;;
               esac
             done)
    [ -z "$others" ] && break
    if [ $((w % 120)) -eq 0 ]; then
      echo "[$label] waiting for exclusive GPU; other llama-server(s):" >&2
      echo "$others" | sed 's/^/    /' >&2
    fi
    sleep 20; w=$((w+20))
    [ $w -ge 2400 ] && { echo "[$label] TIMEOUT waiting for GPU"; return 1; }
  done

  # shellcheck disable=SC2086
  env $envs timeout 300 "$LS" -m "$M8" --host 127.0.0.1 --port $PORT --no-webui --offline \
    --log-verbosity 4 --no-log-prefix --no-log-timestamps "$@" > "$logf" 2>&1 &
  SRVPID=$!
  local ok=0
  for _ in $(seq 1 120); do
    curl -s --max-time 2 "http://127.0.0.1:$PORT/health" | grep -q '"status":"ok"' && { ok=1; break; }
    kill -0 $SRVPID 2>/dev/null || break
    sleep 2
  done
  if [ $ok -ne 1 ]; then
    echo "[$label] LOAD FAIL"; grep -aoE "out of memory|failed to allocate|error[^,]{0,80}" "$logf" | head -3
    kill -9 $SRVPID 2>/dev/null; SRVPID=""; return 1
  fi

  # static facts
  local ngl ctx thr batch
  ngl=$(grep -aoE "n_gpu_layers = *[0-9]+" "$logf" | tail -1)
  ctx=$(grep -aoE "n_ctx += *[0-9]+" "$logf" | tail -1)
  thr=$(grep -aoE "n_threads = *[0-9]+" "$logf" | tail -1)
  batch=$(grep -aoE "n_batch = *[0-9]+" "$logf" | tail -1)
  local cubuf kvb
  cubuf=$(grep -aoE "CUDA0 model buffer size = *[0-9.]+ MiB" "$logf" | tail -1)
  kvb=$(grep -aoE "CUDA0 KV buffer size = *[0-9.]+ MiB" "$logf" | tail -1)
  echo "[$label] $ngl | $ctx | $thr | $batch | $cubuf | $kvb" >&2

  for i in 1 2 3 4; do
    local resp
    resp=$(curl -s --max-time 200 "http://127.0.0.1:$PORT/completion" \
      -H 'Content-Type: application/json' \
      -d "{\"prompt\":$PJ,\"n_predict\":128,\"stream\":false,\"temperature\":0,\"seed\":42,\"cache_prompt\":false,\"timings_per_token\":true}")
    echo "$resp" | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin); t=d.get('timings',{})
  print(json.dumps({'label':'$label','run':$i,'decode_tps':round(t.get('predicted_per_second',0),2),
    'prefill_tps':round(t.get('prompt_per_second',0),2),'pred_n':t.get('predicted_n',0),
    'prompt_n':t.get('prompt_n',0)}))
except Exception as e:
  print(json.dumps({'label':'$label','run':$i,'error':str(e)}))
"
    sleep 1
  done
  kill -TERM $SRVPID 2>/dev/null; sleep 3; kill -9 $SRVPID 2>/dev/null; SRVPID=""
  sleep 2
}

case "${ARM:-all}" in
  A)  echo "##### ARM A: Ollama service on 11435 (native /api/generate) #####"
      for i in 1 2 3 4; do
        R=$(curl -s --max-time 200 http://127.0.0.1:11435/api/generate -H 'Content-Type: application/json' \
           -d "{\"model\":\"lfm25-test\",\"prompt\":$PJ,\"stream\":false,\"keep_alive\":\"30m\",\"options\":{\"temperature\":0,\"seed\":42,\"num_predict\":128}}")
        echo "$R" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ec=d.get('eval_count',0); ed=d.get('eval_duration',1)
pc=d.get('prompt_eval_count',0); pd=d.get('prompt_eval_duration',1)
print(json.dumps({'label':'A_ollama','run':$i,
  'decode_tps':round(ec/(ed/1e9),2) if ed else 0,
  'prefill_tps':round(pc/(pd/1e9),2) if pd else 0,
  'eval_count':ec,'prompt_eval_count':pc}))
"
        sleep 1
      done ;;
  B)  echo "##### ARM B: direct llama-server, prior worker's fast recipe #####"
      run_direct B_direct_fast "" \
        -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 1024 -ub 512 \
        -ngl 16 -t 8 -fa on --context-shift --keep 4 ;;
  C)  echo "##### ARM C: direct llama-server, Ollama's EXACT cmdline + env #####"
      run_direct C_direct_ollama "$OLLAMA_ENV" \
        -c 32768 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 512 -ub 512 \
        --context-shift --keep 4 ;;
  D)  echo "##### ARM D: Ollama cmdline but -c 4096 (context size isolated) #####"
      run_direct D_ctx_only "$OLLAMA_ENV" \
        -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 512 -ub 512 \
        --context-shift --keep 4 ;;
  E)  echo "##### ARM E: Ollama cmdline but -ngl 99 (ngl isolated) #####"
      run_direct E_ngl_only "$OLLAMA_ENV" \
        -c 32768 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 512 -ub 512 \
        -ngl 99 --context-shift --keep 4 ;;
  E2) echo "##### ARM E2: Ollama cmdline + explicit --n-cpu-moe 22 #####"
      run_direct E2_ncmoe22 "$OLLAMA_ENV" \
        -c 32768 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 512 -ub 512 \
        --n-cpu-moe 22 --context-shift --keep 4 ;;
  E3) echo "##### ARM E3: --n-cpu-moe 22 WITHOUT GGML_OP_OFFLOAD_MIN_BATCH=1 #####"
      run_direct E3_ncmoe22_nooffload "" \
        -c 32768 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 512 -ub 512 \
        --n-cpu-moe 22 --context-shift --keep 4 ;;
  E4) echo "##### ARM E4: --n-cpu-moe 4 (the value the OTHER ollama instance uses) #####"
      run_direct E4_ncmoe4 "$OLLAMA_ENV" \
        -c 32768 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 512 -ub 512 \
        --n-cpu-moe 4 --context-shift --keep 4 ;;
  E5) echo "##### ARM E5: Ollama cmdline, NO n-cpu-moe at all (all experts in VRAM) #####"
      run_direct E5_noncmoe "$OLLAMA_ENV" \
        -c 32768 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 512 -ub 512 \
        -ngl 99 --context-shift --keep 4 ;;
  F)  echo "##### ARM F: Ollama cmdline but -t 8 (threads isolated) #####"
      run_direct F_threads_only "$OLLAMA_ENV" \
        -c 32768 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 512 -ub 512 \
        -t 8 --context-shift --keep 4 ;;
  G)  echo "##### ARM G: Ollama cmdline but -b 1024 -ub 1024 (batch isolated) #####"
      run_direct G_batch_only "$OLLAMA_ENV" \
        -c 32768 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 1024 -ub 1024 \
        --context-shift --keep 4 ;;
  H)  echo "##### ARM H: Ollama cmdline WITH DSpark draft (as Ollama ran) #####"
      run_direct H_draft_only "$OLLAMA_ENV" \
        -c 32768 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 512 -ub 512 \
        --spec-draft-n-max 4 --spec-draft-model "$DRAFT8" --context-shift --keep 4 ;;
  I)  echo "##### ARM I: Ollama cmdline, NO draft #####"
      run_direct I_nodraft "$OLLAMA_ENV" \
        -c 32768 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 512 -ub 512 \
        --context-shift --keep 4 ;;
  J)  echo "##### ARM J: everything fast at once #####"
      run_direct J_all_fast "" \
        -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 1024 -ub 512 \
        -ngl 99 -t 8 -fa on --context-shift --keep 4 ;;
  K)  echo "##### ARM K: fast recipe + DSpark draft (does drafting help direct?) #####"
      run_direct K_fast_draft "" \
        -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none \
        --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 1024 -ub 512 \
        -ngl 99 -t 8 -fa on --spec-draft-n-max 4 --spec-draft-model "$DRAFT8" \
        --context-shift --keep 4 ;;
  *) echo "usage: ARM={A|B|C|D|E|E2|E3|E4|E5|F|G|H|I|J|K|all} $0"; exit 2;;
esac

echo "##### DONE #####"
pgrep -af llama-server || echo "no llama-server running (clean)"
