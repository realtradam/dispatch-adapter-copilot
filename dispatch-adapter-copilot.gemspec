# frozen_string_literal: true

require_relative "lib/dispatch/adapter/version"

Gem::Specification.new do |spec|
  spec.name = "dispatch-adapter-copilot"
  spec.version = Dispatch::Adapter::CopilotVersion::VERSION
  spec.authors = ["Adam Malczewski"]
  spec.email = ["github@tradam.dev"]

  spec.summary = "GitHub Copilot adapter for Dispatch LLM framework"
  spec.description = "GitHub Copilot adapter for the Dispatch LLM framework, implementing the dispatch-adapter-interface to provide chat completions via the Copilot API over HTTP."
  spec.homepage = "https://github.com/realtradam/dispatch-adapter-copilot"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .rubocop.yml])
    end
  end
  spec.files.select! { |f| File.exist?(File.join(__dir__, f)) }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  spec.add_dependency "dispatch-adapter-interface", "~> 0.2"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
