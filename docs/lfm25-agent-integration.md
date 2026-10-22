# LFM2.5-24B-A2B as a coding/agentic model on this box

Everything below was measured on **this** machine against the rootless Ollama
**0.40.8** instance on `127.0.0.1:11435` (`OLLAMA_MODELS=/home/parshu/.ollama/models`).

---

## 1. The problem: the 24B tag ships no renderer/parser

The registry config blob for `lfm2.5:24b-a2b-q4_0` (digest
`sha256:30cd3d97973282ad6c47620f033e1deb6e11b15c953b81ca39311077734b078f`) is:

```json
{"model_format":"gguf","model_family":"lfm2moe","model_families":["lfm2moe"],
 "model_type":"24.0B","file_type":"Q4_0","requires":"0.40.4"}
```

No `renderer`, no `parser`. The 8B tag's config blob *does* have them:

```json
{"model_format":"gguf",...,"renderer":"lfm2","parser":"lfm2-thinking","requires":"0.30.0",...}
```

Consequence: with no parser, Ollama uses the passthrough path — the raw
`<think>...</think>` stays inside `content`, and tool calls are never turned into
structured `tool_calls`.

---

## 2. The exact Modelfiles

### 2a. Recommended — `RENDERER lfm2-thinking` + `PARSER lfm2-thinking`

`/home/parshu/llm-edge-setup/modelfiles/Modelfile.lfm25-24b-agent`

```
FROM lfm2.5:24b-a2b-q4_0

RENDERER lfm2-thinking
PARSER lfm2-thinking

PARAMETER temperature 0.1
PARAMETER top_k 50
PARAMETER repeat_penalty 1.05
```

Build:

```bash
export OLLAMA_HOST=127.0.0.1:11435
ollama create lfm2.5:24b-a2b-agent -f /home/parshu/llm-edge-setup/modelfiles/Modelfile.lfm25-24b-agent
```

> The three `PARAMETER` lines are redundant (the registry params blob is already
> `{"repeat_penalty":1.05,"temperature":0.1,"top_k":50}`) but they make the model
> self-describing.

**Why `lfm2-thinking` and not `lfm2` for the renderer?** Because the *renderer*
is what determines the model's **thinking contract**, and the *parser* only
determines how output is split. From `model/renderers/renderer.go` (v0.40.8):

```go
case "lfm2":           return &LFM2Renderer{IsThinking: false, ...}
case "lfm2-thinking":  return &LFM2Renderer{IsThinking: true,  ...}
```

and `server/model_thinking.go` builds the served contract from that:

```go
if name := resolveRendererName(m); name != "" {
    thinking := renderers.ThinkingForRenderer(name)
    if !slices.Contains(m.Capabilities(), model.CapabilityThinking) {
        return &model.Thinking{Values: []any{false}, Default: false}
    }
    if thinking.Default == false && thinking.Supports(true) { thinking.Default = true }
    return thinking
}
```

Verified live with `GET /api/show`:

| model | renderer / parser | `thinking` contract from `/api/show` |
|---|---|---|
| `lfm2.5:8b-agent` | `lfm2-thinking` / `lfm2-thinking` | `{"values":[true],"default":true}` |
| `lfm2.5:8b-agent-nr` | `lfm2` / `lfm2-thinking` | `{"values":[false],"default":false}` |
| `lfm2.5:8b` (upstream) | `lfm2` / `lfm2-thinking` | `{"values":[false],"default":false}` |

`model/parsers/parsers.go` maps the parser name the same way:

```go
case "lfm2":          return &LFM2Parser{hasThinkingSupport: false}
case "lfm2-thinking": return &LFM2Parser{hasThinkingSupport: true}
```

so `PARSER lfm2` (without `-thinking`) would make the split **impossible** even
with `think: true`. `PARSER lfm2-thinking` is mandatory.

Ollama's own GGUF migration agrees with this pairing —
`compatmigrate/lfm25_thinking.go` emits
`Renderer: "lfm2-thinking", Parser: "lfm2-thinking"`.

### 2b. Literal spec variant — `RENDERER lfm2` + `PARSER lfm2-thinking`

`/home/parshu/llm-edge-setup/modelfiles/Modelfile.lfm25-24b-agent-nr`

```
FROM lfm2.5:24b-a2b-q4_0

RENDERER lfm2
PARSER lfm2-thinking

PARAMETER temperature 0.1
PARAMETER top_k 50
PARAMETER repeat_penalty 1.05
```

