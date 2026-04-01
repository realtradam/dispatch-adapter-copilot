# frozen_string_literal: true

require "webmock/rspec"
require "fileutils"
require "tmpdir"

RSpec.describe Dispatch::Adapter::Copilot, "rate limiting" do
  let(:copilot_token) { "cop_test_token_abc" }
  let(:github_token) { "gho_test_github_token" }
  let(:tmpdir) { Dir.mktmpdir("copilot_rate_limit_test") }
  let(:token_path) { File.join(tmpdir, "copilot_github_token") }

  let(:chat_response_body) do
    JSON.generate({
                    "choices" => [{ "message" => { "content" => "ok" }, "finish_reason" => "stop" }],
                    "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 }
                  })
  end

  let(:messages) { [Dispatch::Adapter::Message.new(role: "user", content: "Hi")] }

  before do
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

    stub_request(:post, "https://api.githubcopilot.com/chat/completions")
      .to_return(
        status: 200,
        body: chat_response_body,
        headers: { "Content-Type" => "application/json" }
      )
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "constructor rate limit parameters" do
    it "accepts default rate limit parameters" do
      adapter = described_class.new(
        model: "gpt-4.1",
        github_token: github_token,
        token_path: token_path
      )
      expect(adapter).to be_a(described_class)
    end

    it "accepts custom min_request_interval" do
      adapter = described_class.new(
        model: "gpt-4.1",
        github_token: github_token,
        token_path: token_path,
        min_request_interval: 5.0
      )
      expect(adapter).to be_a(described_class)
    end

    it "accepts nil min_request_interval to disable cooldown" do
      adapter = described_class.new(
        model: "gpt-4.1",
        github_token: github_token,
        token_path: token_path,
        min_request_interval: nil
      )
      expect(adapter).to be_a(described_class)
    end

    it "accepts rate_limit hash for sliding window" do
      adapter = described_class.new(
        model: "gpt-4.1",
        github_token: github_token,
        token_path: token_path,
        rate_limit: { requests: 10, period: 60 }
      )
      expect(adapter).to be_a(described_class)
    end

    it "raises ArgumentError for invalid min_request_interval" do
      expect do
        described_class.new(
          model: "gpt-4.1",
          github_token: github_token,
          token_path: token_path,
          min_request_interval: -1
        )
      end.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for invalid rate_limit hash" do
      expect do
        described_class.new(
          model: "gpt-4.1",
          github_token: github_token,
          token_path: token_path,
          rate_limit: { requests: 0, period: 60 }
        )
      end.to raise_error(ArgumentError)
    end
  end

  describe "#chat with rate limiting" do
    context "with default 3s cooldown" do
      let(:adapter) do
        described_class.new(
          model: "gpt-4.1",
          github_token: github_token,
          token_path: token_path
        )
      end

      it "does not sleep on the first request" do
        rate_limiter = instance_double(Dispatch::Adapter::RateLimiter)
        allow(Dispatch::Adapter::RateLimiter).to receive(:new).and_return(rate_limiter)
        allow(rate_limiter).to receive(:wait!)

        fresh_adapter = described_class.new(
          model: "gpt-4.1",
          github_token: github_token,
          token_path: token_path
        )
        fresh_adapter.chat(messages)

        expect(rate_limiter).to have_received(:wait!).once
      end

      it "calls wait! before every chat request" do
        rate_limiter = instance_double(Dispatch::Adapter::RateLimiter)
        allow(Dispatch::Adapter::RateLimiter).to receive(:new).and_return(rate_limiter)
        allow(rate_limiter).to receive(:wait!)

        fresh_adapter = described_class.new(
          model: "gpt-4.1",
          github_token: github_token,
          token_path: token_path
        )
        fresh_adapter.chat(messages)
        fresh_adapter.chat(messages)
        fresh_adapter.chat(messages)

        expect(rate_limiter).to have_received(:wait!).exactly(3).times
      end
    end

    context "with rate limiting disabled" do
      let(:adapter) do
        described_class.new(
          model: "gpt-4.1",
          github_token: github_token,
          token_path: token_path,
          min_request_interval: nil,
          rate_limit: nil
        )
      end

      it "does not sleep between rapid requests" do
        rate_limiter = instance_double(Dispatch::Adapter::RateLimiter)
        allow(Dispatch::Adapter::RateLimiter).to receive(:new).and_return(rate_limiter)
        allow(rate_limiter).to receive(:wait!)

        fresh_adapter = described_class.new(
          model: "gpt-4.1",
          github_token: github_token,
          token_path: token_path,
          min_request_interval: nil,
          rate_limit: nil
        )
        fresh_adapter.chat(messages)
        fresh_adapter.chat(messages)

        expect(rate_limiter).to have_received(:wait!).twice
      end
    end
  end

  describe "#chat streaming with rate limiting" do
    it "calls wait! before a streaming request" do
      sse_body = [
        "data: #{JSON.generate({ "choices" => [{ "delta" => { "content" => "hi" }, "index" => 0 }] })}\n\n",
        "data: #{JSON.generate({ "choices" => [{ "delta" => {}, "index" => 0, "finish_reason" => "stop" }],
                                 "usage" => { "prompt_tokens" => 5, "completion_tokens" => 1 } })}\n\n",
        "data: [DONE]\n\n"
      ].join

      stub_request(:post, "https://api.githubcopilot.com/chat/completions")
        .to_return(status: 200, body: sse_body, headers: { "Content-Type" => "text/event-stream" })

      rate_limiter = instance_double(Dispatch::Adapter::RateLimiter)
      allow(Dispatch::Adapter::RateLimiter).to receive(:new).and_return(rate_limiter)
      allow(rate_limiter).to receive(:wait!)

      adapter = described_class.new(
        model: "gpt-4.1",
        github_token: github_token,
        token_path: token_path
      )
      adapter.chat(messages, stream: true) { |_| }

      expect(rate_limiter).to have_received(:wait!).once
    end
  end

  describe "#list_models with rate limiting" do
    it "calls wait! before list_models request" do
      stub_request(:get, "https://api.githubcopilot.com/v1/models")
        .to_return(
          status: 200,
          body: JSON.generate({ "data" => [{ "id" => "gpt-4.1", "object" => "model" }] }),
          headers: { "Content-Type" => "application/json" }
        )

      rate_limiter = instance_double(Dispatch::Adapter::RateLimiter)
      allow(Dispatch::Adapter::RateLimiter).to receive(:new).and_return(rate_limiter)
      allow(rate_limiter).to receive(:wait!)

      adapter = described_class.new(
        model: "gpt-4.1",
        github_token: github_token,
        token_path: token_path
      )
      adapter.list_models

      expect(rate_limiter).to have_received(:wait!).once
    end
  end

  describe "rate limit file location" do
    it "stores the rate limit file in the same directory as the token file" do
      adapter = described_class.new(
        model: "gpt-4.1",
        github_token: github_token,
        token_path: token_path
      )
      adapter.chat(messages)

      rate_limit_path = File.join(tmpdir, "copilot_rate_limit")
      expect(File.exist?(rate_limit_path)).to be(true)
    end
  end
end
