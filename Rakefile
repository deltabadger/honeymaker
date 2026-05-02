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

# Bundler's `release` task is defined when this Rakefile loads — it captures
# the gemspec version at that moment in `Bundler::GemHelper`. If we bump the
# version mid-run (as a build prerequisite), the gem is published correctly
# but the final "Pushed <gem> <ver>" log line still prints the old cached
# version. Fix: bump first, then invoke bundler's release in a subprocess so
# it re-reads the gemspec fresh.

Rake::Task[:release].clear

def do_release(segment)
  bump_version(segment)
  sh "bundle install"
  Rake::Task[:test].invoke
  sh %(git add -A && git diff --cached --quiet || git commit -m "v#{current_version}")
  sh "bundle exec rake _bundler_release"
end

task _bundler_release: %w[build release:guard_clean release:source_control_push release:rubygem_push]

desc "Bump patch, run tests, push to rubygems"
task :release do
  do_release(:patch)
end

namespace :release do
  desc "Bump minor, run tests, push to rubygems"
  task :minor do
    do_release(:minor)
  end

  desc "Bump major, run tests, push to rubygems"
  task :major do
    do_release(:major)
  end
end