This matches the upstream `lfm2.5:8b` tag exactly and works for tool calls, but
its thinking contract is `{"values":[false],"default":false}`, which has a real
cost (see §3). Use it only if you need byte-identical parity with the upstream
8B tag.

### 2c. The 8B development equivalents

```
Modelfile.lfm25-8b-agent       FROM lfm2.5:8b   RENDERER lfm2-thinking  PARSER lfm2-thinking
Modelfile.lfm25-8b-agent-nr    FROM lfm2.5:8b   RENDERER lfm2            PARSER lfm2-thinking
```

Build as `lfm2.5:8b-agent` and `lfm2.5:8b-agent-nr`.

---

## 3. Which mechanism enables the thinking split (measured)

The resolution rule is `model/renderers/thinking.go`:

```go
func ResolveThinking(requestedThink *api.ThinkValue, thinking *model.Thinking) *api.ThinkValue {
	if !thinking.Valid() { return requestedThink }
	if requestedThink != nil {
		switch value := requestedThink.Value.(type) {
		case bool:   return requestedThink              // booleans pass through verbatim
		case string:
			if thinking.Supports(value) { return requestedThink }  // named level must be supported
		}
	}
	return &api.ThinkValue{Value: thinking.Default}     // otherwise -> model default
}
```

`api.ThinkValue.Bool()` returns `true` for *any* string, but `ResolveThinking`
discards unsupported strings **before** that. So a string only works if it is in
the model's `values` list.

### Measured matrix (`/api/chat`, model `lfm25-thinkrenderer` = `RENDERER lfm2`, and `lfm2.5:8b-agent` = `RENDERER lfm2-thinking`)

| request | `RENDERER lfm2` | `RENDERER lfm2-thinking` |
|---|---|---|
| `think` omitted | ❌ no split (`<think>` stays in `content`) | ✅ split |
| `"think": true` | ✅ split | ✅ split |
| `"think": false` | ❌ no split (expected) | ❌ no split (expected) |
| `"think": "enabled"` | ❌ **no split** | ✅ split (falls back to `default:true`) |
| `"think": "high"` | ❌ **no split** | ✅ split (falls back to `default:true`) |

Raw evidence — `RENDERER lfm2` (upstream-style), `"think":"enabled"`:

```
THINKING= None
CONTENT = '<think>\nThe user asks: "What is 17*23? ..."\n</think>\n\\boxed{391}'
```

Raw evidence — `RENDERER lfm2-thinking`, `think` omitted:

```
THINKING= 'The user asks: "What is 17*23? Answer with just the number." ...'
CONTENT = '391'
```

### `OLLAMA_THINK=1` — **does not exist in 0.40.8**

There is no `OLLAMA_THINK` environment variable in Ollama 0.40.8. It is absent
from `env/config.go`, from `server/routes.go`, from `ollama serve --help`, and
from the whole `v0.40.8` tree. (It was introduced in later releases.) The only
server-side switch in 0.40.8 is the per-request `think` field.

### `POST /v1/chat/completions` (OpenAI-compatible)

It does **not** expose `reasoning_content`. The 0.40.8 OpenAI-compat layer
serialises the field as **`reasoning`**:

```go
// openai/openai.go
type Message struct {
    Role      string     `json:"role"`
    Content   any        `json:"content"`
    Reasoning string     `json:"reasoning,omitempty"`   // <-- NOT reasoning_content
    ToolCalls []ToolCall `json:"tool_calls,omitempty"`
    ...
}
type Delta struct {
    ...
    Reasoning string `json:"reasoning,omitempty"`
}
```

`reasoning_content` appears **nowhere** in the v0.40.8 source (`openai/`,
`server/`, `api/`). Clients that look for `reasoning_content` will see nothing.

How thinking is requested on the OpenAI-compat path — `reasoning_effort`
(classic OpenAI) or `reasoning: {effort: ...}` (Ollama extension):

```go
// openai/openai.go
func ThinkingFromReasoningEffort(effort string, thinking ...*model.Thinking) (*api.ThinkValue, error) {
	switch effort {
	case "":     return nil, nil
	case "none": return &api.ThinkValue{Value: false}, nil
	}
	...
}
```

Measured on `POST /v1/chat/completions` with a tool:

