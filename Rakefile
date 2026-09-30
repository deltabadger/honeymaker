# frozen_string_literal: true

require "rake/testtask"

if ENV["HONEYMAKER_RAKEFILE_LIB_ONLY"] != "1" && File.exist?(File.join(__dir__, "honeymaker.gemspec"))
  require "bundler/gem_tasks"
  require "rb_sys/extensiontask"

  GEMSPEC = Gem::Specification.load(File.join(__dir__, "honeymaker.gemspec"))
  RbSys::ExtensionTask.new("honeymaker_native", GEMSPEC) do |ext|
    ext.lib_dir = "lib/honeymaker"
    # Core-only edits must rebuild the extension too (the default pattern covers ext/ only).
    ext.source_pattern = "{**/*,../../crates/honeymaker/**/*,../../Cargo}.{rs,toml,lock}"
    ext.cross_compile = true
    ext.cross_platform = %w[x86_64-linux aarch64-linux x86_64-darwin arm64-darwin x64-mingw-ucrt]
  end
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: %i[compile test]

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
  File.write("Cargo.toml", File.read("Cargo.toml").sub(/(\[workspace\.package\][^\[]*?^version = )"[^"]+"/m, "\\1\"#{new_version}\""))
  puts "Bumped version to #{new_version}"
end

if ENV["HONEYMAKER_RAKEFILE_LIB_ONLY"] != "1" && File.exist?(File.join(__dir__, "honeymaker.gemspec"))
  Rake::Task[:release].clear
end

def do_release(segment)
  bump_version(segment)
  sh "bundle install"
  sh "cargo update --workspace --offline"
  Rake::Task[:compile].invoke
  Rake::Task[:test].invoke
  sh %(git add #{VERSION_FILE} Cargo.toml Cargo.lock Gemfile.lock && git commit -m "v#{current_version}")
  sh "bundle exec rake _tag_release"
end

# Pushes the bump commit and the v* tag; .github/workflows/release.yml builds and publishes.
task _tag_release: %w[release:guard_clean release:source_control_push]

desc "Bump patch, compile, test, and push a release tag for CI"
task :release do
  do_release(:patch)
end

namespace :release do
  desc "Bump minor, compile, test, and push a release tag for CI"
  task :minor do
    do_release(:minor)
  end

  desc "Bump major, compile, test, and push a release tag for CI"
  task :major do
    do_release(:major)
  end
end
