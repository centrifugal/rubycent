# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'centrifuge/version'

Gem::Specification.new do |spec|
  spec.name          = "centrifuge"
  spec.version       = Centrifuge::VERSION
  spec.authors       = ["Oleg Bovykin"]
  spec.email         = ["oleg.bovykin@gmail.com"]
  spec.summary       = %q{Ruby wrapper for centrifuge API}
  spec.description   = %q{Ruby wrapper for centrifuge real time messaging API}
  spec.homepage      = "https://github.com/arrowcircle/centrifuge"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency 'httpclient'
  spec.add_dependency 'multi_json'

  spec.add_development_dependency "bundler", "~> 1.7"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec"
  spec.add_development_dependency "guard-rspec"
  spec.add_development_dependency "webmock"

end