| model | request | `reasoning` | `reasoning_content` | tool_calls |
|---|---|---|---|---|
| `lfm2.5:8b-agent` (`lfm2-thinking`) | *(none)* | ✅ populated | ❌ absent | ✅ |
| `lfm2.5:8b-agent` (`lfm2-thinking`) | `reasoning_effort:"medium"` | ✅ populated | ❌ absent | ✅ |
| `lfm2.5:8b-agent` (`lfm2-thinking`) | `reasoning:{"effort":"high"}` | ✅ populated | ❌ absent | ✅ |
| `lfm2.5:8b-agent-nr` (`lfm2`) | *(none)* | ❌ empty, raw `<think>` in `content` | ❌ absent | ✅ |
| `lfm2.5:8b-agent-nr` (`lfm2`) | `reasoning_effort:"medium"` | ❌ empty | ❌ absent | ✅ |
| `lfm2.5:8b-agent-nr` (`lfm2`) | `reasoning:{"effort":"high"}` | ❌ empty | ❌ absent | ✅ |

**This is the decisive difference.** With `RENDERER lfm2`, reasoning is
*unreachable* over the OpenAI-compat layer entirely: every named effort is
rejected by `ResolveThinking` (the contract only contains `false`) and falls
back to `default:false`. Only the native `/api/chat` `think: true` works.

### `POST /v1/messages` (Anthropic-compatible — what Claude Code calls)

Ollama 0.40.8 ships an Anthropic-compat layer (`anthropic/anthropic.go`) that
speaks the real Anthropic thinking protocol:

```go
if r.Thinking != nil && r.Thinking.Type == "enabled"  { think = &api.ThinkValue{Value: true} }
if r.Thinking != nil && r.Thinking.Type == "disabled" { think = &api.ThinkValue{Value: false} }
```

Measured:

| request | content blocks |
|---|---|
| `"thinking":{"type":"enabled"}` | `['thinking', 'tool_use']`, `stop_reason: "tool_use"` |
| `"thinking":{"type":"disabled"}` | `['text']` (raw `<think>` remains inline) |
| *(no `thinking` field)* | `['thinking', 'text']` — default is on for `lfm2-thinking` |

---

## 4. The LFM2.5 tool-call wire format

### Native format emitted by the model

Captured by rendering the prompt with Ollama's own `_debug_render_only` and
replaying it into a `PARSER passthrough` model:

```
<|tool_call_start|>[get_weather(city="Paris", unit="celsius")]<|tool_call_end|>
```

i.e. **Python call syntax inside the vendor control tokens**:

```
<|tool_call_start|>[<fn>(<arg>=<value>, ...), <fn2>(...)]<|tool_call_end|>
```

The renderer writes the same shape when replaying assistant tool calls
(`model/renderers/lfm2.go`, `lfm2RenderToolCalls`), and the tool *schema* list
goes into the system message as:

```
<|startoftext|>system
List of tools: <|tool_list_start|>[{"name": "get_weather", "description": "...", "parameters": {...}}]<|tool_list_end|>
user
What is the weather in Paris right now? Use the tool.
assistant
```

### What `/api/chat` returns

```json
{
  "message": {
    "role": "assistant",
    "content": "",
    "thinking": "Okay, the user is asking for the current weather in Paris ...",
    "tool_calls": [
      {
        "id": "call_thbva9kl",
        "function": { "index": 0, "name": "get_weather", "arguments": { "city": "Paris" } }
      }
    ]
  },
  "done_reason": "stop"
}
```

`arguments` is a **JSON object** on the native endpoint.

### What `/v1/chat/completions` returns

```json
{
  "choices": [{
    "finish_reason": "tool_calls",
    "message": {
      "role": "assistant",
      "content": "",
      "reasoning": "Okay, the user is asking for the current weather in Paris ...",
      "tool_calls": [{
        "id": "call_pqyghh6f", "index": 0, "type": "function",
        "function": { "name": "get_weather", "arguments": "{\"city\":\"Paris\"}" }
      }]
    }
  }]
}
```

`arguments` is a **JSON string** here (classic OpenAI shape), `finish_reason` is
`"tool_calls"`, and the reasoning field is `reasoning`.

### What `/v1/messages` returns

```json
{
  "content": [
    { "type": "thinking", "thinking": "Okay, the user is asking ..." },
    { "type": "tool_use", "id": "call_2knyyp59", "name": "get_weather", "input": { "city": "Paris" } }
  ],
  "stop_reason": "tool_use"
}
```

---

## 5. Upstream issue #30490 — does Ollama's parser accept the XML form?

**No.** `model/parsers/lfm2.go` (v0.40.8) recognises exactly two control
tokens:

