# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "digest"
require "rubygems/package"

class PushGemsTest < Minitest::Test
  SCRIPT = File.expand_path("../../script/release/push_gems.sh", __dir__)

  PLATFORMS = %w[x86_64-linux aarch64-linux x86_64-darwin arm64-darwin x64-mingw-ucrt].freeze

  def build_gem(dir, platform)
    spec = Gem::Specification.new do |s|
      s.name = "honeymaker"
      s.version = "9.9.9"
      s.summary = "t"
      s.authors = ["t"]
      s.files = []
      s.platform = platform
    end
    Dir.chdir(dir) { Gem::Package.build(spec) }
    File.join(dir, spec.file_name)
  end

  def run_script(gems_dir, published_sha:, push_fails:)
    Dir.mktmpdir do |bin|
      log = File.join(bin, "log")
      File.write(File.join(bin, "gem"), "#!/bin/sh\necho \"push $2\" >> #{log}\n#{push_fails ? 'exit 1' : 'exit 0'}\n")
      File.write(File.join(bin, "curl"), "#!/bin/sh\necho '{\"sha\":\"#{published_sha}\"}'\n")
      File.chmod(0o755, File.join(bin, "gem"), File.join(bin, "curl"))
      out = `PATH=#{bin}:$PATH #{SCRIPT} #{gems_dir} 9.9.9 2>&1`
      [$?.success?, out, File.exist?(log) ? File.read(log).lines.map { |l| File.basename(l.split.last) } : []]
    end
  end

  def full_set(dir)
    plats = PLATFORMS.map { |pl| build_gem(dir, pl) }
    [plats, build_gem(dir, "ruby")]
  end

  def test_platform_gems_first_then_source_and_idempotent_on_identical_rerun
    Dir.mktmpdir do |dir|
      plats, source = full_set(dir)
      ok, _out, order = run_script(dir, published_sha: "x", push_fails: false)
      assert ok
      assert_equal plats.map { |g| File.basename(g) } + [File.basename(source)], order
      ok, out, = run_script(dir, published_sha: Digest::SHA256.file(plats.first).hexdigest, push_fails: true)
      refute ok, "only the first gem matches the stubbed sha, so the run must stop at the second"
      assert_includes out, "already published with the same checksum"
    end
  end

  def test_mismatched_published_gem_fails
    Dir.mktmpdir do |dir|
      full_set(dir)
      ok, out, = run_script(dir, published_sha: "deadbeef", push_fails: true)
      refute ok
      assert_includes out, "differs from the published gem"
    end
  end

  def test_missing_or_empty_artifacts_push_nothing_and_fail
    Dir.mktmpdir do |dir|
      ok, out, order = run_script(File.join(dir, "nope"), published_sha: "x", push_fails: false)
      refute ok
      assert_empty order
      ok, out, order = run_script(dir, published_sha: "x", push_fails: false)
      refute ok, out
      assert_empty order
      PLATFORMS.first(4).each { |pl| build_gem(dir, pl) }
      build_gem(dir, "ruby")
      ok, out, order = run_script(dir, published_sha: "x", push_fails: false)
      refute ok, "one platform missing must block the whole release"
      assert_includes out, "missing honeymaker-9.9.9-x64-mingw-ucrt.gem"
      assert_empty order
    end
  end
end
