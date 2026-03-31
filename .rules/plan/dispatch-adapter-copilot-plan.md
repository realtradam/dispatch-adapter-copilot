# Dispatch Adapter Copilot — Gem Implementation Plan

This plan covers the full implementation of the `dispatch-adapter-copilot` gem.

> **Canonical interface:** See `prototype_interface.md` for the full adapter interface definition, including all struct types, the `Base` class, the error hierarchy, and concrete adapter sketches. This plan must conform to that interface.

---

## Overview

This gem provides:
1. A **provider-agnostic adapter interface** (`Dispatch::Adapter::Base`) that defines the contract all LLM adapters must implement.
2. A **concrete Copilot implementation** (`Dispatch::Adapter::Copilot`) that calls the GitHub Copilot API directly over HTTP (no SDK).

---

## Gem Structure

```
dispatch-adapter-copilot/
├── lib/
│   └── dispatch/
│       └── adapter/
│           ├── base.rb
│           ├── copilot.rb
│           ├── message.rb        # Message, TextBlock, ImageBlock, ToolUseBlock, ToolResultBlock structs
│           ├── response.rb       # Response, Usage, StreamDelta structs
│           ├── tool_definition.rb # ToolDefinition struct
│           ├── model_info.rb     # ModelInfo struct
│           └── errors.rb         # Error hierarchy
├── spec/
│   └── dispatch/
│       └── adapter/
│           ├── base_spec.rb
│           └── copilot_spec.rb
├── dispatch-adapter-copilot.gemspec
├── Gemfile
├── Rakefile
└── README.md
```

---

## 1. Canonical Structs (under `Dispatch::Adapter`)

Implement all structs defined in the prototype interface:

- **`Message`** — `role` (String: "user" | "assistant"), `content` (String | Array<ContentBlock>).
- **`TextBlock`** — `type` ("text"), `text` (String).
- **`ImageBlock`** — `type` ("image"), `source` (String), `media_type` (String).
- **`ToolUseBlock`** — `type` ("tool_use"), `id` (String), `name` (String), `arguments` (Hash).
- **`ToolResultBlock`** — `type` ("tool_result"), `tool_use_id` (String), `content` (String | Array<TextBlock>), `is_error` (Boolean, optional).
- **`ToolDefinition`** — `name` (String), `description` (String), `parameters` (Hash — JSON Schema).
- **`Response`** — `content` (String?), `tool_calls` (Array<ToolUseBlock>), `model` (String), `stop_reason` (Symbol: `:end_turn` | `:tool_use` | `:max_tokens` | `:stop_sequence`), `usage` (Usage).
- **`Usage`** — `input_tokens` (Integer), `output_tokens` (Integer), `cache_read_tokens` (Integer, default 0), `cache_creation_tokens` (Integer, default 0).
- **`StreamDelta`** — `type` (Symbol: `:text_delta` | `:tool_use_delta` | `:tool_use_start`), `text` (String?), `tool_call_id` (String?), `tool_name` (String?), `argument_delta` (String?).
- **`ModelInfo`** — `id` (String), `name` (String), `max_context_tokens` (Integer), `supports_vision` (Boolean), `supports_tool_use` (Boolean), `supports_streaming` (Boolean).

All structs use `keyword_init: true`.

---

## 2. Adapter Interface (`Dispatch::Adapter::Base`)

An abstract base class that all adapters must subclass.

### Required Methods (raise `NotImplementedError` in base)

- `chat(messages, system: nil, tools: [], stream: false, max_tokens: nil, &block)` — Send a chat completion request.
  - `messages` — `Array<Message>` (canonical structs, not raw hashes).
  - `system:` — `String` or `nil`. System prompt. Adapters handle placement differences (Claude: top-level param; Copilot/OpenAI: system role message).
  - `tools:` — `Array<ToolDefinition>`. Tools available to the model. Empty = no tools.
  - `stream:` — `Boolean`. If `true`, yields `StreamDelta` objects to the block.
  - `max_tokens:` — `Integer` or `nil`. Per-call override of the constructor default.
  - **Return:** `Dispatch::Adapter::Response`.
- `model_name` — Returns `String`, the resolved model identifier.

### Optional Methods (base provides defaults)

- `count_tokens(messages, system: nil, tools: [])` — Returns `Integer` token count, or `-1` if unsupported. Base returns `-1`.
- `list_models` — Returns `Array<ModelInfo>`. Base raises `NotImplementedError`.
- `provider_name` — Returns `String`. Base returns `self.class.name`.
- `max_context_tokens` — Returns `Integer` or `nil`. Base returns `nil`.

---

## 3. Copilot Implementation (`Dispatch::Adapter::Copilot`)

Subclass of `Dispatch::Adapter::Base`. Calls `api.githubcopilot.com` directly over HTTP — no CLI, no SDK, pure Ruby. Authentication uses a 3-step flow: GitHub device OAuth → GitHub token → Copilot token (auto-refreshed).

### Constructor

