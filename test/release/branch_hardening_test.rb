# frozen_string_literal: true

require "test_helper"
require "yaml"

class BranchHardeningTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_workflows_parse_and_use_read_only_default_permissions
    %w[test native-gems release].each do |name|
      path = File.join(ROOT, ".github/workflows/#{name}.yml")
      workflow = YAML.load_file(path)
      assert_equal({ "contents" => "read" }, workflow["permissions"], name)
      File.foreach(path).grep(/uses: /).each do |line|
        next if line.include?("uses: ./")

        assert_match(%r{uses: [\w/-]+@[0-9a-f]{40} # v\d+\.\d+\.\d+\s*$}, line, path)
      end
      if name == "release"
        assert_equal({ "id-token" => "write", "contents" => "read" }, workflow.dig("jobs", "publish", "permissions"))
      end
    end
  end

  def test_source_gem_does_not_pin_the_rust_toolchain
    spec = Gem::Specification.load(File.join(ROOT, "honeymaker.gemspec"))
    refute_includes spec.files, "rust-toolchain.toml"
    assert_includes spec.files, "Cargo.toml"
  end

  def test_unused_integer_coercion_is_removed
    refute_match(/pub fn to_i\b/, File.read(File.join(ROOT, "crates/honeymaker/src/semantics.rs")))
  end
end
