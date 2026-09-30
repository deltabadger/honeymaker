# frozen_string_literal: true

# Runs against an INSTALLED gem (no bundler, no -Ilib) on native CI runners.
# EXPECT_PLATFORM=x86_64-linux (platform gem) or EXPECT_PLATFORM=ruby (source gem, compiled on install).
require "honeymaker"

Honeymaker::Native.load!
abort "native #{Honeymaker::Native::Ext.version} != gem #{Honeymaker::VERSION}" unless Honeymaker::Native::Ext.version == Honeymaker::VERSION
spec = Gem.loaded_specs.fetch("honeymaker")
expected = ENV.fetch("EXPECT_PLATFORM")
abort "installed platform #{spec.platform} != #{expected}" unless spec.platform.to_s == expected
puts "smoke ok #{RUBY_VERSION} #{RUBY_PLATFORM} #{spec.full_name}"
