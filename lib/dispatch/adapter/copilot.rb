# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "securerandom"
require "fileutils"

require "dispatch/adapter/interface"
require_relative "rate_limiter"

require_relative "version"

module Dispatch
  module Adapter
    class Copilot < Base
      VERSION = CopilotVersion::VERSION

      API_BASE = "https://api.githubcopilot.com"
      GITHUB_DEVICE_CODE_URL = "https://github.com/login/device/code"
      GITHUB_ACCESS_TOKEN_URL = "https://github.com/login/oauth/access_token"
      COPILOT_TOKEN_URL = "https://api.github.com/copilot_internal/v2/token"
      CLIENT_ID = "Iv1.b507a08c87ecfe98"

      MODEL_CONTEXT_WINDOWS = {
        "gpt-4.1" => 1_047_576,
        "gpt-4.1-mini" => 1_047_576,
        "gpt-4.1-nano" => 1_047_576,
        "gpt-4o" => 128_000,
        "gpt-4o-mini" => 128_000,
        "gpt-4" => 8_192,
        "gpt-4-turbo" => 128_000,
        "gpt-3.5-turbo" => 16_385,
        "o1" => 200_000,
        "o1-mini" => 128_000,
        "o1-preview" => 128_000,
        "o3" => 200_000,
        "o3-mini" => 200_000,
        "o4-mini" => 200_000,
        "claude-3.5-sonnet" => 200_000,
        "claude-3.7-sonnet" => 200_000,
        "gemini-2.0-flash-001" => 1_048_576
      }.freeze

      STOP_REASON_MAP = {
        "stop" => :end_turn,
        "tool_calls" => :tool_use,
        "length" => :max_tokens,
        "content_filter" => :end_turn
      }.freeze

      VALID_THINKING_LEVELS = %w[low medium high].freeze

      # Default Editor-Version header value. Mimics what codecompanion.nvim
      # sends so that requests are indistinguishable on the wire from the
      # well-known Neovim Copilot adapter (which is widely used and trusted).
      # Override via the `editor_version:` constructor option if you need a
      # different value (e.g. your actual running Neovim version).
      DEFAULT_EDITOR_VERSION = "Neovim/0.10.4"

      def initialize(model: "gpt-4.1", github_token: nil, token_path: nil, max_tokens: 8192, thinking: "high",
                     min_request_interval: 3.0, rate_limit: nil, editor_version: DEFAULT_EDITOR_VERSION)
        super()
        @model = model
        @github_token = github_token
        @token_path = token_path || default_token_path
        @default_max_tokens = max_tokens
        @default_thinking = thinking
        @editor_version = editor_version
        @copilot_token = nil
        @copilot_token_expires_at = 0
        @mutex = Mutex.new
        validate_thinking_level!(@default_thinking)

        rate_limit_path = File.join(File.dirname(@token_path), "copilot_rate_limit")
        @rate_limiter = RateLimiter.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: min_request_interval,
          rate_limit: rate_limit
        )
      end

      def chat(messages, system: nil, tools: [], stream: false, max_tokens: nil, thinking: :default, &)
        ensure_authenticated!
        effective_max_tokens = max_tokens || @default_max_tokens
        effective_thinking = thinking == :default ? @default_thinking : thinking
        validate_thinking_level!(effective_thinking)

        if uses_responses_api?
          if stream
            chat_streaming_responses(messages, system, tools, effective_max_tokens, effective_thinking, &)
          else
            chat_non_streaming_responses(messages, system, tools, effective_max_tokens, effective_thinking)
          end
        else
          wire_messages = build_wire_messages(messages, system)
          wire_tools = build_wire_tools(tools)

          body = {
            model: @model,
            messages: wire_messages,
            stream: stream
          }
          if uses_max_completion_tokens?
            body[:max_completion_tokens] = effective_max_tokens
          else
            body[:max_tokens] = effective_max_tokens
          end
          body[:tools] = wire_tools unless wire_tools.empty?
          body[:reasoning_effort] = effective_thinking if effective_thinking

          if stream
            chat_streaming(body, &)
          else
            chat_non_streaming(body)
          end
        end
      end

      def model_name
        @model
      end

      def provider_name
        "GitHub Copilot"
      end

      def max_context_tokens
        MODEL_CONTEXT_WINDOWS[@model]
      end

      def list_models
        ensure_authenticated!
        @rate_limiter.wait!
        uri = URI("#{API_BASE}/models")
        request = Net::HTTP::Get.new(uri)
        apply_headers!(request)
        request["X-Github-Api-Version"] = "2025-10-01"

        response = execute_request(uri, request)
        data = parse_response!(response)
        models = data["data"] || []

        models.filter_map do |m|
          next unless m["model_picker_enabled"]
          next unless chat_model?(m)

          build_model_info(m)
        end
      end

      private

      def validate_thinking_level!(level)
        return if level.nil?

        return if VALID_THINKING_LEVELS.include?(level)

        raise ArgumentError,
              "Invalid thinking level: #{level.inspect}. Must be one of: #{VALID_THINKING_LEVELS.join(", ")}, or nil"
      end

      def chat_model?(model_data)
        capabilities = model_data["capabilities"]
        return true unless capabilities

        model_type = capabilities["type"]
        return true if model_type.nil?

        if model_type.is_a?(Array)
          model_type.include?("chat")
        else
          model_type == "chat"
        end
      end

      def build_model_info(model_data)
        capabilities = model_data["capabilities"] || {}
        supports = capabilities["supports"] || {}
        limits = capabilities["limits"] || {}
        billing = model_data["billing"] || {}

        context_tokens = limits["max_context_window_tokens"] ||
                         MODEL_CONTEXT_WINDOWS.fetch(model_data["id"], 0)

        ModelInfo.new(
          id: model_data["id"],
          name: model_data["name"] || model_data["id"],
          max_context_tokens: context_tokens.to_i,
          supports_vision: !!supports["vision"],
          supports_tool_use: !!supports["tool_calls"],
          supports_streaming: !!supports["streaming"],
          premium_request_multiplier: billing["multiplier"]&.to_f
        )
      end

      def uses_max_completion_tokens?
        @model.match?(/o[1-9]|gpt-5|gemini/)
      end

      # Returns true when the selected model requires the /v1/responses endpoint.
      # This applies to GPT-5 reasoning models. These models reject tool calls on
      # /v1/chat/completions and return a 400 RequestError directing callers to
      # use /v1/responses instead.
      def uses_responses_api?
        @model.match?(/\Agpt-5/)
      end

      def default_token_path
        File.join(Dir.home, ".config", "dispatch", "copilot_github_token")
      end

      # --- Authentication ---

      def ensure_authenticated!
        ensure_github_token!
        ensure_copilot_token!
      end

      def ensure_github_token!
        return if @github_token

        @github_token = load_persisted_token
        return if @github_token

        @github_token = perform_device_flow
        persist_token(@github_token)
      end

      def load_persisted_token
        return nil unless File.exist?(@token_path)

        token = File.read(@token_path).strip
        token.empty? ? nil : token
      end

      def persist_token(token)
        FileUtils.mkdir_p(File.dirname(@token_path))
        File.write(@token_path, token)
        File.chmod(0o600, @token_path)
      end

      def perform_device_flow
        uri = URI(GITHUB_DEVICE_CODE_URL)
        request = Net::HTTP::Post.new(uri)
        request["Accept"] = "application/json"
        request.set_form_data("client_id" => CLIENT_ID, "scope" => "copilot")

        response = execute_request(uri, request)
        data = parse_json_body(response)

        device_code = data["device_code"]
        user_code = data["user_code"]
        verification_uri = data["verification_uri"]
        interval = (data["interval"] || 5).to_i

        warn "\n=== GitHub Device Authorization ==="
        warn "Open: #{verification_uri}"
        warn "Enter code: #{user_code}"
        warn "Waiting for authorization...\n\n"

        poll_for_access_token(device_code, interval)
      end

      def poll_for_access_token(device_code, interval)
        loop do
          sleep(interval)

          uri = URI(GITHUB_ACCESS_TOKEN_URL)
          request = Net::HTTP::Post.new(uri)
          request["Accept"] = "application/json"
          request.set_form_data(
            "client_id" => CLIENT_ID,
            "device_code" => device_code,
            "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
          )

          response = execute_request(uri, request)
          data = parse_json_body(response)

          if data["access_token"]
            return data["access_token"]
          elsif data["error"] == "authorization_pending"
            next
          elsif data["error"] == "slow_down"
            interval += 5
          else
            raise AuthenticationError.new(
              "Device flow failed: #{data["error_description"] || data["error"]}",
              provider: "GitHub Copilot"
            )
          end
        end
      end

      def ensure_copilot_token!
        @mutex.synchronize do
          return if @copilot_token && Time.now.to_i < @copilot_token_expires_at - 60

          uri = URI(COPILOT_TOKEN_URL)
          request = Net::HTTP::Get.new(uri)
          request["Authorization"] = "token #{@github_token}"
          request["Accept"] = "application/json"

          response = execute_request(uri, request)

          unless response.is_a?(Net::HTTPSuccess)
            raise AuthenticationError.new(
              "Failed to obtain Copilot token: #{response.code} #{response.body}",
              status_code: response.code.to_i,
              provider: "GitHub Copilot"
            )
          end

          data = parse_json_body(response)
          @copilot_token = data["token"]
          @copilot_token_expires_at = data["expires_at"].to_i
        end
      end

      # --- HTTP helpers ---

      # Apply the request headers used for Copilot chat completions.
      #
      # Header set is intentionally identical to what codecompanion.nvim's
      # Copilot adapter sends (see lua/codecompanion/adapters/http/copilot/init.lua):
      #
      #   - Authorization: Bearer <copilot-token>
      #   - Content-Type: application/json
      #   - Copilot-Integration-Id: vscode-chat
      #   - Editor-Version: Neovim/x.y.z (configurable)
      #   - X-Initiator: user|agent (only added by callers via apply_headers!)
      #
      # We deliberately DO NOT send `Openai-Intent` because codecompanion
      # does not, and matching that wire profile is the goal.
      def apply_headers!(request, initiator: "user")
        request["Authorization"] = "Bearer #{@copilot_token}"
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request["Copilot-Integration-Id"] = "vscode-chat"
        request["Editor-Version"] = @editor_version
        request["X-Initiator"] = initiator
      end

      # Decides the value of the `X-Initiator` header that GitHub Copilot uses
      # to classify a request as a billable premium request ("user") or a
      # non-billable agent continuation ("agent").
      #
      # Strategy: "savings" mode (matches ericc-ch/copilot-api default and is
      # more aggressive than codecompanion.nvim / VS Code).
      #
      #   * If the wire payload contains ANY assistant or tool message, it means
      #     the model has already produced at least one turn — therefore this
      #     send is part of an ongoing agent loop (typically a tool-result
      #     follow-up) and is NOT a fresh user-initiated turn. → "agent".
      #   * Otherwise this is the very first send for a conversation (only
      #     system + user messages present). → "user".
      #
      # Only the initial user prompt of an automation should be billed as a
      # premium request; every subsequent tool-loop continuation is free.
      #
      # Rationale & references:
      #   - codecompanion.nvim PR #1738 / Discussion #1717
      #   - ericc-ch/copilot-api PR #85 ("savings" vs "per-user-prompt" modes)
      #   - https://docs.github.com/en/copilot/concepts/billing/copilot-requests
      def x_initiator_for(wire_messages)
        wire_messages.any? { |m| %w[assistant tool].include?(m[:role].to_s) } ? "agent" : "user"
      end

      def execute_request(uri, request)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 30
        http.read_timeout = 120
        http.start { |h| h.request(request) }
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
             Net::OpenTimeout, Net::ReadTimeout, SocketError => e
        raise ConnectionError.new(
          "Connection failed: #{e.message}",
          provider: "GitHub Copilot"
        )
      end

      def execute_streaming_request(uri, request)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 30
        http.read_timeout = 300

        http.start do |h|
          h.request(request) do |response|
            handle_error_response!(response) unless response.is_a?(Net::HTTPSuccess)
            yield(response)
          end
        end
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
             Net::OpenTimeout, Net::ReadTimeout, SocketError => e
        raise ConnectionError.new(
          "Connection failed: #{e.message}",
          provider: "GitHub Copilot"
        )
      end

      def parse_response!(response)
        handle_error_response!(response) unless response.is_a?(Net::HTTPSuccess)
        parse_json_body(response)
      end

      def parse_json_body(response)
        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise RequestError.new(
          "Invalid JSON response: #{e.message}",
          provider: "GitHub Copilot"
        )
      end

      def handle_error_response!(response)
        code = response.code.to_i
        body = response.body.to_s
        message = begin
          JSON.parse(body).dig("error", "message") || body
        rescue JSON::ParserError
          body
        end

        case code
        when 401, 403
          raise AuthenticationError.new(message, status_code: code, provider: "GitHub Copilot")
        when 429
          retry_after = response["Retry-After"]&.to_i
          raise RateLimitError.new(message, status_code: code, provider: "GitHub Copilot", retry_after: retry_after)
        when 400, 422
          raise RequestError.new(message, status_code: code, provider: "GitHub Copilot")
        when 500, 502, 503
          raise ServerError.new(message, status_code: code, provider: "GitHub Copilot")
        else
          raise Error.new(message, status_code: code, provider: "GitHub Copilot")
        end
      end

      # --- Message conversion ---

      def build_wire_messages(messages, system)
        wire = []
        wire << { role: "system", content: system } if system

        messages.each do |msg|
          wire_msg = convert_message(msg)
          if wire_msg.is_a?(Array)
            wire.concat(wire_msg)
          else
            wire << wire_msg
          end
        end

        merge_consecutive_roles(wire)
      end

      # Converts canonical messages to the flat `input` array required by
      # POST /v1/responses. System prompt is prepended as a system-role item.
      # The Responses API does not support a top-level `system` parameter —
      # the system message must be the first element of `input`.
      def build_responses_api_input(messages, system)
        input = []
        input << { role: "system", content: system } if system

        messages.each do |msg|
          input.concat(convert_message_to_responses_input(msg))
        end

        input
      end

      # Converts a single canonical Message to one or more Responses API input
      # items. Returns an Array (always) so results can be flat-concatenated.
      def convert_message_to_responses_input(msg)
        case msg.content
        when String
          [{ role: msg.role, content: msg.content }]
        when Array
          convert_content_blocks_to_responses_input(msg)
        else
          [{ role: msg.role, content: msg.content.to_s }]
        end
      end

      # Converts an array of content blocks (TextBlock, ToolUseBlock,
      # ToolResultBlock) from a single Message into Responses API input items.
      #
      # Key differences from the Chat Completions conversion:
      # - ToolUseBlock  → top-level {type: "function_call", ...} item (not nested
      #   under an assistant message role)
      # - ToolResultBlock → top-level {type: "function_call_output", ...} item
      # - TextBlock in assistant message → {role: "assistant", content: [{type:
      #   "output_text", text: "..."}]}
      def convert_content_blocks_to_responses_input(msg)
        items = []
        text_parts = []

        msg.content.each do |block|
          case block
          when TextBlock
            text_parts << block.text
          when ImageBlock
            raise NotImplementedError, "ImageBlock is not yet supported by the Copilot adapter"
          when ToolUseBlock
            # Flush any accumulated text first as an assistant message
            unless text_parts.empty?
              items << {
                role: "assistant",
                content: [{ type: "output_text", text: text_parts.join("\n") }]
              }
              text_parts = []
            end
            items << {
              type: "function_call",
              call_id: block.id,
              name: block.name,
              arguments: JSON.generate(block.arguments)
            }
          when ToolResultBlock
            items << {
              type: "function_call_output",
              call_id: block.tool_use_id,
              output: tool_result_content(block)
            }
          end
        end

        # Flush any remaining text
        unless text_parts.empty?
          items << if msg.role == "assistant"
                     {
                       role: "assistant",
                       content: [{ type: "output_text", text: text_parts.join("\n") }]
                     }
                   else
                     { role: msg.role, content: text_parts.join("\n") }
                   end
        end

        items
      end

      def convert_message(msg)
        case msg.content
        when String
          { role: msg.role, content: msg.content }
        when Array
          convert_content_blocks(msg)
        else
          { role: msg.role, content: msg.content.to_s }
        end
      end

      def convert_content_blocks(msg)
        results = []
        text_parts = []
        tool_calls = []

        msg.content.each do |block|
          case block
          when TextBlock
            text_parts << block.text
          when ImageBlock
            raise NotImplementedError, "ImageBlock is not yet supported by the Copilot adapter"
          when ToolUseBlock
            tool_calls << {
              id: block.id,
              type: "function",
              function: {
                name: block.name,
                arguments: JSON.generate(block.arguments)
              }
            }
          when ToolResultBlock
            results << {
              role: "tool",
              tool_call_id: block.tool_use_id,
              content: tool_result_content(block)
            }
          end
        end

        if msg.role == "assistant" && !tool_calls.empty?
          assistant_msg = { role: "assistant" }
          assistant_msg[:content] = text_parts.join("\n") unless text_parts.empty?
          assistant_msg[:tool_calls] = tool_calls
          results.unshift(assistant_msg)
        elsif !text_parts.empty?
          results.unshift({ role: msg.role, content: text_parts.join("\n") })
        end

        results
      end

      def tool_result_content(block)
        case block.content
        when String
          block.content
        when Array
          block.content.map(&:text).join("\n")
        else
          block.content.to_s
        end
      end

      def merge_consecutive_roles(messages)
        return messages if messages.empty?

        merged = [messages.first.dup]

        messages[1..].each do |msg|
          prev = merged.last

          if prev[:role] == msg[:role] && prev[:role] != "tool" && !msg.key?(:tool_calls) && !prev.key?(:tool_calls)
            prev[:content] = [prev[:content], msg[:content]].compact.join("\n\n")
          else
            merged << msg.dup
          end
        end

        merged
      end

      # --- Tool conversion ---

      def build_wire_tools(tools)
        tools.map do |td|
          {
            type: "function",
            function: {
              name: tool_attr(td, :name),
              description: tool_attr(td, :description),
              parameters: tool_attr(td, :parameters)
            }
          }
        end
      end

      def tool_attr(tool, key)
        if tool.respond_to?(key)
          tool.public_send(key)
        elsif tool.is_a?(Hash)
          tool[key] || tool[key.to_s]
        end
      end

      # Assembles the full request body for POST /v1/responses.
      #
      # Key differences from the Chat Completions body:
      # - Uses `input` instead of `messages`.
      # - Uses `max_output_tokens` instead of `max_tokens`/`max_completion_tokens`.
      # - Uses `reasoning: {effort:}` instead of `reasoning_effort`.
      # - Tool definitions omit the `function` wrapper — name/description/parameters
      #   are top-level inside the tool object.
      def build_responses_api_body(messages, system, tools, stream, max_tokens, thinking)
        input = build_responses_api_input(messages, system)
        wire_tools = build_responses_api_tools(tools)

        body = {
          model: @model,
          input: input,
          stream: stream,
          max_output_tokens: max_tokens
        }

        body[:tools] = wire_tools unless wire_tools.empty?
        body[:reasoning] = { effort: thinking } if thinking

        body
      end

      # Converts ToolDefinition structs (or plain hashes) to the Responses API
      # tool format. Unlike Chat Completions, there is no `function` wrapper —
      # name, description, and parameters are direct keys on the tool object.
      def build_responses_api_tools(tools)
        tools.map do |td|
          {
            type: "function",
            name: tool_attr(td, :name),
            description: tool_attr(td, :description),
            parameters: tool_attr(td, :parameters)
          }
        end
      end

      # --- Chat (non-streaming) ---

      def chat_non_streaming(body)
        @rate_limiter.wait!
        uri = URI("#{API_BASE}/chat/completions")
        request = Net::HTTP::Post.new(uri)
        apply_headers!(request, initiator: x_initiator_for(body[:messages] || []))
        request.body = JSON.generate(deep_utf8(body))

        response = execute_request(uri, request)
        data = parse_response!(response)

        build_response(data)
      end

      def build_response(data)
        choice = data["choices"]&.first
        return empty_response(data) unless choice

        message = choice["message"] || {}
        content = message["content"]
        tool_calls = (message["tool_calls"] || []).map do |tc|
          func = tc["function"]
          ToolUseBlock.new(
            id: tc["id"],
            name: func["name"],
            arguments: parse_tool_arguments(func["arguments"])
          )
        end

        stop_reason = STOP_REASON_MAP.fetch(choice["finish_reason"], :end_turn)

        usage_data = data["usage"] || {}
        usage = Usage.new(
          input_tokens: usage_data["prompt_tokens"] || 0,
          output_tokens: usage_data["completion_tokens"] || 0
        )

        Response.new(
          content: content,
          tool_calls: tool_calls,
          model: data["model"] || @model,
          stop_reason: stop_reason,
          usage: usage
        )
      end

      def empty_response(data)
        usage_data = data["usage"] || {}
        Response.new(
          model: data["model"] || @model,
          stop_reason: :end_turn,
          usage: Usage.new(
            input_tokens: usage_data["prompt_tokens"] || 0,
            output_tokens: usage_data["completion_tokens"] || 0
          )
        )
      end

      # Non-streaming chat via POST /v1/responses.
      # Called when uses_responses_api? is true and stream is false.
      def chat_non_streaming_responses(messages, system, tools, max_tokens, thinking)
        @rate_limiter.wait!
        body = build_responses_api_body(messages, system, tools, false, max_tokens, thinking)
        wire_messages = build_responses_api_input(messages, system)

        uri = URI("#{API_BASE}/responses")
        request = Net::HTTP::Post.new(uri)
        apply_headers!(request, initiator: x_initiator_for_responses(wire_messages))
        request.body = JSON.generate(deep_utf8(body))

        response = execute_request(uri, request)
        data = parse_response!(response)
        build_response_from_responses_api(data)
      end

      # Builds a canonical Response from a /v1/responses non-streaming body.
      def build_response_from_responses_api(data)
        output = data["output"] || []
        text_parts = []
        tool_calls = []

        output.each do |item|
          case item["type"]
          when "message"
            (item["content"] || []).each do |part|
              text_parts << part["text"] if part["type"] == "output_text" && part["text"]
            end
          when "function_call"
            tool_calls << ToolUseBlock.new(
              id: item["call_id"] || item["id"],
              name: item["name"],
              arguments: parse_tool_arguments(item["arguments"])
            )
          end
        end

        stop_reason = tool_calls.any? ? :tool_use : :end_turn
        content = text_parts.empty? ? nil : text_parts.join

        usage_data = data["usage"] || {}
        usage = Usage.new(
          input_tokens: usage_data["input_tokens"] || 0,
          output_tokens: usage_data["output_tokens"] || 0
        )

        Response.new(
          content: content,
          tool_calls: tool_calls,
          model: data["model"] || @model,
          stop_reason: stop_reason,
          usage: usage
        )
      end

      # Determines X-Initiator for a Responses API call.
      # Same logic as x_initiator_for but operates on the already-built `input`
      # array where items use `type: "function_call"` / `type: "function_call_output"`
      # instead of role-based items.
      def x_initiator_for_responses(input_items)
        if input_items.any? do |item|
          item[:role].to_s == "assistant" ||
          item[:type].to_s == "function_call" ||
          item[:type].to_s == "function_call_output"
        end
          "agent"
        else
          "user"
        end
      end

      # Recursively coerces every String inside a wire-body to valid UTF-8.
      #
      # Tool results (grep output, file reads, shell stdout) frequently arrive
      # tagged as US-ASCII or BINARY/ASCII-8BIT even though the bytes are
      # legitimate UTF-8 (e.g. an em-dash \xE2\x80\x94 inside a source
      # comment). `JSON.generate` then raises
      # `Encoding::InvalidByteSequenceError: "\xE2" on US-ASCII` because it
      # tries to re-encode the mistagged string.
      #
      # We force_encoding to UTF-8 (no byte rewrite) and then `scrub` to
      # replace any genuinely invalid sequences with the Unicode replacement
      # character so JSON.generate can never fail on user-provided text.
      def deep_utf8(obj)
        case obj
        when String
          s = obj.dup
          s.force_encoding(Encoding::UTF_8)
          s.valid_encoding? ? s : s.scrub("\uFFFD")
        when Array
          obj.map { |v| deep_utf8(v) }
        when Hash
          obj.each_with_object({}) { |(k, v), h| h[k] = deep_utf8(v) }
        else
          obj
        end
      end

      def parse_tool_arguments(args_string)
        return {} if args_string.nil? || args_string.empty?

        JSON.parse(args_string)
      rescue JSON::ParserError
        {}
      end

      # --- Chat (streaming) ---

      def chat_streaming(body, &block)
        @rate_limiter.wait!
        uri = URI("#{API_BASE}/chat/completions")
        request = Net::HTTP::Post.new(uri)
        apply_headers!(request, initiator: x_initiator_for(body[:messages] || []))
        request.body = JSON.generate(deep_utf8(body))

        collected = new_stream_collector

        execute_streaming_request(uri, request) do |response|
          buffer = +""

          response.read_body do |chunk|
            buffer << chunk
            process_sse_buffer(buffer, collected, &block)
          end
        end

        build_streaming_response(collected)
      end

      def new_stream_collector
        {
          content: +"",
          tool_calls: {},
          model: @model,
          finish_reason: nil,
          input_tokens: 0,
          output_tokens: 0
        }
      end

      def process_sse_buffer(buffer, collected, &)
        while (line_end = buffer.index("\n"))
          line = buffer.slice!(0..line_end).strip
          next if line.empty?
          next unless line.start_with?("data: ")

          data_str = line.delete_prefix("data: ")
          next if data_str == "[DONE]"

          data = JSON.parse(data_str)
          process_stream_chunk(data, collected, &)
        end
      rescue JSON::ParserError
        # Incomplete JSON chunk, will be completed on next read
        nil
      end

      def process_stream_chunk(data, collected, &)
        collected[:model] = data["model"] if data["model"]

        choice = data.dig("choices", 0)
        return unless choice

        collected[:finish_reason] = choice["finish_reason"] if choice["finish_reason"]
        delta = choice["delta"] || {}

        process_text_delta(delta, collected, &)
        process_tool_call_deltas(delta, collected, &)

        process_usage(data, collected)
      end

      def process_text_delta(delta, collected)
        return unless delta["content"]

        collected[:content] << delta["content"]
        yield(StreamDelta.new(type: :text_delta, text: delta["content"]))
      end

      def process_tool_call_deltas(delta, collected)
        return unless delta["tool_calls"]

        delta["tool_calls"].each do |tc_delta|
          index = tc_delta["index"]
          tc = (collected[:tool_calls][index] ||= { id: nil, name: +"", arguments: +"" })

          if tc_delta["id"]
            tc[:id] = tc_delta["id"]
            tc[:name] = tc_delta.dig("function", "name") || ""
            yield(StreamDelta.new(
              type: :tool_use_start,
              tool_call_id: tc[:id],
              tool_name: tc[:name]
            ))
          end

          next unless (arg_frag = tc_delta.dig("function", "arguments"))
          next if arg_frag.empty?

          tc[:arguments] << arg_frag
          yield(StreamDelta.new(
            type: :tool_use_delta,
            tool_call_id: tc[:id],
            argument_delta: arg_frag
          ))
        end
      end

      def process_usage(data, collected)
        return unless data["usage"]

        collected[:input_tokens] = data["usage"]["prompt_tokens"] || collected[:input_tokens]
        collected[:output_tokens] = data["usage"]["completion_tokens"] || collected[:output_tokens]
      end

      def build_streaming_response(collected)
        tool_calls = collected[:tool_calls].values.map do |tc|
          ToolUseBlock.new(
            id: tc[:id],
            name: tc[:name],
            arguments: parse_tool_arguments(tc[:arguments])
          )
        end

        stop_reason = STOP_REASON_MAP.fetch(collected[:finish_reason], :end_turn)
        content = collected[:content].empty? ? nil : collected[:content]

        Response.new(
          content: content,
          tool_calls: tool_calls,
          model: collected[:model],
          stop_reason: stop_reason,
          usage: Usage.new(
            input_tokens: collected[:input_tokens],
            output_tokens: collected[:output_tokens]
          )
        )
      end

      # Streaming chat via POST /v1/responses.
      # Called when uses_responses_api? is true and stream is true.
      def chat_streaming_responses(messages, system, tools, max_tokens, thinking, &block)
        @rate_limiter.wait!
        body = build_responses_api_body(messages, system, tools, true, max_tokens, thinking)
        wire_input = build_responses_api_input(messages, system)

        uri = URI("#{API_BASE}/responses")
        request = Net::HTTP::Post.new(uri)
        apply_headers!(request, initiator: x_initiator_for_responses(wire_input))
        request.body = JSON.generate(deep_utf8(body))

        collector = new_responses_stream_collector

        execute_streaming_request(uri, request) do |response|
          buffer = +""
          response.read_body do |chunk|
            buffer << chunk
            process_responses_sse_buffer(buffer, collector, &block)
          end
        end

        build_streaming_response_from_responses(collector)
      end

      def new_responses_stream_collector
        {
          # text_parts: Hash<output_index => String> — accumulated text fragments
          text_parts: Hash.new { |h, k| h[k] = +"" },
          # tool_calls: Hash<item_id => {call_id:, name:, arguments:}>
          tool_calls: {},
          # order: Array of [:text, output_index] or [:tool, item_id] in appearance order
          order: [],
          model: @model,
          input_tokens: 0,
          output_tokens: 0
        }
      end

      def process_responses_sse_buffer(buffer, collector, &)
        while (line_end = buffer.index("\n"))
          line = buffer.slice!(0..line_end).strip
          next if line.empty?
          next unless line.start_with?("data: ")

          data_str = line.delete_prefix("data: ")
          next if data_str == "[DONE]"

          data = JSON.parse(data_str)
          process_responses_stream_event(data, collector, &)
        end
      rescue JSON::ParserError
        nil
      end

      def process_responses_stream_event(data, collector, &block)
        case data["type"]
        when "response.output_item.added"
          handle_responses_output_item_added(data, collector, &block)
        when "response.output_text.delta"
          output_index = data["output_index"] || 0
          fragment = data["delta"].to_s
          collector[:text_parts][output_index] << fragment
          block.call(StreamDelta.new(type: :text_delta, text: fragment))
        when "response.function_call_arguments.delta"
          handle_responses_arguments_delta(data, collector, &block)
        when "response.completed"
          usage = data.dig("response", "usage") || {}
          collector[:input_tokens] = usage["input_tokens"] || collector[:input_tokens]
          collector[:output_tokens] = usage["output_tokens"] || collector[:output_tokens]
          model = data.dig("response", "model")
          collector[:model] = model if model
        end
      end

      def handle_responses_output_item_added(data, collector, &block)
        item = data["item"] || {}
        case item["type"]
        when "function_call"
          item_id = item["id"]
          collector[:tool_calls][item_id] = {
            call_id: item["call_id"] || item_id,
            name: item["name"] || "",
            arguments: +""
          }
          collector[:order] << [:tool, item_id]
          block.call(StreamDelta.new(
                       type: :tool_use_start,
                       tool_call_id: item["call_id"] || item_id,
                       tool_name: item["name"] || ""
                     ))
        when "message"
          output_index = data["output_index"] || 0
          collector[:order] << [:text, output_index] unless collector[:order].any? { |t, i| t == :text && i == output_index }
        end
      end

      def handle_responses_arguments_delta(data, collector, &block)
        item_id = data["item_id"]
        fragment = data["delta"].to_s
        tc = collector[:tool_calls][item_id]
        return unless tc

        tc[:arguments] << fragment
        block.call(StreamDelta.new(
                     type: :tool_use_delta,
                     tool_call_id: tc[:call_id],
                     argument_delta: fragment
                   ))
      end

      def build_streaming_response_from_responses(collector)
        tool_calls = collector[:tool_calls].values.map do |tc|
          ToolUseBlock.new(
            id: tc[:call_id],
            name: tc[:name],
            arguments: parse_tool_arguments(tc[:arguments])
          )
        end

        all_text = collector[:text_parts].keys.sort.map { |idx| collector[:text_parts][idx] }.join
        content = all_text.empty? ? nil : all_text
        stop_reason = tool_calls.any? ? :tool_use : :end_turn

        Response.new(
          content: content,
          tool_calls: tool_calls,
          model: collector[:model],
          stop_reason: stop_reason,
          usage: Usage.new(
            input_tokens: collector[:input_tokens],
            output_tokens: collector[:output_tokens]
          )
        )
      end
    end
  end
end
