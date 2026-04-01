# frozen_string_literal: true

module Dispatch
  module Adapter
    ModelInfo = Struct.new(
      :id, :name, :max_context_tokens,
      :supports_vision, :supports_tool_use, :supports_streaming,
      :premium_request_multiplier,
      keyword_init: true
    ) do
      def initialize(id:, name:, max_context_tokens:, supports_vision:, supports_tool_use:, supports_streaming:,
                     premium_request_multiplier: nil)
        super
      end
    end
  end
end
