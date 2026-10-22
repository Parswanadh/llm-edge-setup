#!/usr/bin/env bash
# chat.sh — talk to the rootless Ollama instance on :11435 with LFM2.5 thinking enabled.
#
# Usage:
#   ./chat.sh "your prompt" [--model NAME] [--tools FILE.json] [--system TEXT] [--no-think]
#
# Defaults:
#   host   : http://127.0.0.1:11435
#   model  : lfm2.5:24b-a2b-agent if present, else lfm2.5:8b-agent
#   think  : true
#
# Requires: curl + python3 (for pretty-printing the JSON response).

set -euo pipefail

HOST="${OLLAMA_HOST:-http://127.0.0.1:11435}"
MODEL=""
TOOLS_FILE=""
SYSTEM=""
THINK=true

usage() {
  cat <<'EOF'
Usage: chat.sh [-m MODEL] [-t FILE.json] [-s SYSTEM] [-n] "PROMPT"

  -m, --model MODEL     model tag (default: lfm2.5:24b-a2b-agent, else lfm2.5:8b-agent)
  -t, --tools FILE      JSON file containing a tools array (OpenAI function schema)
  -s, --system TEXT     system prompt
  -n, --no-think        disable thinking (think: false)
  -h, --help            this message

Environment:
  OLLAMA_HOST           base URL (default http://127.0.0.1:11435)
EOF
}

# ---- pick a default model -------------------------------------------------
default_model() {
  for m in lfm2.5:24b-a2b-agent lfm2.5:8b-agent; do
    if curl -sf --max-time 5 "$HOST/api/tags" | grep -q "\"$m\""; then
      echo "$m"; return 0
    fi
  done
  # fall back to the plain upstream tags
  for m in lfm2.5:24b-a2b-q4_0 lfm2.5:8b; do
    if curl -sf --max-time 5 "$HOST/api/tags" | grep -q "\"$m\""; then
      echo "$m"; return 0
    fi
  done
  echo "lfm2.5:8b"
}

PROMPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--model)     MODEL="$2"; shift 2 ;;
    -t|--tools)     TOOLS_FILE="$2"; shift 2 ;;
    -s|--system)    SYSTEM="$2"; shift 2 ;;
    -n|--no-think)  THINK=false; shift ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; break ;;
    -*)             echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *)              PROMPT="$1"; shift ;;
  esac
done
# any remaining positional args form the prompt
if [[ -z "$PROMPT" && $# -gt 0 ]]; then PROMPT="$*"; fi
if [[ -z "$PROMPT" ]]; then echo "error: no prompt given" >&2; usage; exit 2; fi

[[ -n "$MODEL" ]] || MODEL="$(default_model)"

# ---- build the request ----------------------------------------------------
REQ="$(mktemp)"
trap 'rm -f "$REQ"' EXIT

python3 - "$REQ" "$MODEL" "$PROMPT" "$SYSTEM" "$THINK" "$TOOLS_FILE" <<'PY'
import json, os, sys
req_path, model, prompt, system, think, tools_file = sys.argv[1:7]

messages = []
if system:
    messages.append({"role": "system", "content": system})
messages.append({"role": "user", "content": prompt})

body = {"model": model, "messages": messages, "stream": False, "think": think == "true"}

if tools_file:
    if not os.path.exists(tools_file):
        sys.exit(f"error: tools file not found: {tools_file}")
    with open(tools_file) as fh:
        tools = json.load(fh)
    if isinstance(tools, dict):
        tools = tools.get("tools", [tools])
    body["tools"] = tools

with open(req_path, "w") as fh:
    json.dump(body, fh)
PY

# ---- send ------------------------------------------------------------------
RESP="$(curl -sf --max-time 900 -H 'Content-Type: application/json' \
        -d @"$REQ" "$HOST/api/chat")" || {
  echo "error: request to $HOST/api/chat failed" >&2; exit 1; }

echo "$RESP" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if "error" in d:
    print("ERROR:", d["error"]); sys.exit(1)
m = d.get("message", {})

th = m.get("thinking")
ct = m.get("content")
tc = m.get("tool_calls")

if th:
    print("=== THINKING ===")
    print(th.strip())
    print()
if ct:
    print("=== CONTENT ===")
    print(ct.strip())
if tc:
    print("=== TOOL CALLS ===")
    for i, c in enumerate(tc):
        fn = c.get("function", {})
        print(f"[{i}] {fn.get(\"name\")}({json.dumps(fn.get(\"arguments\", {}), ensure_ascii=False)})")
if not th and not ct and not tc:
    print("(empty response)")
print()
print(f"--- done_reason={d.get(\"done_reason\")} eval_count={d.get(\"eval_count\")} "
      f"prompt_tokens={d.get(\"prompt_eval_count\")} ---")
'
