# frozen_string_literal: true

require "test_helper"

class Honeymaker::Native::LockstepTest < Minitest::Test
  def test_cargo_workspace_version_equals_gem_version
    cargo = File.read(File.expand_path("../../Cargo.toml", __dir__))
    assert_equal Honeymaker::VERSION, cargo[/^\[workspace\.package\].*?^version = "([^"]+)"/m, 1]
  end
end
