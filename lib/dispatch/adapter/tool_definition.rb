# frozen_string_literal: true

module Dispatch
  module Adapter
    ToolDefinition = Struct.new(:name, :description, :parameters, keyword_init: true)
  end
end
