# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rubocop/rake_task"

desc "Regenerate lib/cent/generated/ from proto/"
task :generate do
  ruby "gen/generate.rb"
end

namespace :generate do
  desc "Fail when lib/cent/generated/ is stale"
  task :check do
    ruby "gen/generate.rb", "--check"
  end
end

namespace :proto do
  desc "Copy api.proto and proxy.proto from a Centrifugo tag (CENTRIFUGO_REF=v6.10.2), and regenerate"
  task :sync do
    ruby "gen/sync_proto.rb"
  end
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/*_test.rb"]
  t.warning = true
end

namespace :test do
  Rake::TestTask.new(:integration) do |t|
    t.description = "Integration tests, against the Centrifugo of testdata/ on :8100"
    t.libs << "test"
    t.test_files = FileList["test/integration/*_test.rb"]
  end
end

RuboCop::RakeTask.new(:lint)

desc "Fail when a public class, module or method has no documentation"
task :docs do
  out = `yard stats --list-undoc --no-save -q 2>&1`
  puts out
  abort "undocumented public API: see above" unless out.include?("100.00% documented")
end

desc "What CI runs, but integration"
task check: %w[generate:check lint test docs]

task default: :check
