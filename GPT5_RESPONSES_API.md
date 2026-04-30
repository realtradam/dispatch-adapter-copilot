# GPT-5.4 + Tool Calls — Requires `/v1/responses` API

## Problem

When `build.rb` selects the `gpt-5.4` model and sends a request with tool
definitions, the Copilot API responds with:

```
Dispatch::Adapter::RequestError: Function tools with reasoning_effort are
not supported for gpt-5.4 in /v1/chat/completions. Please use /v1/responses instead.
```

`dispatch-adapter-copilot` currently targets `/v1/chat/completions` for all
models. GPT-5.4 is a reasoning model that requires the newer `/v1/responses`
endpoint when tool calls are involved.

---

## Background

### `/v1/chat/completions`
OpenAI's original chat API. Stateless: you send the full `messages` history,
get back `choices`. Tool calls via `tools` + `tool_calls` are supported. Works
for all models up to GPT-4o.

### `/v1/responses`
Introduced for reasoning models (o1, o3, GPT-5+). Key differences:

- Uses `input` instead of `messages` for the conversation history.
- Exposes a `reasoning_effort` parameter (`low` / `medium` / `high`).
- Optionally stateful via `previous_response_id` (server keeps history).
- **Required** for tool use on reasoning/GPT-5 models — OpenAI removed
  function-call support from Chat Completions for these models.

GPT-5.4 was added to the GitHub Copilot model catalog but brings the
Responses API requirement with it. The adapter was written before this model
existed, so it has no Responses API support.

---

## What Needs to Be Done

To support GPT-5.4 (and future reasoning models) with tool calls:

1. **Detect reasoning models** — identify which model IDs require the
   Responses API (e.g. anything matching `gpt-5.*` or carrying a
   `reasoning` capability flag in the `/models` response).

2. **Implement a Responses API code path** in `dispatch-adapter-copilot`:
   - Endpoint: `POST /v1/responses` (not `/v1/chat/completions`).
   - Request shape: `input` array instead of `messages`.
   - Response shape: different structure — parse accordingly.
   - Map `Dispatch::Adapter` tool definitions and result blocks to the
     Responses API format.
   - Handle `reasoning_effort` (expose as an adapter option or auto-set
     to `medium`).

3. **Route per model** — the adapter should check the model ID and choose
   the correct endpoint at request time, keeping Chat Completions for all
   non-reasoning models.

---

## Workaround (until implemented)

Use `sonnet-4.6` instead of `gpt-5.4` in `build.rb`'s interactive menu.
Claude Sonnet 4.6 (routed via Copilot's `/v1/chat/completions`) fully
supports tool calls and has no Responses API requirement.
