# frozen_string_literal: true

require 'cent'
require 'webmock/rspec'

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Integration tests (spec/integration/**) only run when pointed at a real
  # Centrifugo instance. Locally: `docker compose up -d` then
  # `CENTRIFUGO_API_URL=http://localhost:8000/api CENTRIFUGO_API_KEY=api_key bundle exec rspec`.
  config.filter_run_excluding(integration: true) unless ENV['CENTRIFUGO_API_URL']
end