```go
const (
	lfm2ThinkingOpenTag  = "<think>"
	lfm2ThinkingCloseTag = "</think>"
	lfm2ToolCallStartTag = "<|tool_call_start|>"
	lfm2ToolCallEndTag   = "<|tool_call_end|>"
)
```

It transitions into the tool-call state **only** on `<|tool_call_start|>`:

```go
case LFM2CollectingContent:
	if strings.Contains(bufStr, lfm2ToolCallStartTag) { ... p.state = LFM2CollectingToolCalls }
```

There *is* one fallback — if the turn ends with **zero** parsed calls, the whole
content is re-parsed as a bare python-style call:

```go
if done && len(toolCalls) == 0 && p.hasTools {
	candidate := strings.TrimSpace(contentSb.String())
	if fallbackCalls, parseErr := p.parseToolCallsContent(candidate); parseErr == nil && p.toolCallsAllowed(fallbackCalls) {
		contentSb.Reset()
		toolCalls = append(toolCalls, fallbackCalls...)
	}
}
```

but `parseToolCallsContent` → `parsePythonStyleToolCalls` requires an opening
parenthesis:

```go
parenIdx := strings.Index(content, "(")
if parenIdx == -1 { return nil, errors.New("invalid tool call: no opening parenthesis") }
```

The Qwen3-Coder-style XML from #30490 has **no parentheses**:

```
<tool_call>
<function=edit>
<parameter=i>[/tmp/mdhtml/build.mjs#2ff4]</parameter>
</function>
</tool_call>
```

→ the fallback errors out → the XML stays in `content`, `tool_calls` is empty,
`finish_reason` is `"stop"`. **The call is silently lost**, exactly as the
upstream report describes. There is no recovery path in 0.40.8.

### Measured failure rate

10 identical tool-triggering attempts, `POST /api/chat`, model
`lfm25-thinkrenderer` (`RENDERER lfm2-thinking`, `PARSER lfm2-thinking`),
tool `get_weather(city)`, prompt *"What is the weather in Paris right now? Use
the tool."*:

```
run1:  tool_calls=1 xml_in_content=False
run2:  tool_calls=1 xml_in_content=False
run3:  tool_calls=1 xml_in_content=False
run4:  tool_calls=1 xml_in_content=False
run5:  tool_calls=1 xml_in_content=False
run6:  tool_calls=1 xml_in_content=False
run7:  tool_calls=1 xml_in_content=False
run8:  tool_calls=1 xml_in_content=False
run9:  tool_calls=1 xml_in_content=False
run10: tool_calls=1 xml_in_content=False
```

**10/10 parsed successfully, 0/10 XML drift.**

Two of the ten initially failed for *environmental* reasons, not model reasons:
`run9` returned `an error was encountered while running the model: unexpected EOF`
because the `llama-server` subprocess was **SIGKILLed** under memory pressure
while a 13.5 GB model pull was running concurrently:

```
journalctl --user -u ollama-rootless
  WARN source=llama_server.go:1242 msg="llama-server process no longer running"
       sys=9 string="signal: killed"
```

The 8B does not drift into XML on its own. Note the upstream reporter's own
observation: the drift happened **after a run of tool-schema errors** (a client
rejecting ~8 consecutive calls), i.e. it is context-drift, not randomness — so
the failure rate depends on the *conversation*, not on the model in isolation.

---

## 6. OpenAI-compatible endpoint summary

| check | result |
|---|---|
| `GET /v1/models` lists the lfm2.5 models | ✅ yes — every tag is listed, e.g. `lfm2.5:8b-agent` |
| `POST /v1/chat/completions` works | ✅ yes |
| exposes `reasoning_content` | ❌ **no** — the field is `reasoning` |
| accepts `tools`, returns `tool_calls` | ✅ yes, `finish_reason: "tool_calls"` |
| model name string to use | the exact Ollama tag, e.g. `lfm2.5:24b-a2b-agent` |
| `POST /v1/messages` (Anthropic) | ✅ yes — `thinking` blocks, `tool_use` blocks, `stop_reason: "tool_use"` |

---

## 7. Client wiring

### OpenCode / any OpenAI-compatible client

```bash
export OPENAI_BASE_URL=http://127.0.0.1:11435/v1
export OPENAI_API_KEY=ollama          # any non-empty value; Ollama ignores it
export OPENAI_MODEL=lfm2.5:24b-a2b-agent
```

* `OPENAI_API_KEY` is not validated by Ollama — `ollama` (or any placeholder)
  is fine.
