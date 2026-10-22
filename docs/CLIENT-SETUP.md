# Client setup — LFM2.5-24B-A2B via direct llama-server (OpenAI-compatible)

The production service is a **direct `llama-server`**, not the Ollama proxy.

| | |
|---|---|
| Base URL | `http://127.0.0.1:11436/v1` |
| Health | `http://127.0.0.1:11436/health` → `{"status":"ok"}` |
| API key | `llfm25-24b-local` (placeholder — change it, see below) |
| Model name | `lfm2.5-24b-a2b` (whatever `/v1/models` reports) |
| Service | `systemctl --user status llfm25-24b.service` |

Port **11436** is new and does not touch the Ollama rootless service on **11435**.

---

## 1. Claude Code

Claude Code speaks the OpenAI-compatible API via `ANTHROPIC_BASE_URL` only for
Anthropic-native endpoints. For an OpenAI-compatible server, use the
`ANTHROPIC_BASE_URL` + OpenAI-compatible shim, or point the Anthropic SDK at
the server's Anthropic-native route.

**llama-server also exposes Anthropic-native routes** (`/v1/messages`). This is
the cleanest path for Claude Code:

```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:11436"
export ANTHROPIC_API_KEY="llfm25-24b-local"
export ANTHROPIC_MODEL="lfm2.5-24b-a2b"
export ANTHROPIC_SMALL_FAST_MODEL="lfm2.5-24b-a2b"
```

Verify:

```bash
curl -s http://127.0.0.1:11436/v1/messages \
  -H "x-api-key: llfm25-24b-local" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"lfm2.5-24b-a2b","max_tokens":256,
       "messages":[{"role":"user","content":"say hi"}]}'
```

If you route Claude Code through a gateway that speaks OpenAI instead, use
`/v1` + `OPENAI_BASE_URL` / `OPENAI_API_KEY` as in §2.

---

## 2. OpenCode

OpenCode accepts a custom OpenAI-compatible provider. Configure it in
`~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "lfm-local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LFM2.5-24B-A2B (local)",
      "options": {
        "baseURL": "http://127.0.0.1:11436/v1",
        "apiKey": "llfm25-24b-local"
      },
      "models": {
        "lfm2.5-24b-a2b": {
          "name": "LFM2.5-24B-A2B (local, 24B MoE)",
          "limit": { "context": 4096, "output": 2048 }
        }
      }
    }
  },
  "model": "lfm-local/lfm2.5-24b-a2b"
}
```

### Environment-variable equivalent (for scripts / CI)

```bash
export OPENAI_BASE_URL="http://127.0.0.1:11436/v1"
export OPENAI_API_KEY="llfm25-24b-local"
export OPENAI_MODEL="lfm2.5-24b-a2b"
```

Any OpenAI SDK works with these:

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:11436/v1", api_key="llfm25-24b-local")
r = client.chat.completions.create(
    model="lfm2.5-24b-a2b",
    messages=[{"role": "user", "content": "hello"}],
)
```

---

## 3. Changing the API key

The service file ships with a **placeholder** key `llfm25-24b-local`. Change it
before treating the endpoint as anything but loopback-local:

```bash
# 1. generate a real key
KEY=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)

# 2. write it into the unit (quoted so systemd does not expand it)
sed -i "s|--api-key llfm25-24b-local|--api-key $KEY|" \
  ~/.config/systemd/user/llfm25-24b.service

# 3. reload + restart
systemctl --user daemon-reload
systemctl --user restart llfm25-24b.service
```

`llama-server` also accepts `--api-key-file FNAME` (one key per line, `#`
comments allowed), which keeps the key out of the unit file entirely — the
better option if you want to avoid the secret showing up in
`systemctl --user cat`:

```bash
install -m 600 /dev/null ~/.config/llfm25-24b.apikey
printf '%s\n' "$KEY" > ~/.config/llfm25-24b.apikey
```

then replace `--api-key llfm25-24b-local` with
`--api-key-file /home/parshu/.config/llfm25-24b.apikey`.

> The service listens on `127.0.0.1` only. It is **not** reachable from the
> network, so the API key is defence-in-depth against other local users /
> local processes, not against the internet.

---

## 4. Reasoning / thinking — where does `<think>` go?

**This is the important part for LFM2.5, which is a reasoning model.**

`llama-server` has a `--reasoning-format` flag with three values:

| value | behaviour |
|---|---|
| `none` | thoughts are left unparsed **inside `message.content`** |
| `deepseek` | thoughts are **extracted into `message.reasoning_content`**; `content` holds only the answer |
| `deepseek-legacy` | `content` **keeps** the `<think>…</think>` tags **and** `reasoning_content` is also populated |

