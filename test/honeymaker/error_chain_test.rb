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

  def setup
    @servers = []
  end

  # Closing a server makes its blocked #accept raise, which ends the serving thread; joining it
  # keeps that thread from outliving the test.
  def teardown
    @servers.each do |server, thread|
      server.close
      thread.join(1)
    end
  end

  def test_real_chain_for_a_connection_closed_before_the_answer
    port = local_server

    assert_equal %w[Faraday::ConnectionFailed EOFError], chain_of("http://127.0.0.1:#{port}")
  end

  def test_real_chain_for_a_refused_connection
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }

    assert_includes chain_of("http://127.0.0.1:#{port}"), "Errno::ECONNREFUSED"
  end

  def test_real_chain_for_a_proxy_refusing_connect
    port = local_server("HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n")
    client = Honeymaker::Client.new(proxy: "http://127.0.0.1:#{port}")
    result = client.send(:with_rescue) { client.send(:build_client_connection, "https://example.com").get("/") }

    assert_equal %w[Faraday::ConnectionFailed Net::HTTPClientException], result.data[:error_chain]
  end

  private

  # A local server that reads each request and answers with `reply`, or hangs up without an answer
  # when there is none. Returns its port; teardown closes it.
  def local_server(reply = nil)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = server.accept
        begin
          client.readpartial(4096)
          client.write(reply) if reply
        rescue EOFError, SystemCallError
          nil
        ensure
          client.close
        end
      end
    rescue IOError, SystemCallError
      nil # the server was closed in teardown
    end
    @servers << [server, thread]
    server.addr[1]
  end

  def chain_of(url)
    client = Honeymaker::Client.new
    client.send(:with_rescue) { client.send(:build_client_connection, url).get("/") }.data[:error_chain]
  end
end
