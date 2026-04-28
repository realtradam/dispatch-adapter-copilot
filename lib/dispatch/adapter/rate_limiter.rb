# frozen_string_literal: true

require "json"
require "fileutils"

module Dispatch
  module Adapter
    class RateLimiter
      def initialize(rate_limit_path:, min_request_interval:, rate_limit:)
        validate_min_request_interval!(min_request_interval)
        validate_rate_limit!(rate_limit)

        @rate_limit_path = rate_limit_path
        @min_request_interval = min_request_interval
        @rate_limit = rate_limit
      end

      def wait!
        return if disabled?

        loop do
          wait_time = 0.0
          done = false

          File.open(rate_limit_file, File::RDWR | File::CREAT) do |file|
            file.flock(File::LOCK_EX)
            state = read_state(file)
            now = Time.now.to_f
            wait_time = compute_wait(state, now)

            if wait_time <= 0
              record_request(state, now)
              write_state(file, state)
              done = true
            end
          end

          return if done

          sleep(wait_time)
        end
      end

      private

      def disabled?
        effective_min_interval.nil? && @rate_limit.nil?
      end

      def effective_min_interval
        return nil if @min_request_interval.nil?
        return nil if @min_request_interval.zero?

        @min_request_interval
      end

      def rate_limit_file
        FileUtils.mkdir_p(File.dirname(@rate_limit_path))
        File.chmod(0o600, @rate_limit_path) if File.exist?(@rate_limit_path)
        @rate_limit_path
      end

      def read_state(file)
        file.rewind
        content = file.read
        return default_state if content.nil? || content.strip.empty?

        parsed = JSON.parse(content)
        {
          "last_request_at" => parsed["last_request_at"]&.to_f,
          "request_log" => Array(parsed["request_log"]).map(&:to_f)
        }
      rescue JSON::ParserError
        default_state
      end

      def default_state
        { "last_request_at" => nil, "request_log" => [] }
      end

      def write_state(file, state)
        file.rewind
        file.truncate(0)
        file.write(JSON.generate(state))
        file.flush

        File.chmod(0o600, @rate_limit_path)
      end

      def compute_wait(state, now)
        cooldown_wait = compute_cooldown_wait(state, now)
        window_wait = compute_window_wait(state, now)
        [ cooldown_wait, window_wait ].max
      end

      def compute_cooldown_wait(state, now)
        interval = effective_min_interval
        return 0.0 if interval.nil?

        last = state["last_request_at"]
        return 0.0 if last.nil?

        elapsed = now - last
        remaining = interval - elapsed
        remaining.positive? ? remaining : 0.0
      end

      def compute_window_wait(state, now)
        return 0.0 if @rate_limit.nil?

        max_requests = @rate_limit[:requests]
        period = @rate_limit[:period]
        window_start = now - period

        log = state["request_log"].select { |t| t > window_start }

        return 0.0 if log.size < max_requests

        oldest_in_window = log.min
        wait = oldest_in_window + period - now
        wait.positive? ? wait : 0.0
      end

      def record_request(state, now)
        state["last_request_at"] = now
        state["request_log"] << now
        prune_log(state, now)
      end

      def prune_log(state, now)
        if @rate_limit
          period = @rate_limit[:period]
          cutoff = now - period
          state["request_log"] = state["request_log"].select { |t| t > cutoff }
        else
          state["request_log"] = []
        end
      end

      def validate_min_request_interval!(value)
        return if value.nil?

        unless value.is_a?(Numeric)
          raise ArgumentError,
                "min_request_interval must be nil or a Numeric >= 0, got #{value.inspect}"
        end

        return unless value.negative?

        raise ArgumentError,
              "min_request_interval must be nil or a Numeric >= 0, got #{value.inspect}"
      end

      def validate_rate_limit!(value)
        return if value.nil?

        unless value.is_a?(Hash)
          raise ArgumentError,
                "rate_limit must be nil or a Hash with :requests and :period keys, got #{value.inspect}"
        end

        unless value.key?(:requests) && value[:requests].is_a?(Integer) && value[:requests].positive?
          raise ArgumentError,
                "rate_limit[:requests] must be a positive Integer, got #{value[:requests].inspect}"
        end

        return if value.key?(:period) && value[:period].is_a?(Numeric) && value[:period].positive?

        raise ArgumentError,
              "rate_limit[:period] must be a positive Numeric, got #{value[:period].inspect}"
      end
    end
  end
end
