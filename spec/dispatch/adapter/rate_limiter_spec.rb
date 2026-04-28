# frozen_string_literal: true

require "fileutils"
require "json"
require "tempfile"

RSpec.describe Dispatch::Adapter::RateLimiter do
  let(:tmpdir) { Dir.mktmpdir("rate_limiter_test") }
  let(:rate_limit_path) { File.join(tmpdir, "copilot_rate_limit") }

  after { FileUtils.rm_rf(tmpdir) }

  describe "#initialize" do
    it "accepts valid min_request_interval and nil rate_limit" do
      limiter = described_class.new(
        rate_limit_path: rate_limit_path,
        min_request_interval: 3.0,
        rate_limit: nil
      )
      expect(limiter).to be_a(described_class)
    end

    it "accepts nil min_request_interval" do
      limiter = described_class.new(
        rate_limit_path: rate_limit_path,
        min_request_interval: nil,
        rate_limit: nil
      )
      expect(limiter).to be_a(described_class)
    end

    it "accepts zero min_request_interval" do
      limiter = described_class.new(
        rate_limit_path: rate_limit_path,
        min_request_interval: 0,
        rate_limit: nil
      )
      expect(limiter).to be_a(described_class)
    end

    it "accepts valid rate_limit hash" do
      limiter = described_class.new(
        rate_limit_path: rate_limit_path,
        min_request_interval: nil,
        rate_limit: { requests: 10, period: 60 }
      )
      expect(limiter).to be_a(described_class)
    end

    it "accepts both min_request_interval and rate_limit" do
      limiter = described_class.new(
        rate_limit_path: rate_limit_path,
        min_request_interval: 2.0,
        rate_limit: { requests: 5, period: 30 }
      )
      expect(limiter).to be_a(described_class)
    end

    it "raises ArgumentError for negative min_request_interval" do
      expect do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: -1,
          rate_limit: nil
        )
      end.to raise_error(ArgumentError, /min_request_interval/)
    end

    it "raises ArgumentError for non-numeric min_request_interval" do
      expect do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: "fast",
          rate_limit: nil
        )
      end.to raise_error(ArgumentError, /min_request_interval/)
    end

    it "raises ArgumentError when rate_limit is missing requests key" do
      expect do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: nil,
          rate_limit: { period: 60 }
        )
      end.to raise_error(ArgumentError, /requests/)
    end

    it "raises ArgumentError when rate_limit is missing period key" do
      expect do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: nil,
          rate_limit: { requests: 10 }
        )
      end.to raise_error(ArgumentError, /period/)
    end

    it "raises ArgumentError when rate_limit requests is zero" do
      expect do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: nil,
          rate_limit: { requests: 0, period: 60 }
        )
      end.to raise_error(ArgumentError, /requests/)
    end

    it "raises ArgumentError when rate_limit requests is negative" do
      expect do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: nil,
          rate_limit: { requests: -1, period: 60 }
        )
      end.to raise_error(ArgumentError, /requests/)
    end

    it "raises ArgumentError when rate_limit period is zero" do
      expect do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: nil,
          rate_limit: { requests: 10, period: 0 }
        )
      end.to raise_error(ArgumentError, /period/)
    end

    it "raises ArgumentError when rate_limit period is negative" do
      expect do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: nil,
          rate_limit: { requests: 10, period: -5 }
        )
      end.to raise_error(ArgumentError, /period/)
    end

    it "raises ArgumentError when rate_limit is not a Hash" do
      expect do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: nil,
          rate_limit: "10/60"
        )
      end.to raise_error(ArgumentError)
    end
  end

  describe "#wait!" do
    context "with both mechanisms disabled" do
      let(:limiter) do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: nil,
          rate_limit: nil
        )
      end

      it "returns immediately without sleeping" do
        expect(limiter).not_to receive(:sleep)
        limiter.wait!
      end

      it "does not create a rate limit file" do
        limiter.wait!
        expect(File.exist?(rate_limit_path)).to be(false)
      end
    end

    context "with per-request cooldown only" do
      let(:limiter) do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: 1.0,
          rate_limit: nil
        )
      end

      it "does not sleep on the first request" do
        expect(limiter).not_to receive(:sleep)
        limiter.wait!
      end

      it "creates the rate limit file on first request" do
        limiter.wait!
        expect(File.exist?(rate_limit_path)).to be(true)
      end

      it "sets the rate limit file permissions to 0600" do
        limiter.wait!
        mode = File.stat(rate_limit_path).mode & 0o777
        expect(mode).to eq(0o600)
      end

      it "records last_request_at in the state file" do
        before = Time.now.to_f
        limiter.wait!
        after = Time.now.to_f

        state = JSON.parse(File.read(rate_limit_path))
        expect(state["last_request_at"]).to be_between(before, after)
      end

      it "sleeps for the remaining cooldown on a rapid second request" do
        limiter.wait!

        # Simulate that almost no time has passed
        allow(limiter).to receive(:sleep) { |duration| expect(duration).to be > 0 }
        limiter.wait!
      end

      it "does not sleep when enough time has elapsed between requests" do
        limiter.wait!

        # Write a past timestamp to simulate time passing
        state = { "last_request_at" => Time.now.to_f - 2.0, "request_log" => [] }
        File.write(rate_limit_path, JSON.generate(state))

        expect(limiter).not_to receive(:sleep)
        limiter.wait!
      end
    end

    context "with sliding window only" do
      let(:limiter) do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: nil,
          rate_limit: { requests: 3, period: 10 }
        )
      end

      it "allows requests up to the window limit without sleeping" do
        expect(limiter).not_to receive(:sleep)
        3.times { limiter.wait! }
      end

      it "sleeps when the window limit is reached" do
        now = Time.now.to_f
        state = {
          "last_request_at" => now,
          "request_log" => [ now - 2.0, now - 1.0, now ]
        }
        File.write(rate_limit_path, JSON.generate(state))

        allow(limiter).to receive(:sleep) { |duration| expect(duration).to be > 0 }
        limiter.wait!
      end

      it "does not sleep when oldest entries have expired from the window" do
        now = Time.now.to_f
        state = {
          "last_request_at" => now - 5.0,
          "request_log" => [ now - 15.0, now - 12.0, now - 5.0 ]
        }
        File.write(rate_limit_path, JSON.generate(state))

        expect(limiter).not_to receive(:sleep)
        limiter.wait!
      end

      it "prunes expired entries from the request_log on write" do
        now = Time.now.to_f
        state = {
          "last_request_at" => now - 5.0,
          "request_log" => [ now - 20.0, now - 15.0, now - 5.0 ]
        }
        File.write(rate_limit_path, JSON.generate(state))

        limiter.wait!

        updated_state = JSON.parse(File.read(rate_limit_path))
        # Old entries (20s and 15s ago) should be pruned (window is 10s)
        # Only the 5s-ago entry and the new entry should remain
        expect(updated_state["request_log"].size).to be <= 2
      end
    end

    context "with both mechanisms enabled" do
      let(:limiter) do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: 1.0,
          rate_limit: { requests: 3, period: 10 }
        )
      end

      it "uses the longer wait time when cooldown is the bottleneck" do
        limiter.wait!

        # Second request immediately — cooldown should be the bottleneck
        # (only 1 of 3 window slots used, but cooldown not elapsed)
        allow(limiter).to receive(:sleep) { |duration| expect(duration).to be > 0 }
        limiter.wait!
      end

      it "uses the longer wait time when window limit is the bottleneck" do
        now = Time.now.to_f
        state = {
          "last_request_at" => now - 2.0, # cooldown elapsed
          "request_log" => [ now - 3.0, now - 2.5, now - 2.0 ] # window full
        }
        File.write(rate_limit_path, JSON.generate(state))

        allow(limiter).to receive(:sleep) { |duration| expect(duration).to be > 0 }
        limiter.wait!
      end
    end

    context "with a missing or corrupt state file" do
      let(:limiter) do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: 1.0,
          rate_limit: nil
        )
      end

      it "treats a non-existent file as fresh state" do
        expect(File.exist?(rate_limit_path)).to be(false)
        expect(limiter).not_to receive(:sleep)
        limiter.wait!
      end

      it "treats an empty file as fresh state" do
        FileUtils.mkdir_p(File.dirname(rate_limit_path))
        File.write(rate_limit_path, "")

        expect(limiter).not_to receive(:sleep)
        limiter.wait!
      end

      it "treats a corrupt JSON file as fresh state" do
        FileUtils.mkdir_p(File.dirname(rate_limit_path))
        File.write(rate_limit_path, "not valid json{{{")

        expect(limiter).not_to receive(:sleep)
        limiter.wait!
      end

      it "overwrites corrupt state with valid state after a request" do
        FileUtils.mkdir_p(File.dirname(rate_limit_path))
        File.write(rate_limit_path, "garbage")

        limiter.wait!

        state = JSON.parse(File.read(rate_limit_path))
        expect(state).to have_key("last_request_at")
        expect(state["last_request_at"]).to be_a(Float)
      end
    end

    context "with a missing parent directory" do
      let(:nested_path) { File.join(tmpdir, "sub", "dir", "copilot_rate_limit") }

      let(:limiter) do
        described_class.new(
          rate_limit_path: nested_path,
          min_request_interval: 1.0,
          rate_limit: nil
        )
      end

      it "creates parent directories" do
        limiter.wait!
        expect(File.exist?(nested_path)).to be(true)
      end
    end

    context "cross-process coordination" do
      let(:limiter) do
        described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: 1.0,
          rate_limit: nil
        )
      end

      it "reads state written by another process" do
        # Simulate another process having made a request just now
        now = Time.now.to_f
        state = { "last_request_at" => now, "request_log" => [ now ] }
        FileUtils.mkdir_p(File.dirname(rate_limit_path))
        File.write(rate_limit_path, JSON.generate(state))

        # Our limiter should see this and wait
        allow(limiter).to receive(:sleep) { |duration| expect(duration).to be > 0 }
        limiter.wait!
      end

      it "writes state that another process can read" do
        limiter.wait!

        # Another RateLimiter instance (simulating another process) reads the file
        other_limiter = described_class.new(
          rate_limit_path: rate_limit_path,
          min_request_interval: 1.0,
          rate_limit: nil
        )

        allow(other_limiter).to receive(:sleep) { |duration| expect(duration).to be > 0 }
        other_limiter.wait!
      end
    end
  end
end