```ruby
Copilot.new(model: "gpt-4.1", github_token: nil, token_path: default_token_path, max_tokens: 8192)
```

- `model:` — Model identifier (default: `"gpt-4.1"`).
- `github_token:` — Pre-existing `gho_xxx` token. If nil, triggers interactive device flow on first use.
- `token_path:` — Path to persist the github token.
- `max_tokens:` — Default max output tokens (default: 8192). Per-call `max_tokens:` on `chat` overrides this.

### `chat(messages, system: nil, tools: [], stream: false, max_tokens: nil, &block)`

- Accepts `Array<Message>` (canonical structs).
- Converts canonical structs to OpenAI wire format internally.
- Handles `system:` by prepending as a `role: "system"` message.
- Translates `ToolDefinition` structs → OpenAI function tools format.
- Translates `ToolUseBlock`/`ToolResultBlock` in messages to OpenAI `tool_calls`/`tool` role format.
- Merges consecutive same-role messages before sending.
- Uses `max_tokens` keyword or constructor default (`@default_max_tokens`).
- If `stream: true`, parses SSE chunks and yields `StreamDelta` objects.
- Returns `Dispatch::Adapter::Response` with `tool_calls` as `ToolUseBlock[]`.
- Raises `Dispatch::Adapter::*Error` on HTTP failures.
- `ImageBlock` in messages raises `NotImplementedError` (not yet supported).

### `model_name` → `String`
### `provider_name` → `"GitHub Copilot"`
### `max_context_tokens` → `Integer` (from MODEL_CONTEXT_WINDOWS lookup)

### `list_models` → `Array<ModelInfo>`

- `GET /v1/models` with Copilot headers.
- Translates to `ModelInfo` structs.

### `count_tokens` — Inherits base (`-1`). No native counting API.

---

## 4. Error Hierarchy (under `Dispatch::Adapter`)

All errors carry `message`, `status_code` (Integer or nil), and `provider` (String) attributes.

- `Dispatch::Adapter::Error` — base error for all adapter errors.
- `Dispatch::Adapter::AuthenticationError` — 401/403, invalid or expired credentials.
- `Dispatch::Adapter::RateLimitError` — 429, rate limit exceeded. Has `retry_after` attribute (seconds).
- `Dispatch::Adapter::ServerError` — 500/502/503, provider-side failure.
- `Dispatch::Adapter::RequestError` — 400/422, malformed request, invalid model, bad parameters.
- `Dispatch::Adapter::ConnectionError` — network timeouts, DNS failures, connection refused.

The Copilot adapter maps HTTP status codes to these error classes.

---

## 5. Testing

- **Unit tests for `Base`:** Verify that calling any interface method on `Base` directly raises `NotImplementedError`. Verify optional methods return defaults (`count_tokens` → `-1`, `max_context_tokens` → `nil`, `provider_name` → class name).
- **Unit tests for canonical structs:** Verify struct creation with keyword args, field access.
- **Unit tests for `Copilot`:**
  - Mock HTTP responses (not a real SDK — mock `Net::HTTP` or use WebMock).
  - Test `chat` with text-only responses → returns `Response` with `content` set, `tool_calls` empty.
  - Test `chat` with tool-call responses → returns `Response` with `tool_calls` as `ToolUseBlock[]`.
  - Test `chat` with mixed responses (text + tool calls).
  - Test `chat` with `system:` param → system message prepended correctly.
  - Test `chat` with `max_tokens:` per-call override vs constructor default.
  - Test streaming: verify `StreamDelta` objects are yielded correctly and `Response` is returned.
  - Test `model_name`, `provider_name`, `max_context_tokens`.
  - Test `list_models` returns `ModelInfo[]`.
  - Test error mapping: 401 → `AuthenticationError`, 429 → `RateLimitError`, 500 → `ServerError`, 400 → `RequestError`, network error → `ConnectionError`.
  - Test consecutive same-role message merging.
- **Integration tests (optional, requires real Copilot access):** Mark with a tag so they can be skipped.

---

## 6. Gemspec Dependencies

- No external SDK dependency. Uses Ruby's `net/http` (or a lightweight HTTP client like `httpx`).
- No dependency on other dispatch gems. This gem is standalone.

---

## Key Constraints

- The adapter interface will be extracted into its own gem post-MVP (Phase 7). For now it lives here.
- Streaming support is required for ActionCable relay in the Rails app.
- All adapters accept and return canonical structs (`Message`, `Response`, `ToolUseBlock`, etc.) — not raw hashes.
- The response format is consistent regardless of which adapter is used — the Rails agent loop depends on it.
- Thread-safety: adapters may be called from multiple GoodJob workers concurrently. Ensure no shared mutable state.
- `system:` is a separate parameter on `chat`, not a message role. Adapters handle placement internally.
- `max_tokens:` is accepted both in the constructor (default) and per-call on `chat` (override).
- `count_tokens` returns `-1` when not natively supported (Copilot case). Callers must check for `-1`.
