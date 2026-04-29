# frozen_string_literal: true

require "dispatch/adapter/copilot"

# ---------------------------------------------------------------------------
# CRITICAL SAFETY: BLOCK ALL REAL NETWORK ACCESS DURING TESTS.
#
# This gem talks to GitHub Copilot's billed API. A leaked real request during
# a test run could:
#   * authenticate against a real GitHub account if a token is in the env,
#   * consume premium-request quota,
#   * trigger device-flow prompts,
#   * leave persisted token files on disk.
#
# We unconditionally disable all outbound HTTP from spec processes here, in
# the shared spec_helper, so that any spec file (current or future) is
# protected even if it forgets to `require "webmock/rspec"` itself.
# ---------------------------------------------------------------------------
require "webmock/rspec"
WebMock.disable_net_connect!(allow_localhost: false, allow: nil)

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Defense in depth: re-assert net-block before EVERY example, in case some
  # test (or a future contributor) called WebMock.allow_net_connect! and
  # forgot to reset it. Also clears any leftover stubs.
  config.before(:each) do
    WebMock.reset!
    WebMock.disable_net_connect!(allow_localhost: false, allow: nil)
  end
end
