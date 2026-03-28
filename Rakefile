# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: :test

Rake::Task[:build].enhance([:release_preflight])

task :release_preflight do
  sh "bundle install"
  Rake::Task[:test].invoke
  sh 'git add -A && git diff --cached --quiet || git commit -m "$(ruby -e "require_relative \'lib/honeymaker/version\'; puts Honeymaker::VERSION")"'
end
