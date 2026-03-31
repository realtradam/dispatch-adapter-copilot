# frozen_string_literal: true

module Dispatch
  module Adapter
    ModelInfo = Struct.new(
      :id, :name, :max_context_tokens,
      :supports_vision, :supports_tool_use, :supports_streaming,
      keyword_init: true
    )
  end
end
