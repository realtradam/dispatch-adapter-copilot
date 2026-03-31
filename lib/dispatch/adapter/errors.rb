# frozen_string_literal: true

module Dispatch
  module Adapter
    class Error < StandardError
      attr_reader :status_code, :provider

      def initialize(message = nil, status_code: nil, provider: nil)
        @status_code = status_code
        @provider = provider
        super(message)
      end
    end

    class AuthenticationError < Error; end

    class RateLimitError < Error
      attr_reader :retry_after

      def initialize(message = nil, status_code: nil, provider: nil, retry_after: nil)
        @retry_after = retry_after
        super(message, status_code:, provider:)
      end
    end

    class ServerError < Error; end
    class RequestError < Error; end
    class ConnectionError < Error; end
  end
end
