# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Dispatch::Adapter::Copilot do
  let(:copilot_token) { "cop_test_token_abc" }
  let(:github_token) { "gho_test_github_token" }

  # ---------------------------------------------------------------------------
  # SAFETY: this MUST be the first test in the file. If WebMock is not
  # globally blocking real network access, every other test in this gem could
  # potentially hit the real GitHub Copilot API and consume premium-request
  # quota / leak credentials. If this test fails, STOP and fix spec_helper
  # before running any other spec.
  # ---------------------------------------------------------------------------
  describe "!! network safety !!" do
    it "globally blocks real outbound HTTP via WebMock" do
      expect(WebMock.net_connect_allowed?).to be(false)
    end

    it "raises when an unstubbed request is attempted" do
      expect do
        Net::HTTP.get(URI("https://api.githubcopilot.com/never-should-fire"))
      end.to raise_error(WebMock::NetConnectNotAllowedError)
    end

    it "forbids localhost as well (no accidental dev-server contact)" do
      # The spec_helper passes allow_localhost: false. Verify it.
      expect do
        Net::HTTP.get(URI("http://127.0.0.1:1/should-not-fire"))
      end.to raise_error(WebMock::NetConnectNotAllowedError)
    end
  end

  let(:adapter) do
    described_class.new(
      model: "gpt-4.1",
      github_token: github_token,
      max_tokens: 4096,
      min_request_interval: 0
    )
  end

  before do
    # Stub Copilot token exchange
    stub_request(:get, "https://api.github.com/copilot_internal/v2/token")
      .with(headers: { "Authorization" => "token #{github_token}" })
      .to_return(
        status: 200,
        body: JSON.generate({
                              "token" => copilot_token,
                              "expires_at" => (Time.now.to_i + 3600)
                            }),
        headers: { "Content-Type" => "application/json" }
      )
  end

  describe "#model_name" do
    it "returns the model identifier" do
      expect(adapter.model_name).to eq("gpt-4.1")
    end
  end

  describe "VERSION" do
    it "is accessible" do
      expect(Dispatch::Adapter::Copilot::VERSION).to eq("0.4.0")
    end
  end

  describe "#provider_name" do
    it "returns 'GitHub Copilot'" do
      expect(adapter.provider_name).to eq("GitHub Copilot")
    end
  end

  describe "#max_context_tokens" do
    it "returns the context window for known models" do
      expect(adapter.max_context_tokens).to eq(1_047_576)
    end

    it "returns nil for unknown models" do
      unknown = described_class.new(model: "unknown-model", github_token: github_token)
      expect(unknown.max_context_tokens).to be_nil
    end
  end

  describe "#count_tokens" do
    it "returns -1 (inherited from Base)" do
      expect(adapter.count_tokens([])).to eq(-1)
    end
  end

  describe "#chat" do
    context "with a text-only response" do
      before do
        stub_request(:post, "https://api.githubcopilot.com/chat/completions")
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "id" => "chatcmpl-123",
                                  "model" => "gpt-4.1",
                                  "choices" => [{
                                    "index" => 0,
                                    "message" => { "role" => "assistant", "content" => "Hello there!" },
                                    "finish_reason" => "stop"
                                  }],
                                  "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns a Response with content" do
        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        response = adapter.chat(messages)

        expect(response).to be_a(Dispatch::Adapter::Response)
        expect(response.content).to eq("Hello there!")
        expect(response.tool_calls).to be_empty
        expect(response.model).to eq("gpt-4.1")
        expect(response.stop_reason).to eq(:end_turn)
        expect(response.usage.input_tokens).to eq(10)
        expect(response.usage.output_tokens).to eq(5)
      end
    end

    context "with a tool call response" do
      before do
        stub_request(:post, "https://api.githubcopilot.com/chat/completions")
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "id" => "chatcmpl-456",
                                  "model" => "gpt-4.1",
                                  "choices" => [{
                                    "index" => 0,
                                    "message" => {
                                      "role" => "assistant",
                                      "content" => nil,
                                      "tool_calls" => [{
                                        "id" => "call_abc",
                                        "type" => "function",
                                        "function" => {
                                          "name" => "get_weather",
                                          "arguments" => '{"city":"New York"}'
                                        }
                                      }]
                                    },
                                    "finish_reason" => "tool_calls"
                                  }],
                                  "usage" => { "prompt_tokens" => 15, "completion_tokens" => 10 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns a Response with tool_calls as ToolUseBlock array" do
        messages = [Dispatch::Adapter::Message.new(role: "user", content: "What's the weather?")]
        response = adapter.chat(messages)

        expect(response.content).to be_nil
        expect(response.stop_reason).to eq(:tool_use)
        expect(response.tool_calls.size).to eq(1)

        tc = response.tool_calls.first
        expect(tc).to be_a(Dispatch::Adapter::ToolUseBlock)
        expect(tc.id).to eq("call_abc")
        expect(tc.name).to eq("get_weather")
        expect(tc.arguments).to eq({ "city" => "New York" })
      end
    end

    context "with multiple tool calls in response" do
      before do
        stub_request(:post, "https://api.githubcopilot.com/chat/completions")
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{
                                    "index" => 0,
                                    "message" => {
                                      "role" => "assistant",
                                      "content" => nil,
                                      "tool_calls" => [
                                        {
                                          "id" => "call_1",
                                          "type" => "function",
                                          "function" => { "name" => "get_weather", "arguments" => '{"city":"NYC"}' }
                                        },
                                        {
                                          "id" => "call_2",
                                          "type" => "function",
                                          "function" => { "name" => "get_time", "arguments" => '{"timezone":"EST"}' }
                                        }
                                      ]
                                    },
                                    "finish_reason" => "tool_calls"
                                  }],
                                  "usage" => { "prompt_tokens" => 20, "completion_tokens" => 15 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns multiple ToolUseBlocks" do
        messages = [Dispatch::Adapter::Message.new(role: "user", content: "weather and time?")]
        response = adapter.chat(messages)

        expect(response.tool_calls.size).to eq(2)
        expect(response.tool_calls[0].name).to eq("get_weather")
        expect(response.tool_calls[0].id).to eq("call_1")
        expect(response.tool_calls[1].name).to eq("get_time")
        expect(response.tool_calls[1].id).to eq("call_2")
        expect(response.tool_calls[1].arguments).to eq({ "timezone" => "EST" })
      end
    end

    context "with a mixed response (text + tool calls)" do
      before do
        stub_request(:post, "https://api.githubcopilot.com/chat/completions")
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "id" => "chatcmpl-789",
                                  "model" => "gpt-4.1",
                                  "choices" => [{
                                    "index" => 0,
                                    "message" => {
                                      "role" => "assistant",
                                      "content" => "Let me check that for you.",
                                      "tool_calls" => [{
                                        "id" => "call_def",
                                        "type" => "function",
                                        "function" => {
                                          "name" => "search",
                                          "arguments" => '{"query":"Ruby gems"}'
                                        }
                                      }]
                                    },
                                    "finish_reason" => "tool_calls"
                                  }],
                                  "usage" => { "prompt_tokens" => 20, "completion_tokens" => 15 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns both content and tool_calls" do
        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Search for Ruby gems")]
        response = adapter.chat(messages)

        expect(response.content).to eq("Let me check that for you.")
        expect(response.tool_calls.size).to eq(1)
        expect(response.stop_reason).to eq(:tool_use)
      end
    end

    context "with system: parameter" do
      it "prepends system message in the wire format" do
        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 body["messages"].first == { "role" => "system", "content" => "You are helpful." }
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "OK" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        adapter.chat(messages, system: "You are helpful.")

        expect(stub).to have_been_requested
      end
    end

    context "with max_tokens: per-call override" do
      it "uses per-call max_tokens over constructor default" do
        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 body["max_tokens"] == 100
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "short" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        adapter.chat(messages, max_tokens: 100)

        expect(stub).to have_been_requested
      end

      it "uses constructor default when max_tokens not specified" do
        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 body["max_tokens"] == 4096
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        adapter.chat(messages)

        expect(stub).to have_been_requested
      end
    end

    context "with tools parameter" do
      it "sends tools in OpenAI function format" do
        tool = Dispatch::Adapter::ToolDefinition.new(
          name: "get_weather",
          description: "Get weather for a city",
          parameters: { "type" => "object", "properties" => { "city" => { "type" => "string" } } }
        )

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 body["tools"] == [{
                   "type" => "function",
                   "function" => {
                     "name" => "get_weather",
                     "description" => "Get weather for a city",
                     "parameters" => { "type" => "object", "properties" => { "city" => { "type" => "string" } } }
                   }
                 }]
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "weather?")]
        adapter.chat(messages, tools: [tool])

        expect(stub).to have_been_requested
      end

      it "accepts plain hashes with symbol keys as tools" do
        tool_hash = {
          name: "get_weather",
          description: "Get weather for a city",
          parameters: { "type" => "object", "properties" => { "city" => { "type" => "string" } } }
        }

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 body["tools"] == [{
                   "type" => "function",
                   "function" => {
                     "name" => "get_weather",
                     "description" => "Get weather for a city",
                     "parameters" => { "type" => "object", "properties" => { "city" => { "type" => "string" } } }
                   }
                 }]
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "weather?")]
        adapter.chat(messages, tools: [tool_hash])

        expect(stub).to have_been_requested
      end

      it "accepts plain hashes with string keys as tools" do
        tool_hash = {
          "name" => "get_weather",
          "description" => "Get weather for a city",
          "parameters" => { "type" => "object", "properties" => { "city" => { "type" => "string" } } }
        }

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 body["tools"] == [{
                   "type" => "function",
                   "function" => {
                     "name" => "get_weather",
                     "description" => "Get weather for a city",
                     "parameters" => { "type" => "object", "properties" => { "city" => { "type" => "string" } } }
                   }
                 }]
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "weather?")]
        adapter.chat(messages, tools: [tool_hash])

        expect(stub).to have_been_requested
      end

      it "accepts a mix of ToolDefinition structs and plain hashes" do
        tool_struct = Dispatch::Adapter::ToolDefinition.new(
          name: "get_weather",
          description: "Get weather",
          parameters: { "type" => "object", "properties" => {} }
        )
        tool_hash = {
          name: "get_time",
          description: "Get time",
          parameters: { "type" => "object", "properties" => {} }
        }

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 body["tools"].size == 2 &&
                   body["tools"][0]["function"]["name"] == "get_weather" &&
                   body["tools"][1]["function"]["name"] == "get_time"
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "both?")]
        adapter.chat(messages, tools: [tool_struct, tool_hash])

        expect(stub).to have_been_requested
      end

      it "does not include tools key when tools array is empty" do
        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 !body.key?("tools")
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        adapter.chat(messages)

        expect(stub).to have_been_requested
      end
    end

    context "with ToolUseBlock and ToolResultBlock in messages" do
      it "converts to OpenAI wire format" do
        tool_use = Dispatch::Adapter::ToolUseBlock.new(
          id: "call_1", name: "get_weather", arguments: { "city" => "NYC" }
        )
        tool_result = Dispatch::Adapter::ToolResultBlock.new(
          tool_use_id: "call_1", content: "72F and sunny"
        )

        messages = [
          Dispatch::Adapter::Message.new(role: "user", content: "What's the weather?"),
          Dispatch::Adapter::Message.new(role: "assistant", content: [tool_use]),
          Dispatch::Adapter::Message.new(role: "user", content: [tool_result])
        ]

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 msgs = body["messages"]
                 # user message
                 msgs[0]["role"] == "user" &&
                   # assistant with tool_calls
                   msgs[1]["role"] == "assistant" &&
                   msgs[1]["tool_calls"].is_a?(Array) &&
                   msgs[1]["tool_calls"][0]["id"] == "call_1" &&
                   # tool result
                   msgs[2]["role"] == "tool" &&
                   msgs[2]["tool_call_id"] == "call_1" &&
                   msgs[2]["content"] == "72F and sunny"
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "It's 72F and sunny in NYC!" },
                                                  "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 20, "completion_tokens" => 10 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        adapter.chat(messages)
        expect(stub).to have_been_requested
      end
    end

    context "with ImageBlock" do
      it "raises NotImplementedError" do
        image = Dispatch::Adapter::ImageBlock.new(source: "base64data", media_type: "image/png")
        messages = [Dispatch::Adapter::Message.new(role: "user", content: [image])]

        expect { adapter.chat(messages) }.to raise_error(NotImplementedError, /ImageBlock/)
      end
    end

    context "with TextBlock array in user message" do
      it "converts to string content" do
        text_blocks = [
          Dispatch::Adapter::TextBlock.new(text: "First paragraph."),
          Dispatch::Adapter::TextBlock.new(text: "Second paragraph.")
        ]
        messages = [Dispatch::Adapter::Message.new(role: "user", content: text_blocks)]

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 msgs = body["messages"]
                 msgs[0]["content"] == "First paragraph.\nSecond paragraph."
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        adapter.chat(messages)
        expect(stub).to have_been_requested
      end
    end

    context "with ToolResultBlock containing array content" do
      it "joins TextBlock array into string" do
        tool_use = Dispatch::Adapter::ToolUseBlock.new(
          id: "call_1", name: "search", arguments: { "q" => "test" }
        )
        tool_result = Dispatch::Adapter::ToolResultBlock.new(
          tool_use_id: "call_1",
          content: [
            Dispatch::Adapter::TextBlock.new(text: "Result line 1"),
            Dispatch::Adapter::TextBlock.new(text: "Result line 2")
          ]
        )

        messages = [
          Dispatch::Adapter::Message.new(role: "user", content: "search"),
          Dispatch::Adapter::Message.new(role: "assistant", content: [tool_use]),
          Dispatch::Adapter::Message.new(role: "user", content: [tool_result])
        ]

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 msgs = body["messages"]
                 tool_msg = msgs.find { |m| m["role"] == "tool" }
                 tool_msg && tool_msg["content"] == "Result line 1\nResult line 2"
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 10, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        adapter.chat(messages)
        expect(stub).to have_been_requested
      end
    end

    context "with ToolResultBlock with is_error: true" do
      it "converts to tool role message" do
        tool_use = Dispatch::Adapter::ToolUseBlock.new(
          id: "call_err", name: "risky_op", arguments: {}
        )
        tool_result = Dispatch::Adapter::ToolResultBlock.new(
          tool_use_id: "call_err", content: "Something went wrong", is_error: true
        )

        messages = [
          Dispatch::Adapter::Message.new(role: "user", content: "do it"),
          Dispatch::Adapter::Message.new(role: "assistant", content: [tool_use]),
          Dispatch::Adapter::Message.new(role: "user", content: [tool_result])
        ]

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 msgs = body["messages"]
                 tool_msg = msgs.find { |m| m["role"] == "tool" }
                 tool_msg && tool_msg["content"] == "Something went wrong" && tool_msg["tool_call_id"] == "call_err"
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "I see the error" },
                                                  "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 10, "completion_tokens" => 3 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        adapter.chat(messages)
        expect(stub).to have_been_requested
      end
    end

    context "with finish_reason 'length'" do
      it "maps to :max_tokens stop_reason" do
        stub_request(:post, "https://api.githubcopilot.com/chat/completions")
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{
                                    "message" => { "content" => "truncated output..." },
                                    "finish_reason" => "length"
                                  }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 100 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Write a long essay")]
        response = adapter.chat(messages)

        expect(response.stop_reason).to eq(:max_tokens)
        expect(response.content).to eq("truncated output...")
      end
    end

    context "with assistant message containing text + tool_use blocks" do
      it "includes both content and tool_calls in wire format" do
        text = Dispatch::Adapter::TextBlock.new(text: "Checking...")
        tool_use = Dispatch::Adapter::ToolUseBlock.new(
          id: "call_mixed", name: "lookup", arguments: { "id" => 42 }
        )

        messages = [
          Dispatch::Adapter::Message.new(role: "user", content: "lookup 42"),
          Dispatch::Adapter::Message.new(role: "assistant", content: [text, tool_use])
        ]

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 msgs = body["messages"]
                 assistant = msgs.find { |m| m["role"] == "assistant" }
                 assistant &&
                   assistant["content"] == "Checking..." &&
                   assistant["tool_calls"].is_a?(Array) &&
                   assistant["tool_calls"][0]["id"] == "call_mixed"
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 10, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        adapter.chat(messages)
        expect(stub).to have_been_requested
      end
    end

    context "with consecutive same-role messages" do
      it "merges them before sending" do
        messages = [
          Dispatch::Adapter::Message.new(role: "user", content: "First"),
          Dispatch::Adapter::Message.new(role: "user", content: "Second")
        ]

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 msgs = body["messages"]
                 msgs.size == 1 && msgs[0]["role"] == "user" && msgs[0]["content"].include?("First") && msgs[0]["content"].include?("Second")
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        adapter.chat(messages)
        expect(stub).to have_been_requested
      end
    end

    context "with thinking: parameter" do
      it "sends reasoning_effort in the request body" do
        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 body["reasoning_effort"] == "high"
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "thought deeply" },
                                                  "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 3 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Think hard")]
        adapter.chat(messages, thinking: "high")

        expect(stub).to have_been_requested
      end

      it "uses constructor default when not specified per-call" do
        thinking_adapter = described_class.new(
          model: "o3-mini",
          github_token: github_token,
          max_tokens: 4096,
          thinking: "medium"
        )

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 body["reasoning_effort"] == "medium"
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        thinking_adapter.chat(messages)

        expect(stub).to have_been_requested
      end

      it "overrides constructor default with per-call thinking" do
        thinking_adapter = described_class.new(
          model: "o3-mini",
          github_token: github_token,
          max_tokens: 4096,
          thinking: "medium"
        )

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 body["reasoning_effort"] == "low"
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        thinking_adapter.chat(messages, thinking: "low")

        expect(stub).to have_been_requested
      end

      it "does not send reasoning_effort when thinking is nil" do
        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 !body.key?("reasoning_effort")
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        # Explicitly disable thinking for this single call. The default adapter
        # is constructed with thinking: "high", so we must pass thinking: nil
        # per-call to suppress reasoning_effort.
        adapter.chat(messages, thinking: nil)

        expect(stub).to have_been_requested
      end

      it "raises ArgumentError for invalid thinking level" do
        expect do
          described_class.new(model: "o3", github_token: github_token, thinking: "extreme")
        end.to raise_error(ArgumentError, /Invalid thinking level/)
      end

      it "raises ArgumentError for invalid per-call thinking level" do
        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        expect do
          adapter.chat(messages, thinking: "extreme")
        end.to raise_error(ArgumentError, /Invalid thinking level/)
      end

      it "allows disabling constructor default with nil per-call" do
        thinking_adapter = described_class.new(
          model: "o3-mini",
          github_token: github_token,
          max_tokens: 4096,
          thinking: "high"
        )

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 !body.key?("reasoning_effort")
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        thinking_adapter.chat(messages, thinking: nil)

        expect(stub).to have_been_requested
      end
    end
  end

  describe "X-Initiator header (premium request billing)" do
    # GitHub Copilot only bills requests sent with `X-Initiator: user` as
    # premium requests. Continuations inside a tool/agent loop must be sent
    # with `X-Initiator: agent` to avoid being billed.
    #
    # This adapter uses the "savings" strategy: the very first send for a
    # conversation (only system + user) is `user`; every subsequent send
    # (containing any assistant or tool message) is `agent`.

    let(:ok_response) do
      {
        status: 200,
        body: JSON.generate({
                              "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                              "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                            }),
        headers: { "Content-Type" => "application/json" }
      }
    end

    it "sends X-Initiator: user for the first request (user message only)" do
      stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
             .with(headers: { "X-Initiator" => "user" })
             .to_return(**ok_response)

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      adapter.chat(messages)

      expect(stub).to have_been_requested
    end

    it "sends X-Initiator: user when only a system + user message are present" do
      stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
             .with(headers: { "X-Initiator" => "user" })
             .to_return(**ok_response)

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      adapter.chat(messages, system: "You are a helpful assistant.")

      expect(stub).to have_been_requested
    end

    it "sends X-Initiator: agent when sending a tool result back to the model" do
      # The classic agent-loop continuation: prior assistant tool_use +
      # current tool_result. This MUST NOT be billed as premium.
      tool_use = Dispatch::Adapter::ToolUseBlock.new(
        id: "call_1", name: "get_weather", arguments: { "city" => "NYC" }
      )
      tool_result = Dispatch::Adapter::ToolResultBlock.new(
        tool_use_id: "call_1", content: "72F and sunny"
      )

      messages = [
        Dispatch::Adapter::Message.new(role: "user", content: "What's the weather?"),
        Dispatch::Adapter::Message.new(role: "assistant", content: [tool_use]),
        Dispatch::Adapter::Message.new(role: "user", content: [tool_result])
      ]

      stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
             .with(headers: { "X-Initiator" => "agent" })
             .to_return(**ok_response)

      adapter.chat(messages)

      expect(stub).to have_been_requested
    end

    it "sends X-Initiator: agent when an assistant text turn is present (multi-turn)" do
      # Savings semantics: any prior assistant turn in history flips this to
      # `agent`, even if the latest message is a fresh user prompt. This is
      # intentional and more aggressive than VS Code.
      messages = [
        Dispatch::Adapter::Message.new(role: "user", content: "Hi"),
        Dispatch::Adapter::Message.new(role: "assistant", content: "Hello!"),
        Dispatch::Adapter::Message.new(role: "user", content: "And again?")
      ]

      stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
             .with(headers: { "X-Initiator" => "agent" })
             .to_return(**ok_response)

      adapter.chat(messages)

      expect(stub).to have_been_requested
    end

    it "sends codecompanion-equivalent fingerprint headers alongside X-Initiator" do
      # We mimic codecompanion.nvim's wire profile exactly:
      #   Copilot-Integration-Id: vscode-chat
      #   Editor-Version: Neovim/<version>
      #   X-Initiator: user|agent
      # We DO NOT send Openai-Intent (codecompanion does not).
      stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
             .with(headers: {
                     "Copilot-Integration-Id" => "vscode-chat",
                     "Editor-Version" => "Neovim/0.10.4",
                     "X-Initiator" => "user"
                   })
             .to_return(**ok_response)

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      adapter.chat(messages)

      expect(stub).to have_been_requested
    end

    it "does not send the Openai-Intent header (codecompanion parity)" do
      captured_headers = nil
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .with do |req|
          captured_headers = req.headers
          true
        end
        .to_return(**ok_response)

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      adapter.chat(messages)

      expect(captured_headers.keys.map(&:downcase)).not_to include("openai-intent")
    end

    it "allows overriding Editor-Version via constructor" do
      custom_adapter = described_class.new(
        model: "gpt-4.1",
        github_token: github_token,
        max_tokens: 4096,
        min_request_interval: 0,
        editor_version: "Neovim/0.12.1"
      )

      stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
             .with(headers: { "Editor-Version" => "Neovim/0.12.1" })
             .to_return(**ok_response)

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      custom_adapter.chat(messages)

      expect(stub).to have_been_requested
    end

    context "in streaming mode" do
      let(:sse_ok) do
        {
          status: 200,
          body: [
            "data: #{JSON.generate({ "choices" => [{ "delta" => { "content" => "ok" }, "index" => 0 }] })}\n\n",
            "data: #{JSON.generate({ "choices" => [{ "delta" => {}, "index" => 0, "finish_reason" => "stop" }],
                                     "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 } })}\n\n",
            "data: [DONE]\n\n"
          ].join,
          headers: { "Content-Type" => "text/event-stream" }
        }
      end

      it "sends X-Initiator: user for the initial streaming request" do
        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with(headers: { "X-Initiator" => "user" })
               .to_return(**sse_ok)

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        adapter.chat(messages, stream: true) { |_d| }

        expect(stub).to have_been_requested
      end

      it "sends X-Initiator: agent for streaming tool-result continuations" do
        tool_use = Dispatch::Adapter::ToolUseBlock.new(
          id: "call_1", name: "search", arguments: { "q" => "x" }
        )
        tool_result = Dispatch::Adapter::ToolResultBlock.new(
          tool_use_id: "call_1", content: "result"
        )

        messages = [
          Dispatch::Adapter::Message.new(role: "user", content: "search x"),
          Dispatch::Adapter::Message.new(role: "assistant", content: [tool_use]),
          Dispatch::Adapter::Message.new(role: "user", content: [tool_result])
        ]

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with(headers: { "X-Initiator" => "agent" })
               .to_return(**sse_ok)

        adapter.chat(messages, stream: true) { |_d| }

        expect(stub).to have_been_requested
      end
    end
  end

  describe "#chat with streaming" do
    it "yields StreamDelta objects and returns Response" do
      sse_body = [
        "data: #{JSON.generate({ "choices" => [{ "delta" => { "content" => "Hello" }, "index" => 0 }] })}\n\n",
        "data: #{JSON.generate({ "choices" => [{ "delta" => { "content" => " world" }, "index" => 0 }] })}\n\n",
        "data: #{JSON.generate({ "choices" => [{ "delta" => {}, "index" => 0, "finish_reason" => "stop" }],
                                 "usage" => { "prompt_tokens" => 5, "completion_tokens" => 2 } })}\n\n",
        "data: [DONE]\n\n"
      ].join

      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .with { |req| JSON.parse(req.body)["stream"] == true }
        .to_return(
          status: 200,
          body: sse_body,
          headers: { "Content-Type" => "text/event-stream" }
        )

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      deltas = []
      response = adapter.chat(messages, stream: true) { |delta| deltas << delta }

      expect(deltas.size).to eq(2)
      expect(deltas[0]).to be_a(Dispatch::Adapter::StreamDelta)
      expect(deltas[0].type).to eq(:text_delta)
      expect(deltas[0].text).to eq("Hello")
      expect(deltas[1].text).to eq(" world")

      expect(response).to be_a(Dispatch::Adapter::Response)
      expect(response.content).to eq("Hello world")
      expect(response.stop_reason).to eq(:end_turn)
    end

    it "yields tool_use_start and tool_use_delta for tool call streams" do
      sse_body = [
        "data: #{JSON.generate({ "choices" => [{
                                 "delta" => { "tool_calls" => [{ "index" => 0, "id" => "call_1", "type" => "function",
                                                                 "function" => { "name" => "search", "arguments" => "" } }] }, "index" => 0
                               }] })}\n\n",
        "data: #{JSON.generate({ "choices" => [{
                                 "delta" => { "tool_calls" => [{ "index" => 0,
                                                                 "function" => { "arguments" => "{\"q\":" } }] }, "index" => 0
                               }] })}\n\n",
        "data: #{JSON.generate({ "choices" => [{
                                 "delta" => { "tool_calls" => [{ "index" => 0,
                                                                 "function" => { "arguments" => "\"test\"}" } }] }, "index" => 0
                               }] })}\n\n",
        "data: #{JSON.generate({ "choices" => [{ "delta" => {}, "index" => 0,
                                                 "finish_reason" => "tool_calls" }] })}\n\n",
        "data: [DONE]\n\n"
      ].join

      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(
          status: 200,
          body: sse_body,
          headers: { "Content-Type" => "text/event-stream" }
        )

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "search")]
      deltas = []
      response = adapter.chat(messages, stream: true) { |delta| deltas << delta }

      starts = deltas.select { |d| d.type == :tool_use_start }
      arg_deltas = deltas.select { |d| d.type == :tool_use_delta }

      expect(starts.size).to eq(1)
      expect(starts.first.tool_call_id).to eq("call_1")
      expect(starts.first.tool_name).to eq("search")

      expect(arg_deltas.size).to eq(2)

      expect(response.stop_reason).to eq(:tool_use)
      expect(response.tool_calls.size).to eq(1)
      expect(response.tool_calls.first.name).to eq("search")
      expect(response.tool_calls.first.arguments).to eq({ "q" => "test" })
    end

    it "captures usage from streaming response" do
      sse_body = [
        "data: #{JSON.generate({ "choices" => [{ "delta" => { "content" => "hi" }, "index" => 0 }] })}\n\n",
        "data: #{JSON.generate({ "choices" => [{ "delta" => {}, "index" => 0, "finish_reason" => "stop" }],
                                 "usage" => { "prompt_tokens" => 42, "completion_tokens" => 7 } })}\n\n",
        "data: [DONE]\n\n"
      ].join

      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(
          status: 200,
          body: sse_body,
          headers: { "Content-Type" => "text/event-stream" }
        )

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      response = adapter.chat(messages, stream: true) { |_delta| nil }

      expect(response.usage.input_tokens).to eq(42)
      expect(response.usage.output_tokens).to eq(7)
    end

    it "handles multiple parallel tool calls in a stream" do
      sse_body = [
        "data: #{JSON.generate({ "choices" => [{
                                 "delta" => { "tool_calls" => [{ "index" => 0, "id" => "call_a", "type" => "function",
                                                                 "function" => { "name" => "tool_a", "arguments" => "" } }] }, "index" => 0
                               }] })}\n\n",
        "data: #{JSON.generate({ "choices" => [{
                                 "delta" => { "tool_calls" => [{ "index" => 1, "id" => "call_b", "type" => "function",
                                                                 "function" => { "name" => "tool_b", "arguments" => "" } }] }, "index" => 0
                               }] })}\n\n",
        "data: #{JSON.generate({ "choices" => [{
                                 "delta" => { "tool_calls" => [{ "index" => 0,
                                                                 "function" => { "arguments" => "{\"x\":1}" } }] }, "index" => 0
                               }] })}\n\n",
        "data: #{JSON.generate({ "choices" => [{
                                 "delta" => { "tool_calls" => [{ "index" => 1,
                                                                 "function" => { "arguments" => "{\"y\":2}" } }] }, "index" => 0
                               }] })}\n\n",
        "data: #{JSON.generate({ "choices" => [{ "delta" => {}, "index" => 0,
                                                 "finish_reason" => "tool_calls" }] })}\n\n",
        "data: [DONE]\n\n"
      ].join

      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 200, body: sse_body, headers: { "Content-Type" => "text/event-stream" })

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "do both")]
      deltas = []
      response = adapter.chat(messages, stream: true) { |d| deltas << d }

      starts = deltas.select { |d| d.type == :tool_use_start }
      expect(starts.size).to eq(2)
      expect(starts[0].tool_name).to eq("tool_a")
      expect(starts[1].tool_name).to eq("tool_b")

      expect(response.tool_calls.size).to eq(2)
      expect(response.tool_calls[0].name).to eq("tool_a")
      expect(response.tool_calls[0].arguments).to eq({ "x" => 1 })
      expect(response.tool_calls[1].name).to eq("tool_b")
      expect(response.tool_calls[1].arguments).to eq({ "y" => 2 })
    end
  end

  describe "authentication" do
    it "reuses cached Copilot token for subsequent requests" do
      token_stub = stub_request(:get, "https://api.github.com/copilot_internal/v2/token")
                   .to_return(
                     status: 200,
                     body: JSON.generate({ "token" => copilot_token, "expires_at" => (Time.now.to_i + 3600) }),
                     headers: { "Content-Type" => "application/json" }
                   )

      chat_stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
                  .to_return(
                    status: 200,
                    body: JSON.generate({
                                          "choices" => [{ "message" => { "content" => "ok" },
                                                          "finish_reason" => "stop" }],
                                          "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                        }),
                    headers: { "Content-Type" => "application/json" }
                  )

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      adapter.chat(messages)
      adapter.chat(messages)

      expect(token_stub).to have_been_requested.once
      expect(chat_stub).to have_been_requested.twice
    end

    it "raises AuthenticationError when Copilot token exchange fails" do
      # Override the before block stub
      WebMock.reset!
      stub_request(:get, "https://api.github.com/copilot_internal/v2/token")
        .to_return(
          status: 401,
          body: JSON.generate({ "message" => "Bad credentials" }),
          headers: { "Content-Type" => "application/json" }
        )

      fresh_adapter = described_class.new(model: "gpt-4.1", github_token: "bad_token", max_tokens: 4096)
      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]

      expect { fresh_adapter.chat(messages) }.to raise_error(Dispatch::Adapter::AuthenticationError)
    end
  end

  describe "#list_models" do
    it "returns an array of ModelInfo structs with billing data" do
      stub_request(:get, "https://api.githubcopilot.com/models")
        .to_return(
          status: 200,
          body: JSON.generate({
                                "data" => [
                                  {
                                    "id" => "gpt-4.1",
                                    "name" => "GPT 4.1",
                                    "vendor" => "copilot",
                                    "model_picker_enabled" => true,
                                    "capabilities" => {
                                      "type" => "chat",
                                      "supports" => { "streaming" => true, "tool_calls" => true, "vision" => false },
                                      "limits" => { "max_context_window_tokens" => 1_047_576 }
                                    },
                                    "billing" => { "is_premium" => true, "multiplier" => 1.0 }
                                  },
                                  {
                                    "id" => "gpt-4o",
                                    "name" => "GPT 4o",
                                    "vendor" => "copilot",
                                    "model_picker_enabled" => true,
                                    "capabilities" => {
                                      "type" => "chat",
                                      "supports" => { "streaming" => true, "tool_calls" => true, "vision" => true },
                                      "limits" => { "max_context_window_tokens" => 128_000 }
                                    },
                                    "billing" => { "is_premium" => false, "multiplier" => 0.33 }
                                  }
                                ]
                              }),
          headers: { "Content-Type" => "application/json" }
        )

      models = adapter.list_models

      expect(models.size).to eq(2)
      expect(models.first).to be_a(Dispatch::Adapter::ModelInfo)
      expect(models.first.id).to eq("gpt-4.1")
      expect(models.first.name).to eq("GPT 4.1")
      expect(models.first.max_context_tokens).to eq(1_047_576)
      expect(models.first.supports_tool_use).to be(true)
      expect(models.first.supports_streaming).to be(true)
      expect(models.first.supports_vision).to be(false)
      expect(models.first.premium_request_multiplier).to eq(1.0)

      expect(models.last.id).to eq("gpt-4o")
      expect(models.last.premium_request_multiplier).to eq(0.33)
      expect(models.last.supports_vision).to be(true)
    end

    it "sends X-Github-Api-Version header" do
      stub = stub_request(:get, "https://api.githubcopilot.com/models")
             .with(headers: { "X-Github-Api-Version" => "2025-10-01" })
             .to_return(
               status: 200,
               body: JSON.generate({ "data" => [] }),
               headers: { "Content-Type" => "application/json" }
             )

      adapter.list_models

      expect(stub).to have_been_requested
    end

    it "filters out models with model_picker_enabled false" do
      stub_request(:get, "https://api.githubcopilot.com/models")
        .to_return(
          status: 200,
          body: JSON.generate({
                                "data" => [
                                  {
                                    "id" => "visible-model",
                                    "name" => "Visible Model",
                                    "model_picker_enabled" => true,
                                    "capabilities" => { "type" => "chat", "supports" => {} },
                                    "billing" => { "multiplier" => 1.0 }
                                  },
                                  {
                                    "id" => "hidden-model",
                                    "name" => "Hidden Model",
                                    "model_picker_enabled" => false,
                                    "capabilities" => { "type" => "chat", "supports" => {} },
                                    "billing" => { "multiplier" => 1.0 }
                                  }
                                ]
                              }),
          headers: { "Content-Type" => "application/json" }
        )

      models = adapter.list_models

      expect(models.size).to eq(1)
      expect(models.first.id).to eq("visible-model")
    end

    it "filters out non-chat models" do
      stub_request(:get, "https://api.githubcopilot.com/models")
        .to_return(
          status: 200,
          body: JSON.generate({
                                "data" => [
                                  {
                                    "id" => "chat-model",
                                    "name" => "Chat Model",
                                    "model_picker_enabled" => true,
                                    "capabilities" => { "type" => "chat", "supports" => {} },
                                    "billing" => { "multiplier" => 1.0 }
                                  },
                                  {
                                    "id" => "completion-model",
                                    "name" => "Completion Model",
                                    "model_picker_enabled" => true,
                                    "capabilities" => { "type" => "completion", "supports" => {} },
                                    "billing" => { "multiplier" => 0.5 }
                                  }
                                ]
                              }),
          headers: { "Content-Type" => "application/json" }
        )

      models = adapter.list_models

      expect(models.size).to eq(1)
      expect(models.first.id).to eq("chat-model")
    end

    it "includes models with array type containing chat" do
      stub_request(:get, "https://api.githubcopilot.com/models")
        .to_return(
          status: 200,
          body: JSON.generate({
                                "data" => [
                                  {
                                    "id" => "multi-type-model",
                                    "name" => "Multi Type",
                                    "model_picker_enabled" => true,
                                    "capabilities" => { "type" => %w[chat completion], "supports" => {} },
                                    "billing" => { "multiplier" => 3.0 }
                                  }
                                ]
                              }),
          headers: { "Content-Type" => "application/json" }
        )

      models = adapter.list_models

      expect(models.size).to eq(1)
      expect(models.first.id).to eq("multi-type-model")
      expect(models.first.premium_request_multiplier).to eq(3.0)
    end

    it "falls back to MODEL_CONTEXT_WINDOWS when limits not in response" do
      stub_request(:get, "https://api.githubcopilot.com/models")
        .to_return(
          status: 200,
          body: JSON.generate({
                                "data" => [
                                  {
                                    "id" => "gpt-4o",
                                    "name" => "GPT 4o",
                                    "model_picker_enabled" => true,
                                    "capabilities" => { "type" => "chat", "supports" => {} },
                                    "billing" => { "multiplier" => 0.33 }
                                  }
                                ]
                              }),
          headers: { "Content-Type" => "application/json" }
        )

      models = adapter.list_models

      expect(models.first.max_context_tokens).to eq(128_000)
    end

    it "returns nil premium_request_multiplier when billing is absent" do
      stub_request(:get, "https://api.githubcopilot.com/models")
        .to_return(
          status: 200,
          body: JSON.generate({
                                "data" => [
                                  {
                                    "id" => "no-billing-model",
                                    "name" => "No Billing",
                                    "model_picker_enabled" => true,
                                    "capabilities" => { "type" => "chat", "supports" => {} }
                                  }
                                ]
                              }),
          headers: { "Content-Type" => "application/json" }
        )

      models = adapter.list_models

      expect(models.first.premium_request_multiplier).to be_nil
    end

    it "returns premium models with high multipliers" do
      stub_request(:get, "https://api.githubcopilot.com/models")
        .to_return(
          status: 200,
          body: JSON.generate({
                                "data" => [
                                  {
                                    "id" => "o3",
                                    "name" => "o3",
                                    "model_picker_enabled" => true,
                                    "capabilities" => {
                                      "type" => "chat",
                                      "supports" => { "streaming" => true, "tool_calls" => true }
                                    },
                                    "billing" => { "is_premium" => true, "multiplier" => 30.0 }
                                  },
                                  {
                                    "id" => "gpt-4.1-nano",
                                    "name" => "GPT 4.1 Nano",
                                    "model_picker_enabled" => true,
                                    "capabilities" => {
                                      "type" => "chat",
                                      "supports" => { "streaming" => true, "tool_calls" => true }
                                    },
                                    "billing" => { "is_premium" => false, "multiplier" => 0.33 }
                                  }
                                ]
                              }),
          headers: { "Content-Type" => "application/json" }
        )

      models = adapter.list_models

      expect(models.size).to eq(2)
      o3 = models.find { |m| m.id == "o3" }
      nano = models.find { |m| m.id == "gpt-4.1-nano" }

      expect(o3.premium_request_multiplier).to eq(30.0)
      expect(nano.premium_request_multiplier).to eq(0.33)
    end
  end

  describe "error mapping" do
    it "maps 401 to AuthenticationError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 401, body: JSON.generate({ "error" => { "message" => "Unauthorized" } }))

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::AuthenticationError) { |e|
        expect(e.status_code).to eq(401)
        expect(e.provider).to eq("GitHub Copilot")
      }
    end

    it "maps 403 to AuthenticationError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 403, body: JSON.generate({ "error" => { "message" => "Forbidden" } }))

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::AuthenticationError)
    end

    it "maps 429 to RateLimitError with retry_after" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(
          status: 429,
          body: JSON.generate({ "error" => { "message" => "Too many requests" } }),
          headers: { "Retry-After" => "30" }
        )

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::RateLimitError) { |e|
        expect(e.status_code).to eq(429)
        expect(e.retry_after).to eq(30)
      }
    end

    it "maps 400 to RequestError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 400, body: JSON.generate({ "error" => { "message" => "Bad request" } }))

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::RequestError) { |e|
        expect(e.status_code).to eq(400)
      }
    end

    it "maps 422 to RequestError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 422, body: JSON.generate({ "error" => { "message" => "Unprocessable" } }))

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::RequestError)
    end

    it "maps 500 to ServerError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 500, body: JSON.generate({ "error" => { "message" => "Internal error" } }))

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::ServerError) { |e|
        expect(e.status_code).to eq(500)
      }
    end

    it "maps 502 to ServerError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 502, body: "Bad Gateway")

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::ServerError)
    end

    it "maps 503 to ServerError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 503, body: "Service Unavailable")

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::ServerError)
    end

    it "maps connection errors to ConnectionError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_raise(Errno::ECONNREFUSED.new("Connection refused"))

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::ConnectionError) { |e|
        expect(e.provider).to eq("GitHub Copilot")
      }
    end

    it "maps timeout errors to ConnectionError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_raise(Net::OpenTimeout.new("execution expired"))

      messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::ConnectionError)
    end
  end

  describe "#chat via /v1/responses (reasoning models)" do
    let(:responses_adapter) do
      described_class.new(
        model: "gpt-5.4",
        github_token: github_token,
        max_tokens: 4096,
        thinking: "medium",
        min_request_interval: 0
      )
    end

    # Helper: build a well-formed /v1/responses non-streaming response body.
    def responses_body(text: nil, tool_calls: [], model: "gpt-5.4",
                       input_tokens: 10, output_tokens: 5)
      output = []
      unless text.nil?
        output << {
          "type" => "message",
          "id" => "msg_001",
          "role" => "assistant",
          "content" => [{ "type" => "output_text", "text" => text }]
        }
      end
      tool_calls.each do |tc|
        output << {
          "type" => "function_call",
          "id" => tc[:id],
          "call_id" => tc[:id],
          "name" => tc[:name],
          "arguments" => JSON.generate(tc[:arguments])
        }
      end
      {
        "id" => "resp_001",
        "object" => "response",
        "model" => model,
        "output" => output,
        "usage" => {
          "input_tokens" => input_tokens,
          "output_tokens" => output_tokens,
          "total_tokens" => input_tokens + output_tokens
        }
      }
    end

    context "with a text-only response" do
      before do
        stub_request(:post, "https://api.githubcopilot.com/responses")
          .to_return(
            status: 200,
            body: JSON.generate(responses_body(text: "Hello from GPT-5!")),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns a Response with content" do
        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        response = responses_adapter.chat(messages)

        expect(response).to be_a(Dispatch::Adapter::Response)
        expect(response.content).to eq("Hello from GPT-5!")
        expect(response.tool_calls).to be_empty
        expect(response.model).to eq("gpt-5.4")
        expect(response.stop_reason).to eq(:end_turn)
        expect(response.usage.input_tokens).to eq(10)
        expect(response.usage.output_tokens).to eq(5)
      end
    end

    context "with a tool call response" do
      before do
        stub_request(:post, "https://api.githubcopilot.com/responses")
          .to_return(
            status: 200,
            body: JSON.generate(responses_body(
                                  tool_calls: [{ id: "call_abc", name: "get_weather",
                                                 arguments: { "city" => "New York" } }]
                                )),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns a Response with tool_calls as ToolUseBlock array" do
        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Weather?")]
        response = responses_adapter.chat(messages)

        expect(response.content).to be_nil
        expect(response.stop_reason).to eq(:tool_use)
        expect(response.tool_calls.size).to eq(1)

        tc = response.tool_calls.first
        expect(tc).to be_a(Dispatch::Adapter::ToolUseBlock)
        expect(tc.id).to eq("call_abc")
        expect(tc.name).to eq("get_weather")
        expect(tc.arguments).to eq({ "city" => "New York" })
      end
    end

    context "with mixed text + tool call response" do
      before do
        stub_request(:post, "https://api.githubcopilot.com/responses")
          .to_return(
            status: 200,
            body: JSON.generate(responses_body(
                                  text: "Let me check.",
                                  tool_calls: [{ id: "call_def", name: "search", arguments: { "q" => "test" } }]
                                )),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns both content and tool_calls" do
        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Search")]
        response = responses_adapter.chat(messages)

        expect(response.content).to eq("Let me check.")
        expect(response.tool_calls.size).to eq(1)
        expect(response.stop_reason).to eq(:tool_use)
      end
    end

    context "request body shape" do
      it "sends `input` not `messages`" do
        stub = stub_request(:post, "https://api.githubcopilot.com/responses")
               .with do |req|
                 body = JSON.parse(req.body)
                 body.key?("input") && !body.key?("messages")
               end
               .to_return(
                 status: 200,
                 body: JSON.generate(responses_body(text: "ok")),
                 headers: { "Content-Type" => "application/json" }
               )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        responses_adapter.chat(messages)

        expect(stub).to have_been_requested
      end

      it "sends `max_output_tokens` not `max_tokens`" do
        stub = stub_request(:post, "https://api.githubcopilot.com/responses")
               .with do |req|
                 body = JSON.parse(req.body)
                 body["max_output_tokens"] == 4096 &&
                   !body.key?("max_tokens") &&
                   !body.key?("max_completion_tokens")
               end
               .to_return(
                 status: 200,
                 body: JSON.generate(responses_body(text: "ok")),
                 headers: { "Content-Type" => "application/json" }
               )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        responses_adapter.chat(messages)

        expect(stub).to have_been_requested
      end

      it "sends `reasoning: {effort:}` not `reasoning_effort`" do
        stub = stub_request(:post, "https://api.githubcopilot.com/responses")
               .with do |req|
                 body = JSON.parse(req.body)
                 body["reasoning"] == { "effort" => "medium" } && !body.key?("reasoning_effort")
               end
               .to_return(
                 status: 200,
                 body: JSON.generate(responses_body(text: "ok")),
                 headers: { "Content-Type" => "application/json" }
               )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        responses_adapter.chat(messages)

        expect(stub).to have_been_requested
      end

      it "sends tools without the `function` wrapper" do
        tool = Dispatch::Adapter::ToolDefinition.new(
          name: "get_weather",
          description: "Get weather",
          parameters: { "type" => "object", "properties" => { "city" => { "type" => "string" } } }
        )

        stub = stub_request(:post, "https://api.githubcopilot.com/responses")
               .with do |req|
                 body = JSON.parse(req.body)
                 t = body["tools"]&.first
                 t && t["type"] == "function" &&
                   t["name"] == "get_weather" &&
                   t["description"] == "Get weather" &&
                   !t.key?("function")
               end
               .to_return(
                 status: 200,
                 body: JSON.generate(responses_body(text: "ok")),
                 headers: { "Content-Type" => "application/json" }
               )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "weather?")]
        responses_adapter.chat(messages, tools: [tool])

        expect(stub).to have_been_requested
      end

      it "converts tool results to function_call_output items in input" do
        tool_use = Dispatch::Adapter::ToolUseBlock.new(
          id: "call_1", name: "search", arguments: { "q" => "ruby" }
        )
        tool_result = Dispatch::Adapter::ToolResultBlock.new(
          tool_use_id: "call_1", content: "some results"
        )

        messages = [
          Dispatch::Adapter::Message.new(role: "user", content: "search ruby"),
          Dispatch::Adapter::Message.new(role: "assistant", content: [tool_use]),
          Dispatch::Adapter::Message.new(role: "user", content: [tool_result])
        ]

        stub = stub_request(:post, "https://api.githubcopilot.com/responses")
               .with do |req|
                 body = JSON.parse(req.body)
                 input = body["input"]
                 fc = input.find { |i| i["type"] == "function_call" }
                 fco = input.find { |i| i["type"] == "function_call_output" }
                 fc && fc["call_id"] == "call_1" && fc["name"] == "search" &&
                   fco && fco["call_id"] == "call_1" && fco["output"] == "some results"
               end
               .to_return(
                 status: 200,
                 body: JSON.generate(responses_body(text: "done")),
                 headers: { "Content-Type" => "application/json" }
               )

        responses_adapter.chat(messages)

        expect(stub).to have_been_requested
      end
    end

    context "with system: parameter" do
      it "prepends system item at start of input array" do
        stub = stub_request(:post, "https://api.githubcopilot.com/responses")
               .with do |req|
                 body = JSON.parse(req.body)
                 body["input"].first == { "role" => "system", "content" => "Be concise." }
               end
               .to_return(
                 status: 200,
                 body: JSON.generate(responses_body(text: "ok")),
                 headers: { "Content-Type" => "application/json" }
               )

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        responses_adapter.chat(messages, system: "Be concise.")

        expect(stub).to have_been_requested
      end
    end

    context "X-Initiator header" do
      let(:ok_resp) do
        {
          status: 200,
          body: JSON.generate(responses_body(text: "ok")),
          headers: { "Content-Type" => "application/json" }
        }
      end

      it "sends X-Initiator: user for a fresh user message" do
        stub = stub_request(:post, "https://api.githubcopilot.com/responses")
               .with(headers: { "X-Initiator" => "user" })
               .to_return(**ok_resp)

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        responses_adapter.chat(messages)

        expect(stub).to have_been_requested
      end

      it "sends X-Initiator: agent when tool results are present" do
        tool_use = Dispatch::Adapter::ToolUseBlock.new(id: "c1", name: "fn", arguments: {})
        tool_result = Dispatch::Adapter::ToolResultBlock.new(tool_use_id: "c1", content: "res")

        messages = [
          Dispatch::Adapter::Message.new(role: "user", content: "go"),
          Dispatch::Adapter::Message.new(role: "assistant", content: [tool_use]),
          Dispatch::Adapter::Message.new(role: "user", content: [tool_result])
        ]

        stub = stub_request(:post, "https://api.githubcopilot.com/responses")
               .with(headers: { "X-Initiator" => "agent" })
               .to_return(**ok_resp)

        responses_adapter.chat(messages)

        expect(stub).to have_been_requested
      end
    end

    context "error mapping" do
      it "maps 400 to RequestError (the error gpt-5.4 would give on wrong endpoint)" do
        stub_request(:post, "https://api.githubcopilot.com/responses")
          .to_return(status: 400, body: JSON.generate({ "error" => { "message" => "bad request" } }))

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        expect { responses_adapter.chat(messages) }.to raise_error(Dispatch::Adapter::RequestError)
      end
    end

    context "streaming" do
      def sse_events(*events)
        all = events.map { |e| "data: #{JSON.generate(e)}\n\n" }
        all << "data: [DONE]\n\n"
        all.join
      end

      it "yields text StreamDeltas and returns Response" do
        body = sse_events(
          { "type" => "response.output_item.added", "output_index" => 0,
            "item" => { "type" => "message", "id" => "msg_001", "role" => "assistant", "content" => [] } },
          { "type" => "response.output_text.delta", "item_id" => "msg_001",
            "output_index" => 0, "content_index" => 0, "delta" => "Hello" },
          { "type" => "response.output_text.delta", "item_id" => "msg_001",
            "output_index" => 0, "content_index" => 0, "delta" => " world" },
          { "type" => "response.completed",
            "response" => { "model" => "gpt-5.4",
                            "usage" => { "input_tokens" => 10, "output_tokens" => 2, "total_tokens" => 12 } } }
        )

        stub_request(:post, "https://api.githubcopilot.com/responses")
          .with { |req| JSON.parse(req.body)["stream"] == true }
          .to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        deltas = []
        response = responses_adapter.chat(messages, stream: true) { |d| deltas << d }

        text_deltas = deltas.select { |d| d.type == :text_delta }
        expect(text_deltas.size).to eq(2)
        expect(text_deltas[0].text).to eq("Hello")
        expect(text_deltas[1].text).to eq(" world")

        expect(response).to be_a(Dispatch::Adapter::Response)
        expect(response.content).to eq("Hello world")
        expect(response.stop_reason).to eq(:end_turn)
        expect(response.model).to eq("gpt-5.4")
        expect(response.usage.input_tokens).to eq(10)
        expect(response.usage.output_tokens).to eq(2)
      end

      it "yields tool_use_start and tool_use_delta for function call streams" do
        body = sse_events(
          { "type" => "response.output_item.added", "output_index" => 0,
            "item" => { "type" => "function_call", "id" => "fc_001", "call_id" => "call_001",
                        "name" => "get_weather" } },
          { "type" => "response.function_call_arguments.delta",
            "item_id" => "fc_001", "output_index" => 0, "delta" => "{\"city\":" },
          { "type" => "response.function_call_arguments.delta",
            "item_id" => "fc_001", "output_index" => 0, "delta" => "\"NYC\"}" },
          { "type" => "response.completed",
            "response" => { "model" => "gpt-5.4",
                            "usage" => { "input_tokens" => 15, "output_tokens" => 8, "total_tokens" => 23 } } }
        )

        stub_request(:post, "https://api.githubcopilot.com/responses")
          .to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "weather?")]
        deltas = []
        response = responses_adapter.chat(messages, stream: true) { |d| deltas << d }

        starts = deltas.select { |d| d.type == :tool_use_start }
        arg_deltas = deltas.select { |d| d.type == :tool_use_delta }

        expect(starts.size).to eq(1)
        expect(starts.first.tool_call_id).to eq("call_001")
        expect(starts.first.tool_name).to eq("get_weather")

        expect(arg_deltas.size).to eq(2)
        expect(arg_deltas[0].argument_delta).to eq("{\"city\":")
        expect(arg_deltas[1].argument_delta).to eq("\"NYC\"}")

        expect(response.stop_reason).to eq(:tool_use)
        expect(response.tool_calls.size).to eq(1)
        expect(response.tool_calls.first.name).to eq("get_weather")
        expect(response.tool_calls.first.arguments).to eq({ "city" => "NYC" })
        expect(response.usage.input_tokens).to eq(15)
        expect(response.usage.output_tokens).to eq(8)
      end

      it "sends stream: true in the request body" do
        body = sse_events(
          { "type" => "response.completed",
            "response" => { "model" => "gpt-5.4", "usage" => { "input_tokens" => 5, "output_tokens" => 1 } } }
        )

        stub = stub_request(:post, "https://api.githubcopilot.com/responses")
               .with { |req| JSON.parse(req.body)["stream"] == true }
               .to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "Hi")]
        responses_adapter.chat(messages, stream: true) { |_d| }

        expect(stub).to have_been_requested
      end

      it "returns nil content when there are no text deltas" do
        body = sse_events(
          { "type" => "response.output_item.added", "output_index" => 0,
            "item" => { "type" => "function_call", "id" => "fc_001", "call_id" => "call_001", "name" => "fn" } },
          { "type" => "response.function_call_arguments.delta",
            "item_id" => "fc_001", "output_index" => 0, "delta" => "{}" },
          { "type" => "response.completed",
            "response" => { "model" => "gpt-5.4", "usage" => { "input_tokens" => 5, "output_tokens" => 1 } } }
        )

        stub_request(:post, "https://api.githubcopilot.com/responses")
          .to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })

        messages = [Dispatch::Adapter::Message.new(role: "user", content: "do it")]
        response = responses_adapter.chat(messages, stream: true) { |_d| }

        expect(response.content).to be_nil
        expect(response.tool_calls.size).to eq(1)
      end
    end
  end
end
