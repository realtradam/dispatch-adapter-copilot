# frozen_string_literal: true

module Dispatch
  module Adapter
    class Base
      def chat(_messages, system: nil, tools: [], stream: false, max_tokens: nil, thinking: nil, &_block)
        raise NotImplementedError, "#{self.class}#chat must be implemented"
      end

      def model_name
        raise NotImplementedError, "#{self.class}#model_name must be implemented"
      end

      def count_tokens(_messages, system: nil, tools: []) # rubocop:disable Lint/UnusedMethodArgument
        -1
      end

      def list_models
        raise NotImplementedError, "#{self.class}#list_models must be implemented"
      end

      def provider_name
        self.class.name
      end

      def max_context_tokens
        nil
      end
    end
  end
end
