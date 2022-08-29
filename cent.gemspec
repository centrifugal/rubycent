# frozen_string_literal: true

require_relative 'lib/cent/version'

Gem::Specification.new do |spec|
  spec.name          = 'cent'
  spec.version       = Cent::VERSION
  spec.authors       = ['Sergey Prikhodko']
  spec.email         = ['prikha@gmail.com']

  spec.summary       = 'Centrifugo API V2 Ruby Client'
  spec.description   = <<~DESC
    Provides helper classes Cent::Client and Cent::Notary.

    `Cent::Client` is made to communicate to the server API
    `Client::Notary` is a simple JWT wrapper to generate authorization tokens for the frontend
  DESC
  spec.homepage      = 'https://github.com/centrifugal/rubycent'
  spec.license       = 'MIT'
  spec.required_ruby_version = Gem::Requirement.new('>= 2.5.0')

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/centrifugal/rubycent'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{\A(?:spec|Gemfile)/}) }
  end

  spec.require_paths = ['lib']

  spec.add_dependency 'faraday', '<3.0.0', '> 1.0.0'
  # NOTE: Remove `faraday_middleware` after changing `faraday`'s minimum version to `2.0.0`.
  spec.add_dependency 'faraday_middleware', '<2.0.0', '~> 1.0'
  spec.add_dependency 'jwt', '~> 2.2'
end