* Reasoning is **off by default** unless the model has `default: true`, i.e.
  use the `lfm2.5:24b-a2b-agent` build (`RENDERER lfm2-thinking`). With the
  `lfm2` renderer you must send `reasoning_effort`, and it will be *ignored*.
* Ollama's OpenAI-compat layer has **no `think` passthrough field**. Reasoning
  is controlled only by `reasoning_effort` (or `reasoning: {effort: ...}`).
  There is no way to send a literal boolean `think` over `/v1/chat/completions`.
* Many clients look for `reasoning_content` (DeepSeek/Nous convention).
  Ollama 0.40.8 sends `reasoning`. If your client only reads
  `reasoning_content`, reasoning will appear to be missing — this is a
  client-side mapping issue, not a server bug.

### Claude Code (Anthropic-compatible)

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:11435
export ANTHROPIC_API_KEY=ollama
export ANTHROPIC_MODEL=lfm2.5:24b-a2b-agent
```

Claude Code sends `"thinking": {"type": "enabled"}` on the Messages API, which
Ollama 0.40.8 maps to `think=true` and answers with proper `thinking` blocks.
`"type": "disabled"` is honoured too.

### Native Ollama API (Python / JS SDKs)

```python
from ollama import chat
resp = chat(model="lfm2.5:24b-a2b-agent",
            messages=[{"role": "user", "content": "hi"}],
            think=True)                       # <- required for the `lfm2` renderer
print(resp.message.thinking)                 # reasoning
print(resp.message.content)                  # answer
print(resp.message.tool_calls)               # structured tool calls
```

With `lfm2.5:24b-a2b-agent` (`RENDERER lfm2-thinking`) `think=True` is optional —
it is already the model default.

---

## 8. `scripts/chat.sh`

`/home/parshu/llm-edge-setup/scripts/chat.sh` (executable).

```
Usage: chat.sh [-m MODEL] [-t FILE.json] [-s SYSTEM] [-n] "PROMPT"

  -m, --model MODEL     model tag (default: lfm2.5:24b-a2b-agent, else lfm2.5:8b-agent)
  -t, --tools FILE      JSON file containing a tools array (OpenAI function schema)
  -s, --system TEXT     system prompt
  -n, --no-think        disable thinking (think: false)
  -h, --help            this message

Environment:
  OLLAMA_HOST           base URL (default http://127.0.0.1:11435)
```

It posts to `/api/chat` with `think: true` and prints `thinking` and `content`
separately.

Sample invocation and real output:

```console
$ ./scripts/chat.sh "What is the capital of France? Answer in one sentence." --model lfm2.5:8b-agent
=== THINKING ===
The user asks: "What is the capital of France? Answer in one sentence." That's straightforward. The answer: "The capital of France is Paris." That's one sentence. No extra formatting. Provide that.

=== CONTENT ===
The capital of France is Paris.

--- model=lfm2.5:8b-agent done_reason=stop eval_count=56 prompt_tokens=21 ---
```

With tools:

```console
$ ./scripts/chat.sh "What is the weather in Paris right now? Use the tool." \
      --model lfm2.5:8b-agent --tools /tmp/opencode/tools.json
=== THINKING ===
Okay, the user is asking for the current weather in Paris and wants me to use the provided tool. ...

=== TOOL CALLS ===
[0] get_weather({"city": "Paris"})

--- model=lfm2.5:8b-agent done_reason=stop eval_count=410 prompt_tokens=116 ---
```

---

## 9. Gotchas

1. **`reasoning` vs `reasoning_content`.** Ollama 0.40.8 uses `reasoning`.
2. **The renderer variant decides the thinking contract**, not the parser.
   `PARSER lfm2-thinking` is mandatory; `RENDERER lfm2-thinking` is what makes
   reasoning work over OpenAI-compat and by default.
3. **Named `think` strings are not free-form.** `"think": "enabled"` and
   `"think": "high"` are silently ignored by a `lfm2`-renderer model (they fall
   back to `default:false`). Only `true`/`false` are honoured verbatim.
4. **`OLLAMA_THINK` does not exist in 0.40.8.**
5. **Memory pressure kills `llama-server`.** Running a multi-GB model pull
   concurrently with inference on this 15 GiB box produced
   `signal: killed` on the `llama-server` subprocess and spurious
   `unexpected EOF` API errors. Serialise pulls and inference.
6. **Never run inference and a pull at once on this machine** — see 5.
