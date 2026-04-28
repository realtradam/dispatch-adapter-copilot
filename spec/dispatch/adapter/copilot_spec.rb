# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Dispatch::Adapter::Copilot do
  let(:copilot_token) { "cop_test_token_abc" }
  let(:github_token) { "gho_test_github_token" }

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
expect(Dispatch::Adapter::Copilot::VERSION).to eq("0.3.0")
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
                                  "choices" => [ {
                                    "index" => 0,
                                    "message" => { "role" => "assistant", "content" => "Hello there!" },
                                    "finish_reason" => "stop"
                                  } ],
                                  "usage" => { "prompt_tokens" => 10, "completion_tokens" => 5 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns a Response with content" do
        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
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
                                  "choices" => [ {
                                    "index" => 0,
                                    "message" => {
                                      "role" => "assistant",
                                      "content" => nil,
                                      "tool_calls" => [ {
                                        "id" => "call_abc",
                                        "type" => "function",
                                        "function" => {
                                          "name" => "get_weather",
                                          "arguments" => '{"city":"New York"}'
                                        }
                                      } ]
                                    },
                                    "finish_reason" => "tool_calls"
                                  } ],
                                  "usage" => { "prompt_tokens" => 15, "completion_tokens" => 10 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns a Response with tool_calls as ToolUseBlock array" do
        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "What's the weather?") ]
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
                                  "choices" => [ {
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
                                  } ],
                                  "usage" => { "prompt_tokens" => 20, "completion_tokens" => 15 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns multiple ToolUseBlocks" do
        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "weather and time?") ]
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
                                  "choices" => [ {
                                    "index" => 0,
                                    "message" => {
                                      "role" => "assistant",
                                      "content" => "Let me check that for you.",
                                      "tool_calls" => [ {
                                        "id" => "call_def",
                                        "type" => "function",
                                        "function" => {
                                          "name" => "search",
                                          "arguments" => '{"query":"Ruby gems"}'
                                        }
                                      } ]
                                    },
                                    "finish_reason" => "tool_calls"
                                  } ],
                                  "usage" => { "prompt_tokens" => 20, "completion_tokens" => 15 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns both content and tool_calls" do
        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Search for Ruby gems") ]
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
                                  "choices" => [ { "message" => { "content" => "OK" }, "finish_reason" => "stop" } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
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
                                  "choices" => [ { "message" => { "content" => "short" }, "finish_reason" => "stop" } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
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
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
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
                 body["tools"] == [ {
                   "type" => "function",
                   "function" => {
                     "name" => "get_weather",
                     "description" => "Get weather for a city",
                     "parameters" => { "type" => "object", "properties" => { "city" => { "type" => "string" } } }
                   }
                 } ]
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "weather?") ]
        adapter.chat(messages, tools: [ tool ])

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
                 body["tools"] == [ {
                   "type" => "function",
                   "function" => {
                     "name" => "get_weather",
                     "description" => "Get weather for a city",
                     "parameters" => { "type" => "object", "properties" => { "city" => { "type" => "string" } } }
                   }
                 } ]
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "weather?") ]
        adapter.chat(messages, tools: [ tool_hash ])

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
                 body["tools"] == [ {
                   "type" => "function",
                   "function" => {
                     "name" => "get_weather",
                     "description" => "Get weather for a city",
                     "parameters" => { "type" => "object", "properties" => { "city" => { "type" => "string" } } }
                   }
                 } ]
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "weather?") ]
        adapter.chat(messages, tools: [ tool_hash ])

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
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "both?") ]
        adapter.chat(messages, tools: [ tool_struct, tool_hash ])

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
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
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
          Dispatch::Adapter::Message.new(role: "assistant", content: [ tool_use ]),
          Dispatch::Adapter::Message.new(role: "user", content: [ tool_result ])
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
                                  "choices" => [ { "message" => { "content" => "It's 72F and sunny in NYC!" },
                                                  "finish_reason" => "stop" } ],
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
        messages = [ Dispatch::Adapter::Message.new(role: "user", content: [ image ]) ]

        expect { adapter.chat(messages) }.to raise_error(NotImplementedError, /ImageBlock/)
      end
    end

    context "with TextBlock array in user message" do
      it "converts to string content" do
        text_blocks = [
          Dispatch::Adapter::TextBlock.new(text: "First paragraph."),
          Dispatch::Adapter::TextBlock.new(text: "Second paragraph.")
        ]
        messages = [ Dispatch::Adapter::Message.new(role: "user", content: text_blocks) ]

        stub = stub_request(:post, "https://api.githubcopilot.com/chat/completions")
               .with do |req|
                 body = JSON.parse(req.body)
                 msgs = body["messages"]
                 msgs[0]["content"] == "First paragraph.\nSecond paragraph."
               end
          .to_return(
            status: 200,
            body: JSON.generate({
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
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
          Dispatch::Adapter::Message.new(role: "assistant", content: [ tool_use ]),
          Dispatch::Adapter::Message.new(role: "user", content: [ tool_result ])
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
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
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
          Dispatch::Adapter::Message.new(role: "assistant", content: [ tool_use ]),
          Dispatch::Adapter::Message.new(role: "user", content: [ tool_result ])
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
                                  "choices" => [ { "message" => { "content" => "I see the error" },
                                                  "finish_reason" => "stop" } ],
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
                                  "choices" => [ {
                                    "message" => { "content" => "truncated output..." },
                                    "finish_reason" => "length"
                                  } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 100 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Write a long essay") ]
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
          Dispatch::Adapter::Message.new(role: "assistant", content: [ text, tool_use ])
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
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
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
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
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
                                  "choices" => [ { "message" => { "content" => "thought deeply" },
                                                  "finish_reason" => "stop" } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 3 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Think hard") ]
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
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
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
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
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
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
        adapter.chat(messages)

        expect(stub).to have_been_requested
      end

      it "raises ArgumentError for invalid thinking level" do
        expect do
          described_class.new(model: "o3", github_token: github_token, thinking: "extreme")
        end.to raise_error(ArgumentError, /Invalid thinking level/)
      end

      it "raises ArgumentError for invalid per-call thinking level" do
        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
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
                                  "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
                                  "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                }),
            headers: { "Content-Type" => "application/json" }
          )

        messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
        thinking_adapter.chat(messages, thinking: nil)

        expect(stub).to have_been_requested
      end
    end
  end

  describe "#chat with streaming" do
    it "yields StreamDelta objects and returns Response" do
      sse_body = [
        "data: #{JSON.generate({ "choices" => [ { "delta" => { "content" => "Hello" }, "index" => 0 } ] })}\n\n",
        "data: #{JSON.generate({ "choices" => [ { "delta" => { "content" => " world" }, "index" => 0 } ] })}\n\n",
        "data: #{JSON.generate({ "choices" => [ { "delta" => {}, "index" => 0, "finish_reason" => "stop" } ],
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

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
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
        "data: #{JSON.generate({ "choices" => [ {
                                 "delta" => { "tool_calls" => [ { "index" => 0, "id" => "call_1", "type" => "function",
                                                                 "function" => { "name" => "search", "arguments" => "" } } ] }, "index" => 0
                               } ] })}\n\n",
        "data: #{JSON.generate({ "choices" => [ {
                                 "delta" => { "tool_calls" => [ { "index" => 0,
                                                                 "function" => { "arguments" => "{\"q\":" } } ] }, "index" => 0
                               } ] })}\n\n",
        "data: #{JSON.generate({ "choices" => [ {
                                 "delta" => { "tool_calls" => [ { "index" => 0,
                                                                 "function" => { "arguments" => "\"test\"}" } } ] }, "index" => 0
                               } ] })}\n\n",
        "data: #{JSON.generate({ "choices" => [ { "delta" => {}, "index" => 0,
                                                 "finish_reason" => "tool_calls" } ] })}\n\n",
        "data: [DONE]\n\n"
      ].join

      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(
          status: 200,
          body: sse_body,
          headers: { "Content-Type" => "text/event-stream" }
        )

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "search") ]
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
        "data: #{JSON.generate({ "choices" => [ { "delta" => { "content" => "hi" }, "index" => 0 } ] })}\n\n",
        "data: #{JSON.generate({ "choices" => [ { "delta" => {}, "index" => 0, "finish_reason" => "stop" } ],
                                 "usage" => { "prompt_tokens" => 42, "completion_tokens" => 7 } })}\n\n",
        "data: [DONE]\n\n"
      ].join

      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(
          status: 200,
          body: sse_body,
          headers: { "Content-Type" => "text/event-stream" }
        )

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
      response = adapter.chat(messages, stream: true) { |_delta| nil }

      expect(response.usage.input_tokens).to eq(42)
      expect(response.usage.output_tokens).to eq(7)
    end

    it "handles multiple parallel tool calls in a stream" do
      sse_body = [
        "data: #{JSON.generate({ "choices" => [ {
                                 "delta" => { "tool_calls" => [ { "index" => 0, "id" => "call_a", "type" => "function",
                                                                 "function" => { "name" => "tool_a", "arguments" => "" } } ] }, "index" => 0
                               } ] })}\n\n",
        "data: #{JSON.generate({ "choices" => [ {
                                 "delta" => { "tool_calls" => [ { "index" => 1, "id" => "call_b", "type" => "function",
                                                                 "function" => { "name" => "tool_b", "arguments" => "" } } ] }, "index" => 0
                               } ] })}\n\n",
        "data: #{JSON.generate({ "choices" => [ {
                                 "delta" => { "tool_calls" => [ { "index" => 0,
                                                                 "function" => { "arguments" => "{\"x\":1}" } } ] }, "index" => 0
                               } ] })}\n\n",
        "data: #{JSON.generate({ "choices" => [ {
                                 "delta" => { "tool_calls" => [ { "index" => 1,
                                                                 "function" => { "arguments" => "{\"y\":2}" } } ] }, "index" => 0
                               } ] })}\n\n",
        "data: #{JSON.generate({ "choices" => [ { "delta" => {}, "index" => 0,
                                                 "finish_reason" => "tool_calls" } ] })}\n\n",
        "data: [DONE]\n\n"
      ].join

      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 200, body: sse_body, headers: { "Content-Type" => "text/event-stream" })

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "do both") ]
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
                                          "choices" => [ { "message" => { "content" => "ok" },
                                                          "finish_reason" => "stop" } ],
                                          "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                                        }),
                    headers: { "Content-Type" => "application/json" }
                  )

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
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
      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]

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

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::AuthenticationError) { |e|
        expect(e.status_code).to eq(401)
        expect(e.provider).to eq("GitHub Copilot")
      }
    end

    it "maps 403 to AuthenticationError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 403, body: JSON.generate({ "error" => { "message" => "Forbidden" } }))

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::AuthenticationError)
    end

    it "maps 429 to RateLimitError with retry_after" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(
          status: 429,
          body: JSON.generate({ "error" => { "message" => "Too many requests" } }),
          headers: { "Retry-After" => "30" }
        )

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::RateLimitError) { |e|
        expect(e.status_code).to eq(429)
        expect(e.retry_after).to eq(30)
      }
    end

    it "maps 400 to RequestError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 400, body: JSON.generate({ "error" => { "message" => "Bad request" } }))

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::RequestError) { |e|
        expect(e.status_code).to eq(400)
      }
    end

    it "maps 422 to RequestError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 422, body: JSON.generate({ "error" => { "message" => "Unprocessable" } }))

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::RequestError)
    end

    it "maps 500 to ServerError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 500, body: JSON.generate({ "error" => { "message" => "Internal error" } }))

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::ServerError) { |e|
        expect(e.status_code).to eq(500)
      }
    end

    it "maps 502 to ServerError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 502, body: "Bad Gateway")

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::ServerError)
    end

    it "maps 503 to ServerError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 503, body: "Service Unavailable")

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::ServerError)
    end

    it "maps connection errors to ConnectionError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_raise(Errno::ECONNREFUSED.new("Connection refused"))

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::ConnectionError) { |e|
        expect(e.provider).to eq("GitHub Copilot")
      }
    end

    it "maps timeout errors to ConnectionError" do
      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_raise(Net::OpenTimeout.new("execution expired"))

      messages = [ Dispatch::Adapter::Message.new(role: "user", content: "Hi") ]
      expect { adapter.chat(messages) }.to raise_error(Dispatch::Adapter::ConnectionError)
    end
  end
end
