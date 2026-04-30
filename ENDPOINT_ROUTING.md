# Endpoint Routing — How the adapter picks `/v1/chat/completions` vs `/v1/responses`

> **TL;DR** The decision is made by a single regex against the model id string.
> No capability discovery, no flag, no per-request override.

## The decision

The full routing logic lives in **one method**:

`lib/dispatch/adapter/copilot.rb`

```ruby
# Returns true when the selected model requires the /v1/responses endpoint.
# This applies to GPT-5 reasoning models. These models reject tool calls on
# /v1/chat/completions and return a 400 RequestError directing callers to
# use /v1/responses instead.
def uses_responses_api?
  @model.match?(/\Agpt-5/)
end
```

`\A` anchors at the start of the string, so any model id whose name begins
with the literal `gpt-5` (case-sensitive) is routed to the Responses API.
Everything else goes to Chat Completions.

The check is invoked once per `#chat` call:

```ruby
# lib/dispatch/adapter/copilot.rb (inside #chat)
if uses_responses_api?
  if stream
    chat_streaming_responses(...)        # POST /v1/responses (SSE)
  else
    chat_non_streaming_responses(...)    # POST /v1/responses
  end
else
  # build chat-completions body
  if stream
    chat_streaming(...)                  # POST /v1/chat/completions (SSE)
  else
    chat_non_streaming(...)              # POST /v1/chat/completions
  end
end
```

The four code paths are:

| Path | Method | Endpoint | Streamed? |
|---|---|---|---|
| Responses, streaming | `chat_streaming_responses` | `POST /v1/responses` | yes |
| Responses, blocking | `chat_non_streaming_responses` | `POST /v1/responses` | no |
| Chat, streaming | `chat_streaming` | `POST /v1/chat/completions` | yes |
| Chat, blocking | `chat_non_streaming` | `POST /v1/chat/completions` | no |

All four live in `lib/dispatch/adapter/copilot.rb`.

## Body-shape differences (what the adapter rewrites silently)

| Concept | `/v1/chat/completions` body | `/v1/responses` body |
|---|---|---|
| Conversation | `messages: [...]` | `input: [...]` |
| Token cap | `max_tokens` (or `max_completion_tokens` on o*/gpt-5/gemini) | `max_output_tokens` |
| Reasoning effort | `reasoning_effort: "high"` | `reasoning: { effort: "high" }` |
| Tool definition | `{ type: "function", function: { name, description, parameters } }` | `{ type: "function", name, description, parameters }` (no `function:` wrapper) |

These transforms are handled inside the adapter — callers always pass the
same `Dispatch::Adapter::ToolDefinition` / `Dispatch::Adapter::Message`
structs and the same `thinking:` keyword.

## Current model list and routing

Source: `reference/models.txt` (lives one level up from this gem, in the
parent `update-adapters/` workspace; format is `model_id,premium_multiplier`).

| Model id | Premium multiplier | `\Agpt-5` match? | Endpoint |
|---|---|---|---|
| gpt-4.1 | 0.0 | ❌ | `/v1/chat/completions` |
| gpt-4o | 0.0 | ❌ | `/v1/chat/completions` |
| gpt-5-mini | 0.0 | ✅ | `/v1/responses` |
| oswe-vscode-prime | 0.0 | ❌ | `/v1/chat/completions` |
| grok-code-fast-1 | 0.25 | ❌ | `/v1/chat/completions` |
| claude-haiku-4.5 | 0.33 | ❌ | `/v1/chat/completions` |
| gemini-3-flash-preview | 0.33 | ❌ | `/v1/chat/completions` |
| gpt-5.4-mini | 0.33 | ✅ | `/v1/responses` |
| claude-sonnet-4 | 1.0 | ❌ | `/v1/chat/completions` |
| claude-sonnet-4.5 | 1.0 | ❌ | `/v1/chat/completions` |
| claude-sonnet-4.6 | 1.0 | ❌ | `/v1/chat/completions` |
| gemini-2.5-pro | 1.0 | ❌ | `/v1/chat/completions` |
| gemini-3.1-pro-preview | 1.0 | ❌ | `/v1/chat/completions` |
| gpt-5.2 | 1.0 | ✅ | `/v1/responses` |
| gpt-5.2-codex | 1.0 | ✅ | `/v1/responses` |
| gpt-5.3-codex | 1.0 | ✅ | `/v1/responses` |
| gpt-5.4 | 1.0 | ✅ | `/v1/responses` |
| claude-opus-4.7 | 7.5 | ❌ | `/v1/chat/completions` |
| gpt-5.5 | 7.5 | ✅ | `/v1/responses` |

