# frozen_string_literal: true

require_relative "lib/obxcura/version"

Gem::Specification.new do |spec|
  spec.name = "obxcura"
  spec.version = Obxcura::VERSION
  spec.authors = [ "memoxmrdl" ]
  spec.email = [ "jmemox@gmail.com" ]

  spec.summary = "A small Ruby client for the Obscura headless browser over CDP."
  spec.description = "High-level Browser/Page API for driving h4ckf0r0day/obscura via the Chrome DevTools Protocol."
  spec.homepage = "https://github.com/consultasimple/obxcura"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "websocket-driver", "~> 0.7"

  # nokogiri is optional at runtime (only for #dom/#at_css/#css); dev-only here.
  spec.add_development_dependency "nokogiri", "~> 1.16"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop-rails-omakase", "~> 1.1"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "webrick", "~> 1.8"
  spec.add_development_dependency "yard", "~> 0.9"
end