Default is `auto` (detect from the template).

### Measured on this box

`/v1/chat/completions` returns the `<think>` block **inside `content`** by
default — the OpenAI-compat layer does *not* split it out unless
`--reasoning-format deepseek` (or `deepseek-legacy`) is set.

To get the split, the server must be started with:

```
--reasoning-format deepseek
```

Then the response shape is:

```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "reasoning_content": "…the model's chain of thought…",
      "content": "…the final answer only…"
    }
  }]
}
```

To enable it on the running service, add `--reasoning-format deepseek` to
`ExecStart` in `~/.config/systemd/user/llfm25-24b.service`, then:

```bash
systemctl --user daemon-reload
systemctl --user restart llfm25-24b.service
```

### Client-side behaviour that matters

* **Claude Code / Anthropic-native route** (`/v1/messages`): llama.cpp maps the
  split thinking to Anthropic's `thinking` block
  (`{"type":"thinking","thinking":"…"}` then `{"type":"text","text":"…"}`).
  This is the route that works best with reasoning models.
* **OpenAI-compat route** (`/v1/chat/completions`): the split lands in
  `message.reasoning_content`, which is a **non-standard extension**. Most
  OpenAI SDK versions will simply ignore that field and show only `content`.
  If you need the trace in the UI, either use `deepseek-legacy` (so the
  `<think>` tags stay in `content` too) or read `reasoning_content` explicitly.
* `--reasoning-effort` (`minimal`/`low`/`medium`/`high`/`xhigh`/`max`) is
  forwarded to the chat template. `--reasoning-budget N` caps the thinking
  token count (default `-1` = unrestricted).

### Checking what you actually get

```bash
curl -s http://127.0.0.1:11436/v1/chat/completions \
  -H "Authorization: Bearer llfm25-24b-local" \
  -H "content-type: application/json" \
  -d '{"model":"lfm2.5-24b-a2b","max_tokens":512,
       "messages":[{"role":"user","content":"17*23=? think first"}]}' \
  | python3 -c 'import json,sys; m=json.load(sys.stdin)["choices"][0]["message"]; \
      print("reasoning_content:", repr(m.get("reasoning_content"))[:200]); \
      print("content:", repr(m.get("content"))[:300])'
```

---

## 5. Endpoints verified on this service

| Endpoint | Method | Purpose |
|---|---|---|
| `/health` | GET | liveness → `{"status":"ok"}` |
| `/v1/models` | GET | OpenAI model list |
| `/v1/chat/completions` | POST | chat (OpenAI-compat) |
| `/v1/completions` | POST | raw text completion (OpenAI-compat) |
| `/v1/messages` | POST | Anthropic-native messages |
| `/props` | GET | server-side effective parameters (useful to confirm the flags) |
| `/slots` | GET | per-slot state (context usage) |

`/v1/models` and `/v1/completions` require the `Authorization: Bearer <key>`
header when `--api-key` is set; `/health` does not.

---

## 6. Operating notes

```bash
# status / logs
systemctl --user status llfm25-24b.service
journalctl --user -u llfm25-24b.service -f

# restart after editing
systemctl --user daemon-reload && systemctl --user restart llfm25-24b.service

# confirm it actually uses the GPU (not the silent CPU fallback)
journalctl --user -u llfm25-24b.service | grep -iE "CUDA0 model buffer|offloaded .* layers|compute capability"
```

The CUDA backend is loaded through `GGML_BACKEND_PATH`. If that path is wrong,
llama.cpp **silently falls back to CPU** and you get ~2 tok/s instead of ~20.
Always sanity-check `CUDA0 model buffer size` in the log after a restart.

The context is deliberately small (`-c 4096`): LFM2.5 has attention on only
10 of its 40 blocks, so its KV cache is tiny and a large context costs almost
nothing in VRAM — but a large context *does* cost RAM once the prompt cache
grows, and RAM is the scarce resource on this box.

---

## 7. Do not confuse this with the Ollama service

| | Ollama rootless | Direct llama-server (this service) |
|---|---|---|
| Port | 11435 | **11436** |
| API | Ollama native (`/api/chat`) | OpenAI-compat (`/v1/...`) + Anthropic-native (`/v1/messages`) |
| Managed by | `ollama-rootless.service` | `llfm25-24b.service` |
| Model file | Ollama blob store | same Ollama blob store (read-only) |

Both read the same GGUF from `~/.ollama/models/blobs/`. Stopping or restarting
one does not affect the other.
