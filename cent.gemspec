# frozen_string_literal: true

require_relative 'lib/cent/version'

Gem::Specification.new do |spec|
  spec.name          = 'cent'
  spec.version       = Cent::VERSION
  spec.authors       = ['Sergey Prikhodko']
  spec.email         = ['prikha@gmail.com']

  spec.summary       = 'Centrifugo API V2 Ruby Client'
  spec.description   = 'Centrifugo API V2 Ruby Client'
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

  spec.add_dependency 'faraday', '>= 0.17.3'
  spec.add_dependency 'faraday_middleware'
  spec.add_dependency 'jwt', '~> 2.2.1'

  spec.add_development_dependency 'bundler'
  spec.add_development_dependency 'rake', '>= 12.3.3'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'webmock', '~> 3.7.5'
end
