# Dispatch::Adapter::Copilot

A Ruby gem that provides a provider-agnostic LLM adapter interface with a concrete GitHub Copilot implementation. Calls the Copilot API directly over HTTP using Ruby's `net/http` — no SDK, no CLI, no external dependencies.

## What It Does

- Defines a **canonical adapter interface** (`Dispatch::Adapter::Base`) that any LLM provider can implement
- Provides a **complete GitHub Copilot adapter** (`Dispatch::Adapter::Copilot`) supporting:
  - Chat completions (text responses, tool calls, mixed responses)
  - Streaming via Server-Sent Events (SSE)
  - Tool/function calling with structured input/output
  - Thinking/reasoning effort control for reasoning models (o1, o3, o4-mini, etc.)
  - Automatic GitHub device OAuth flow for authentication
  - Copilot token management with automatic refresh
- Uses **canonical structs** (`Message`, `Response`, `ToolUseBlock`, etc.) so your application code is provider-agnostic

## Installation

Add to your Gemfile:

```ruby
gem "dispatch-adapter-copilot"
```

Then run `bundle install`.

## Authentication

The adapter authenticates via a GitHub OAuth token. You have three options:

### Option 1: Pass a token directly

```ruby
adapter = Dispatch::Adapter::Copilot.new(github_token: "gho_your_token_here")
```

### Option 2: Interactive device flow

Omit the token and the adapter will trigger a GitHub device authorization flow on first use:

```ruby
adapter = Dispatch::Adapter::Copilot.new
adapter.chat(messages)  # Prints a URL and code to stderr, waits for authorization
```

The token is persisted to `~/.config/dispatch/copilot_github_token` and reused on subsequent runs.

### Option 3: Custom token path

```ruby
adapter = Dispatch::Adapter::Copilot.new(token_path: "/path/to/my/token")
```

## Usage

### Basic Chat

```ruby
require "dispatch/adapter/copilot"

adapter = Dispatch::Adapter::Copilot.new(
  model: "gpt-4.1",       # Model to use (default: "gpt-4.1")
  max_tokens: 8192         # Max output tokens (default: 8192)
)

messages = [
  Dispatch::Adapter::Message.new(role: "user", content: "What is Ruby?")
]

response = adapter.chat(messages, system: "You are a helpful programming assistant.")
puts response.content       # => "Ruby is a dynamic, open source..."
puts response.model         # => "gpt-4.1"
puts response.stop_reason   # => :end_turn
puts response.usage.input_tokens   # => 15
puts response.usage.output_tokens  # => 120
```

### Streaming

```ruby
adapter.chat(messages, stream: true) do |delta|
  case delta.type
  when :text_delta
    print delta.text
  when :tool_use_start
    puts "\nCalling tool: #{delta.tool_name}"
  when :tool_use_delta
    # Partial JSON arguments being streamed
  end
end
# Returns a Response after streaming completes
```

### Tool Calling

Tools can be passed as `ToolDefinition` structs or plain hashes with `name`, `description`, and `parameters` keys (symbol or string). This makes it easy to integrate with tool registries that return plain hashes.

```ruby
# Define a tool using a struct
weather_tool = Dispatch::Adapter::ToolDefinition.new(
  name: "get_weather",
  description: "Get the current weather for a city",
  parameters: {
    "type" => "object",
    "properties" => {
      "city" => { "type" => "string", "description" => "City name" }
    },
    "required" => ["city"]
  }
)

# Send a message with tools available
messages = [Dispatch::Adapter::Message.new(role: "user", content: "What's the weather in Tokyo?")]
response = adapter.chat(messages, tools: [weather_tool])

if response.stop_reason == :tool_use
  # The model wants to call a tool
  tool_call = response.tool_calls.first
  puts tool_call.name       # => "get_weather"
  puts tool_call.arguments  # => {"city" => "Tokyo"}
  puts tool_call.id         # => "call_abc123"

  # Execute the tool, then send the result back
  tool_result = Dispatch::Adapter::ToolResultBlock.new(
    tool_use_id: tool_call.id,
    content: "72F and sunny"
  )

  followup = [
    *messages,
    Dispatch::Adapter::Message.new(role: "assistant", content: [tool_call]),
    Dispatch::Adapter::Message.new(role: "user", content: [tool_result])
  ]

  final_response = adapter.chat(followup, tools: [weather_tool])
  puts final_response.content  # => "The weather in Tokyo is 72F and sunny!"
end
```

You can also pass plain hashes instead of `ToolDefinition` structs:

```ruby
# Plain hash (e.g. from a tool registry)
tools = [{ name: "get_weather", description: "Get weather", parameters: { "type" => "object", "properties" => { "city" => { "type" => "string" } } } }]
response = adapter.chat(messages, tools: tools)
```

### Thinking / Reasoning Models

For reasoning models like `o1`, `o3`, `o3-mini`, and `o4-mini`, you can control the thinking effort:

```ruby
# Set as default
adapter = Dispatch::Adapter::Copilot.new(model: "o3-mini", thinking: "high")

# Or override per-call
response = adapter.chat(messages, thinking: "low")

# Disable for a specific call (even with a constructor default)
response = adapter.chat(messages, thinking: nil)
```

Valid values: `"low"`, `"medium"`, `"high"`, or `nil` (disabled).

### Per-Call Max Tokens

```ruby
# Override the constructor default for a single call
response = adapter.chat(messages, max_tokens: 100)
```

### List Available Models

