# Connecting LFM2.5-24B to OpenCode / Claude Code

The direct llama-server on port 11436 serves an OpenAI-compatible API.

## Endpoint

- Base URL: `http://127.0.0.1:11436/v1`
- API key: `lfm25-secret` (set in the systemd unit; change it in `~/.config/systemd/user/llfm25-24b.service`)
- Model ID: `sha256-89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa`

## OpenCode config

Add to `~/.config/opencode/opencode.json` (or a separate config):

```json
{
  "provider": {
    "lfm25-24b": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LFM2.5-24B-A2B (direct llama-server)",
      "options": {
        "baseURL": "http://127.0.0.1:11436/v1",
        "apiKey": "lfm25-secret"
      },
      "models": {
        "lfm25-24b": {
          "name": "LFM2.5-24B-A2B (35.74 tok/s, 131K ctx)",
          "limit": { "context": 131072, "output": 8192 }
        }
      }
    }
  }
}
```

Then select it: `opencode --model lfm25-24b/lfm25-24b` or set `"model": "lfm25-24b/lfm25-24b"` in the config.

## Claude Code

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:11436
export ANTHROPIC_API_KEY=lfm25-secret
# Claude Code expects Anthropic format; llama-server's /v1 is OpenAI format.
# For Claude Code, use the Anthropic-compatible shim or a proxy.
```

## Thinking / reasoning

The model is a reasoning model. The `/v1/chat/completions` endpoint returns the thinking
block inside `reasoning_content` (not `content`):

```json
{
  "choices": [{
    "message": {
      "content": "391",
      "reasoning_content": "The user asks: What is 17*23? ...",
      "role": "assistant"
    }
  }]
}
```

OpenCode will display the reasoning separately if the provider supports it.

## Tool calling

LFM2.5 uses Pythonic tool calls (`<|tool_call_start|>`). The OpenAI-compat layer
returns them as `tool_calls` in the response. Known issue (llama.cpp #30490): the model
occasionally emits Qwen3-Coder-style XML tool calls that the parser drops silently.
If a tool call is lost, check `finish_reason` — it will be `"stop"` with empty `tool_calls`.

## Direct generation (faster than Ollama)

For max throughput, bypass Ollama entirely:

```bash
# Start the server (already running as systemd service)
systemctl --user status llfm25-24b

# Generate
curl -s http://127.0.0.1:11436/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer lfm25-secret' \
  -d '{"model":"lfm25-24b","messages":[{"role":"user","content":"hi"}],"max_tokens":256}'
```

## Performance

| Metric | Value |
|---|---|
| Decode | 35.74 tok/s |
| Prefill | 14.23 tok/s |
| Context | 131 072 tokens |
| VRAM | 7235 MiB / 8188 MiB |
| Quant | QAD-Q4_0 (99% of BF16) |
| KV cache | ktq3/vtq3 (2× smaller than q8_0) |

## Starting/stopping

```bash
systemctl --user start llfm25-24b    # start
systemctl --user stop llfm25-24b     # stop
systemctl --user status llfm25-24b   # check
journalctl --user -u llfm25-24b -f   # logs
```
