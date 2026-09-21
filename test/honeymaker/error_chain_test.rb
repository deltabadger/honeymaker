# frozen_string_literal: true

require "test_helper"
require "socket"

# A transport failure — the request got no HTTP answer at all — carries the chain of exception
# classes behind it, outermost first. The text of such a failure rarely says what happened
# ("end of file reached"); the chain does, and it is what lets a caller tell a request that never
# left (DNS, a refused connection, a proxy refusing CONNECT) from one that may have landed (EOF,
# reset, read timeout). Honeymaker only reports it; deciding what it means is the caller's job.
class Honeymaker::ErrorChainTest < Minitest::Test
  def test_walks_wrapped_exceptions_and_causes_outermost_first
    error = Faraday::ConnectionFailed.new(EOFError.new("end of file reached"))

    assert_equal %w[Faraday::ConnectionFailed EOFError], Honeymaker::Utils.error_chain(error)
  end

  def test_follows_ruby_causes_and_names_each_class_once
    error = begin
      begin
        raise Errno::ECONNREFUSED
      rescue Errno::ECONNREFUSED
        raise Faraday::ConnectionFailed, "connection refused"
      end
    rescue Faraday::ConnectionFailed => e
      e
    end

    assert_equal %w[Faraday::ConnectionFailed Errno::ECONNREFUSED], Honeymaker::Utils.error_chain(error)
  end

  # Adapters re-wrap: a class seen once must not hide what sits beneath its second instance.
  def test_a_repeated_class_does_not_cut_the_chain_short
    inner = Faraday::ConnectionFailed.new(Errno::ECONNREFUSED.new)
    error = Faraday::ConnectionFailed.new(inner)

    assert_equal %w[Faraday::ConnectionFailed Errno::ECONNREFUSED], Honeymaker::Utils.error_chain(error)
  end

  def test_client_failure_carries_the_chain_and_keeps_its_text
    result = Honeymaker::Client.new.send(:with_rescue) do
      raise Faraday::ConnectionFailed, EOFError.new("end of file reached")
    end

    assert_equal ["end of file reached"], result.errors
    assert_nil result.data[:status]
    assert_equal %w[Faraday::ConnectionFailed EOFError], result.data[:error_chain]
  end

  def test_exchange_failure_carries_the_chain_and_keeps_its_text
    result = Honeymaker::Exchange.new.send(:with_rescue) do
      raise Faraday::ConnectionFailed, EOFError.new("end of file reached")
    end

    assert_equal ["end of file reached"], result.errors
    assert_equal %w[Faraday::ConnectionFailed EOFError], result.data[:error_chain]
  end

  # An HTTP answer is not a transport failure: its status says what happened.
  def test_a_failure_with_an_http_answer_has_no_chain
    error = Faraday::ServerError.new("boom", { status: 503, body: "unavailable" })
    [Honeymaker::Client.new, Honeymaker::Exchange.new].each do |receiver|
      result = receiver.send(:with_rescue) { raise error }

      assert_nil result.data[:error_chain], receiver.class.name
    end
  end

  # --- The chains the real adapter produces, against local sockets -------------------------------

  def test_real_chain_for_a_connection_closed_before_the_answer
    server = TCPServer.new("127.0.0.1", 0)
    Thread.new { loop { (c = server.accept).readpartial(4096) rescue nil; c.close } }

    assert_equal %w[Faraday::ConnectionFailed EOFError], chain_of("http://127.0.0.1:#{server.addr[1]}")
  ensure
    server&.close
  end

  def test_real_chain_for_a_refused_connection
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }

    assert_includes chain_of("http://127.0.0.1:#{port}"), "Errno::ECONNREFUSED"
  end

  def test_real_chain_for_a_proxy_refusing_connect
    proxy = TCPServer.new("127.0.0.1", 0)
    Thread.new do
      loop do
        c = proxy.accept
        c.readpartial(4096) rescue nil
        c.write("HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n")
        c.close
      end
    end
    client = Honeymaker::Client.new(proxy: "http://127.0.0.1:#{proxy.addr[1]}")
    result = client.send(:with_rescue) { client.send(:build_client_connection, "https://example.com").get("/") }

    assert_equal %w[Faraday::ConnectionFailed Net::HTTPClientException], result.data[:error_chain]
  ensure
    proxy&.close
  end

  private

  def chain_of(url)
    client = Honeymaker::Client.new
    client.send(:with_rescue) { client.send(:build_client_connection, url).get("/") }.data[:error_chain]
  end
end
