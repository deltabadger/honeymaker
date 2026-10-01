# frozen_string_literal: true

require "test_helper"
require "open3"

# Spec §2.2: the platform gems cross-compile with nothing but pure-Rust crypto. The async client
# lives in the same Cargo workspace, so this proves the extension never pulls it in.
class Honeymaker::Native::GemIsolationTest < Minitest::Test
  FORBIDDEN = /\A(tokio|tokio-rustls|hyper|hyper-util|rustls|ring|aws-lc-rs|aws-lc-sys|webpki-roots|honeymaker-client) /

  def test_the_extension_does_not_depend_on_the_async_client_stack
    out, status = Open3.capture2("cargo", "tree", "--locked", "-p", "honeymaker_native", "-e", "normal,build",
                                 "--prefix", "none", chdir: File.expand_path("../..", __dir__))
    assert status.success?, "cargo tree failed"
    assert_empty out.lines.grep(FORBIDDEN).uniq
  end
end
