# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: :test

VERSION_FILE = "lib/honeymaker/version.rb"

def current_version
  File.read(VERSION_FILE).match(/VERSION = "(.+)"/)[1]
end

def bump_version(segment)
  major, minor, patch = current_version.split(".").map(&:to_i)
  new_version = case segment
  when :major then [major + 1, 0, 0]
  when :minor then [major, minor + 1, 0]
  when :patch then [major, minor, patch + 1]
  end.join(".")
  content = File.read(VERSION_FILE)
  File.write(VERSION_FILE, content.sub(/VERSION = ".+"/, "VERSION = \"#{new_version}\""))
  puts "Bumped version to #{new_version}"
end

task :bump_version do
  bump_version(@bump_segment || :patch)
end

task release_preflight: :bump_version do
  sh "bundle install"
  Rake::Task[:test].invoke
  sh 'git add -A && git diff --cached --quiet || git commit -m "$(ruby -e "require_relative \'lib/honeymaker/version\'; puts Honeymaker::VERSION")"'
end

Rake::Task[:build].enhance([:release_preflight])

namespace :release do
  task :minor do
    @bump_segment = :minor
    Rake::Task[:release].invoke
  end

  task :major do
    @bump_segment = :major
    Rake::Task[:release].invoke
  end
end
