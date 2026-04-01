# frozen_string_literal: true

module Dispatch
  module Adapter
    Response = Struct.new(:content, :tool_calls, :model, :stop_reason, :usage, keyword_init: true) do
      def initialize(model:, stop_reason:, usage:, content: nil, tool_calls: [])
        super
      end
    end

    Usage = Struct.new(:input_tokens, :output_tokens, :cache_read_tokens, :cache_creation_tokens, keyword_init: true) do
      def initialize(input_tokens:, output_tokens:, cache_read_tokens: 0, cache_creation_tokens: 0)
        super
      end
    end

    StreamDelta = Struct.new(:type, :text, :tool_call_id, :tool_name, :argument_delta, keyword_init: true) do
      def initialize(type:, text: nil, tool_call_id: nil, tool_name: nil, argument_delta: nil)
        super
      end
    end
  end
end
