# frozen_string_literal: true

require_relative 'lib/cent/version'

Gem::Specification.new do |spec|
  spec.name          = 'cent'
  spec.version       = Cent::VERSION
  spec.authors       = ['Sergey Prikhodko', 'Centrifugal Labs']
  spec.email         = ['prikha@gmail.com']

  spec.summary       = 'Centrifugo server API client for Ruby'
  spec.description   = <<~DESC
    Ruby client for Centrifugo server HTTP API. Provides Cent::Client to call
    Centrifugo server methods (publish, broadcast, subscribe, presence, history, ...)
    and Cent::Notary to issue JWT connection and subscription tokens.
  DESC
  spec.homepage      = 'https://github.com/centrifugal/rubycent'
  spec.license       = 'MIT'
  spec.required_ruby_version = Gem::Requirement.new('>= 3.0')

  spec.metadata['source_code_uri'] = 'https://github.com/centrifugal/rubycent'
  spec.metadata['changelog_uri']   = 'https://github.com/centrifugal/rubycent/releases'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/centrifugal/rubycent/issues'

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      f.match(%r{\A(?:spec|benchmarks|gemfiles|\.github)/}) ||
        f.match(/\A(?:docker-compose\.yml|Appraisals|\.rubocop\.yml|\.rspec|\.gitignore)\z/)
    end
  end

  spec.require_paths = ['lib']

  spec.add_dependency 'faraday', '>= 2.0', '< 4'
  spec.add_dependency 'jwt',     '>= 2.2', '< 4'
end
