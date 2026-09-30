# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Honeymaker::Native::LockstepTest < Minitest::Test
  def test_cargo_workspace_version_equals_gem_version
    cargo = File.read(File.expand_path("../../Cargo.toml", __dir__))
    assert_equal Honeymaker::VERSION, cargo[/^\[workspace\.package\].*?^version = "([^"]+)"/m, 1]
  end

  def test_bump_updates_cargo_too
    rakefile = File.expand_path("../../Rakefile", __dir__)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib/honeymaker"))
      File.write(File.join(dir, "lib/honeymaker/version.rb"), %(module Honeymaker\n  VERSION = "1.2.3"\nend\n))
      File.write(File.join(dir, "Cargo.toml"), %([workspace]\nmembers = []\n\n[workspace.package]\nversion = "1.2.3" # c\n))
      out = Dir.chdir(dir) { `HONEYMAKER_RAKEFILE_LIB_ONLY=1 #{RbConfig.ruby} -rrake -e 'load "#{rakefile}"; bump_version(:minor)' 2>&1` }
      assert_includes out, "1.3.0"
      assert_includes File.read(File.join(dir, "Cargo.toml")), %(version = "1.3.0" # c)
    end
  end
end