## Why a regex and not capability discovery?

`GET https://api.githubcopilot.com/models` does NOT return a field that
indicates which endpoint a given model accepts. A typical entry looks like:

```json
{
  "id": "claude-3.7-sonnet",
  "vendor": "Anthropic",
  "model_picker_enabled": true,
  "policy": { "state": "enabled" },
  "capabilities": {
    "family": "claude-3.7-sonnet",
    "type": "chat",
    "tokenizer": "o200k_base",
    "limits": { "max_context_window_tokens": 200000, "max_output_tokens": 8192, "max_prompt_tokens": 90000 },
    "supports": { "streaming": true, "tool_calls": true, "parallel_tool_calls": true, "vision": true }
  }
}
```

There is no `endpoints`, `api`, `responses_api`, or `chat_completions`
flag. The signal that a model needs `/v1/responses` is the **400 error
string** Copilot returns when you send tools + reasoning_effort to
`/v1/chat/completions` for a GPT-5 family model:

```
Function tools with reasoning_effort are not supported for gpt-5.4 in
/v1/chat/completions. Please use /v1/responses instead.
```

Hence the hardcoded `/\Agpt-5/` heuristic. See
`GPT5_RESPONSES_API.md` for the original problem statement.

## How to update this when GitHub adds new models

When GitHub Copilot adds a new model that requires `/v1/responses`:

1. **Edit the regex** in
   `lib/dispatch/adapter/copilot.rb` at the `uses_responses_api?` method.
   Add the new family to the alternation, e.g.:

   ```ruby
   def uses_responses_api?
     @model.match?(/\A(?:gpt-5|gpt-6|codex-6|o5)/)
   end
   ```

2. **Update the test expectations** in
   `spec/dispatch/adapter/copilot_spec.rb`. Search for `uses_responses_api`
   and `/\Agpt-5/` to find the relevant examples; both positive (a model
   that should match) and negative (a model that shouldn't) cases need
   updating.

3. **Update the table above** in this file
   (`ENDPOINT_ROUTING.md`) so the documented routing matches the code.

4. **Update `reference/models.txt`** in the parent workspace if you also
   want the new model listed for build/test scripts.

5. **Bump the gem version** in
   `lib/dispatch/adapter/version.rb` (minor bump for new model support,
   patch for a regex tweak that just fixes routing for an existing
   misclassified model).

6. **Run the test gate** from inside this gem:
   ```bash
   bundle exec rubocop --autocorrect-all
   bundle exec rspec
   ```
   Both must exit 0.

## Alternative: probe-and-fallback (not currently implemented)

A more durable design would catch the specific 400 error string from
`/v1/chat/completions`, cache the offending model id, and retransmit on
`/v1/responses`. Pros: zero hardcoded list. Cons: adds latency on the
first request per new model per process and depends on the upstream
error wording staying stable. The probe must include a tool definition
to be reliable — sending a tool-less request to `/v1/chat/completions`
will succeed for some GPT-5 variants and only the tools+reasoning combo
triggers the rejection.

## File reference (everything routing-related)

| Path | What it contains |
|---|---|
| `lib/dispatch/adapter/copilot.rb` | `uses_responses_api?` (the regex), the `chat` dispatcher, all four code paths, body builders for both endpoints |
| `lib/dispatch/adapter/version.rb` | Gem version constant |
| `spec/dispatch/adapter/copilot_spec.rb` | Tests for both endpoint paths and the routing predicate |
| `GPT5_RESPONSES_API.md` | Original problem statement — the 400 error from Copilot |
| `ENDPOINT_ROUTING.md` | This file |
| `../models.txt` | Workspace-level list of model ids and premium multipliers |
