# frozen_string_literal: true

RSpec.describe Dispatch::Adapter do
  describe "Message" do
    it "creates with keyword args" do
      msg = Dispatch::Adapter::Message.new(role: "user", content: "Hello")
      expect(msg.role).to eq("user")
      expect(msg.content).to eq("Hello")
    end

    it "accepts array content" do
      blocks = [Dispatch::Adapter::TextBlock.new(text: "hi")]
      msg = Dispatch::Adapter::Message.new(role: "user", content: blocks)
      expect(msg.content).to be_an(Array)
      expect(msg.content.first.text).to eq("hi")
    end
  end

  describe "TextBlock" do
    it "defaults type to 'text'" do
      block = Dispatch::Adapter::TextBlock.new(text: "hello")
      expect(block.type).to eq("text")
      expect(block.text).to eq("hello")
    end
  end

  describe "ImageBlock" do
    it "defaults type to 'image'" do
      block = Dispatch::Adapter::ImageBlock.new(source: "data:image/png;base64,abc", media_type: "image/png")
      expect(block.type).to eq("image")
      expect(block.source).to eq("data:image/png;base64,abc")
      expect(block.media_type).to eq("image/png")
    end
  end

  describe "ToolUseBlock" do
    it "defaults type to 'tool_use'" do
      block = Dispatch::Adapter::ToolUseBlock.new(id: "call_1", name: "get_weather", arguments: { "city" => "NYC" })
      expect(block.type).to eq("tool_use")
      expect(block.id).to eq("call_1")
      expect(block.name).to eq("get_weather")
      expect(block.arguments).to eq({ "city" => "NYC" })
    end
  end

  describe "ToolResultBlock" do
    it "defaults type to 'tool_result' and is_error to false" do
      block = Dispatch::Adapter::ToolResultBlock.new(tool_use_id: "call_1", content: "72F")
      expect(block.type).to eq("tool_result")
      expect(block.tool_use_id).to eq("call_1")
      expect(block.content).to eq("72F")
      expect(block.is_error).to be(false)
    end

    it "accepts is_error flag" do
      block = Dispatch::Adapter::ToolResultBlock.new(tool_use_id: "call_1", content: "Error", is_error: true)
      expect(block.is_error).to be(true)
    end
  end

  describe "ToolDefinition" do
    it "creates with keyword args" do
      td = Dispatch::Adapter::ToolDefinition.new(
        name: "search",
        description: "Search the web",
        parameters: { "type" => "object", "properties" => {} }
      )
      expect(td.name).to eq("search")
      expect(td.description).to eq("Search the web")
      expect(td.parameters).to be_a(Hash)
    end
  end

  describe "Response" do
    it "creates with defaults" do
      usage = Dispatch::Adapter::Usage.new(input_tokens: 10, output_tokens: 20)
      resp = Dispatch::Adapter::Response.new(model: "gpt-4", stop_reason: :end_turn, usage: usage)
      expect(resp.content).to be_nil
      expect(resp.tool_calls).to eq([])
      expect(resp.model).to eq("gpt-4")
      expect(resp.stop_reason).to eq(:end_turn)
      expect(resp.usage).to eq(usage)
    end

    it "creates with all fields" do
      usage = Dispatch::Adapter::Usage.new(input_tokens: 10, output_tokens: 20)
      tool_call = Dispatch::Adapter::ToolUseBlock.new(id: "1", name: "test", arguments: {})
      resp = Dispatch::Adapter::Response.new(
        content: "Hello",
        tool_calls: [tool_call],
        model: "gpt-4",
        stop_reason: :tool_use,
        usage: usage
      )
      expect(resp.content).to eq("Hello")
      expect(resp.tool_calls.size).to eq(1)
    end
  end

  describe "Usage" do
    it "defaults cache tokens to 0" do
      usage = Dispatch::Adapter::Usage.new(input_tokens: 100, output_tokens: 50)
      expect(usage.cache_read_tokens).to eq(0)
      expect(usage.cache_creation_tokens).to eq(0)
    end

    it "accepts cache tokens" do
      usage = Dispatch::Adapter::Usage.new(
        input_tokens: 100,
        output_tokens: 50,
        cache_read_tokens: 10,
        cache_creation_tokens: 5
      )
      expect(usage.cache_read_tokens).to eq(10)
      expect(usage.cache_creation_tokens).to eq(5)
    end
  end

  describe "StreamDelta" do
    it "creates a text_delta" do
      delta = Dispatch::Adapter::StreamDelta.new(type: :text_delta, text: "Hello")
      expect(delta.type).to eq(:text_delta)
      expect(delta.text).to eq("Hello")
      expect(delta.tool_call_id).to be_nil
    end

    it "creates a tool_use_start" do
      delta = Dispatch::Adapter::StreamDelta.new(type: :tool_use_start, tool_call_id: "1", tool_name: "search")
      expect(delta.type).to eq(:tool_use_start)
      expect(delta.tool_call_id).to eq("1")
      expect(delta.tool_name).to eq("search")
    end

    it "creates a tool_use_delta" do
      delta = Dispatch::Adapter::StreamDelta.new(type: :tool_use_delta, tool_call_id: "1", argument_delta: '{"q":')
      expect(delta.type).to eq(:tool_use_delta)
      expect(delta.argument_delta).to eq('{"q":')
    end
  end

  describe "ModelInfo" do
    it "creates with all fields" do
      info = Dispatch::Adapter::ModelInfo.new(
        id: "gpt-4",
        name: "GPT-4",
        max_context_tokens: 8192,
        supports_vision: false,
        supports_tool_use: true,
        supports_streaming: true
      )
      expect(info.id).to eq("gpt-4")
      expect(info.name).to eq("GPT-4")
      expect(info.max_context_tokens).to eq(8192)
      expect(info.supports_vision).to be(false)
      expect(info.supports_tool_use).to be(true)
      expect(info.supports_streaming).to be(true)
      expect(info.premium_request_multiplier).to be_nil
    end

    it "accepts premium_request_multiplier" do
      info = Dispatch::Adapter::ModelInfo.new(
        id: "o3",
        name: "o3",
        max_context_tokens: 200_000,
        supports_vision: false,
        supports_tool_use: true,
        supports_streaming: true,
        premium_request_multiplier: 30.0
      )
      expect(info.premium_request_multiplier).to eq(30.0)
    end

    it "defaults premium_request_multiplier to nil" do
      info = Dispatch::Adapter::ModelInfo.new(
        id: "gpt-4.1-nano",
        name: "GPT 4.1 Nano",
        max_context_tokens: 1_047_576,
        supports_vision: false,
        supports_tool_use: true,
        supports_streaming: true
      )
      expect(info.premium_request_multiplier).to be_nil
    end
  end

  describe "Struct equality" do
    it "considers structs with same values equal" do
      a = Dispatch::Adapter::Message.new(role: "user", content: "hello")
      b = Dispatch::Adapter::Message.new(role: "user", content: "hello")
      expect(a).to eq(b)
    end

    it "considers structs with different values not equal" do
      a = Dispatch::Adapter::Message.new(role: "user", content: "hello")
      b = Dispatch::Adapter::Message.new(role: "user", content: "goodbye")
      expect(a).not_to eq(b)
    end

    it "Usage structs are equal with same tokens" do
      a = Dispatch::Adapter::Usage.new(input_tokens: 10, output_tokens: 20)
      b = Dispatch::Adapter::Usage.new(input_tokens: 10, output_tokens: 20)
      expect(a).to eq(b)
    end

    it "ToolUseBlock structs are equal with same fields" do
      a = Dispatch::Adapter::ToolUseBlock.new(id: "1", name: "test", arguments: { "k" => "v" })
      b = Dispatch::Adapter::ToolUseBlock.new(id: "1", name: "test", arguments: { "k" => "v" })
      expect(a).to eq(b)
    end
  end
end
