require 'bundler/setup'
Bundler.setup
require 'centrifuge'
require 'rspec'
require 'vcr'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  VCR.configure do |config|
    config.cassette_library_dir = File.expand_path "../fixtures/vcr_cassettes", __FILE__
    config.hook_into :webmock
    config.configure_rspec_metadata!
    config.default_cassette_options = { :record => :new_episodes }
  end


  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.warnings = false

  if config.files_to_run.one?
    config.default_formatter = 'doc'
  end

  config.profile_examples = 10
  config.order = :random
  Kernel.srand config.seed
end