```ruby
models = adapter.list_models
models.each do |m|
  puts "#{m.id} (context: #{m.max_context_tokens} tokens)"
end
```

### Adapter Metadata

```ruby
adapter.model_name          # => "gpt-4.1"
adapter.provider_name       # => "GitHub Copilot"
adapter.max_context_tokens  # => 1047576
adapter.count_tokens(msgs)  # => -1 (not supported by Copilot)
```

## Canonical Types

All communication uses these structs (under `Dispatch::Adapter`):

| Struct | Purpose |
|---|---|
| `Message` | Chat message with `role` and `content` |
| `TextBlock` | Text content block |
| `ImageBlock` | Image content block (not yet supported) |
| `ToolUseBlock` | Tool call from the model |
| `ToolResultBlock` | Result you send back after executing a tool |
| `ToolDefinition` | Tool schema (name, description, JSON Schema parameters) |
| `Response` | Complete response with content, tool_calls, usage, stop_reason |
| `Usage` | Token counts (input, output, cache) |
| `StreamDelta` | Incremental streaming chunk |
| `ModelInfo` | Model metadata |

## Premium Requests / Billing Behavior

GitHub Copilot bills your monthly *premium request* quota only for chat
completions sent with the HTTP header `X-Initiator: user`. Continuations sent
with `X-Initiator: agent` (e.g. follow-up calls inside an agent tool loop) are
**not** counted against your premium quota.

This adapter automatically chooses the correct value for `X-Initiator` on
every request using a "savings" strategy:

* The **first** send of a conversation — i.e. only `system` and `user`
  messages are present — is sent as `X-Initiator: user` and **is** billed as a
  premium request.
* **Every subsequent send** — anything that contains a prior `assistant` or
  `tool` message in the wire payload — is sent as `X-Initiator: agent` and is
  **not** billed.

In practice this means: in a typical agent-loop usage of this gem (initial
user prompt → model returns tool calls → your code executes them and sends
results back → repeat until the model gives a final answer), exactly **one**
premium request is consumed per top-level user prompt, regardless of how many
tool round-trips occur in between.

This behavior is more aggressive (i.e. cheaper) than the official VS Code
Copilot extension and matches the default mode of
[`ericc-ch/copilot-api`](https://github.com/ericc-ch/copilot-api). It assumes
the gem is being used for automation, where every send after the first is
part of the same agent task.

### Wire-level parity with codecompanion.nvim

The HTTP request headers this adapter sends to `api.githubcopilot.com` are
identical to those sent by
[codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim)'s
Copilot adapter:

| Header | Value |
|---|---|
| `Authorization` | `Bearer <copilot-token>` |
| `Content-Type` | `application/json` |
| `Copilot-Integration-Id` | `vscode-chat` |
| `Editor-Version` | `Neovim/0.10.4` (default — override via `editor_version:`) |
| `X-Initiator` | `user` or `agent` (see above) |

Notably, `Openai-Intent` is **not** sent (codecompanion does not send it).

If you want the request to claim a specific Neovim version (e.g. the one
you actually run), pass it to the constructor:

```ruby
adapter = Dispatch::Adapter::Copilot.new(editor_version: "Neovim/0.12.1")
```

References:
- [GitHub: What are premium requests?](https://docs.github.com/en/copilot/concepts/billing/copilot-requests#what-are-premium-requests)
- [codecompanion.nvim Discussion #1717 / PR #1738](https://github.com/olimorris/codecompanion.nvim/discussions/1717)
- [ericc-ch/copilot-api PR #85](https://github.com/ericc-ch/copilot-api/pull/85)

## Error Handling

All errors inherit from `Dispatch::Adapter::Error` (which inherits from `StandardError`):

```ruby
begin
  adapter.chat(messages)
rescue Dispatch::Adapter::AuthenticationError => e
  puts "Auth failed (#{e.status_code}): #{e.message}"
rescue Dispatch::Adapter::RateLimitError => e
  puts "Rate limited, retry after #{e.retry_after} seconds"
rescue Dispatch::Adapter::RequestError => e
  puts "Bad request (#{e.status_code}): #{e.message}"
rescue Dispatch::Adapter::ServerError => e
  puts "Server error (#{e.status_code}): #{e.message}"
rescue Dispatch::Adapter::ConnectionError => e
  puts "Network error: #{e.message}"
end
```

## Adapter Interface

All adapters subclass `Dispatch::Adapter::Base` and implement:

| Method | Returns | Required? |
|---|---|---|
| `chat(messages, system:, tools:, stream:, max_tokens:, thinking:, &block)` | `Response` | Yes |
| `model_name` | `String` | Yes |
| `count_tokens(messages, system:, tools:)` | `Integer` | No (default: -1) |
| `list_models` | `Array<ModelInfo>` | No |
| `provider_name` | `String` | No (default: class name) |
| `max_context_tokens` | `Integer` or `nil` | No (default: nil) |

## Supported Models

Any model available through the GitHub Copilot API, including:

- `gpt-4.1`, `gpt-4.1-mini`, `gpt-4.1-nano`
- `gpt-4o`, `gpt-4o-mini`
- `o1`, `o1-mini`, `o3`, `o3-mini`, `o4-mini`
- `claude-3.5-sonnet`, `claude-3.7-sonnet`
- `gemini-2.0-flash-001`

## Development

```bash
bundle install
bundle exec rspec        # Run tests (84 examples)
bundle exec rubocop      # Run linter
```

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
