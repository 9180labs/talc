# frozen_string_literal: true

require_relative "lib/talc/version"

Gem::Specification.new do |spec|
  spec.name = "talc"
  spec.version = Talc::VERSION
  spec.authors = ["Matrix"]
  spec.email = ["matrix9180@proton.me"]

  spec.summary = "Manage .internal domains with DNS and reverse proxy on Arch Linux"
  spec.description = "Talc is a CLI tool for managing .internal domains on Arch Linux. " \
                     "It integrates with dnsmasq for DNS resolution and Caddy for reverse proxying, " \
                     "enabling easy access to local services via memorable domain names across your LAN."
  spec.homepage = "https://github.com/9180labs/talc"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/9180labs/talc"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "thor", "~> 1.3"

  # Development dependencies
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rubocop", "~> 1.21"
end
