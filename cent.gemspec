# frozen_string_literal: true

require_relative "lib/cent/version"

Gem::Specification.new do |spec|
  spec.name = "cent"
  spec.version = Cent::VERSION
  spec.authors = ["Sergey Prikhodko", "Centrifugal Labs"]
  spec.email = ["prikha@gmail.com"]

  spec.summary = "Ruby SDK for Centrifugo's HTTP server API"
  spec.description = <<~DESC
    Every method of Centrifugo's HTTP server API, with typed results, batches,
    automatic batching and retries; connection, subscription and API tokens,
    JWKS; endpoints for client SDKs and Rack handlers for Centrifugo's proxy.
    No dependencies but json.
  DESC
  spec.homepage = "https://github.com/centrifugal/rubycent"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "source_code_uri" => "https://github.com/centrifugal/rubycent",
    "changelog_uri" => "https://github.com/centrifugal/rubycent/blob/master/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/centrifugal/rubycent/issues",
    "documentation_uri" => "https://rubydoc.info/gems/cent"
  }

  spec.files = Dir["lib/**/*.rb"] + %w[README.md MIGRATING.md CHANGELOG.md LICENSE.txt]
  spec.require_paths = ["lib"]

  # JSON::Fragment, for raw JSON payloads: json 2.10, which Ruby bundles from
  # 4.0.
  spec.add_dependency "json", ">= 2.10"
end
