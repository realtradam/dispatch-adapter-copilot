# frozen_string_literal: true

module Dispatch
  module Adapter
    Message = Struct.new(:role, :content, keyword_init: true)

    TextBlock = Struct.new(:type, :text, keyword_init: true) do
      def initialize(text:, type: "text")
        super(type:, text:)
      end
    end

    ImageBlock = Struct.new(:type, :source, :media_type, keyword_init: true) do
      def initialize(source:, media_type:, type: "image")
        super(type:, source:, media_type:)
      end
    end

    ToolUseBlock = Struct.new(:type, :id, :name, :arguments, keyword_init: true) do
      def initialize(id:, name:, arguments:, type: "tool_use")
        super(type:, id:, name:, arguments:)
      end
    end

    ToolResultBlock = Struct.new(:type, :tool_use_id, :content, :is_error, keyword_init: true) do
      def initialize(tool_use_id:, content:, is_error: false, type: "tool_result")
        super(type:, tool_use_id:, content:, is_error:)
      end
    end
  end
end
