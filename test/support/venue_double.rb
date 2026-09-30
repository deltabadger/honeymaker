# frozen_string_literal: true

require "socket"

# Plain-HTTP local venue: scripted replies, recorded requests. Both backends talk to it through
# the same legacy Faraday connection, one after the other, so URLs in messages are equal.
class VenueDouble
  Request = Struct.new(:method, :target, :headers, :body, keyword_init: true)

  attr_reader :port, :requests

  def initialize(replies)
    reset!(replies)
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.addr[1]
    @thread = Thread.new { loop { serve(@tcp.accept) } }
  end

  def reset!(replies)
    @replies = replies.dup
    @requests = []
  end

  def url = "http://127.0.0.1:#{port}"

  def close
    @thread.kill
    @tcp.close
  end

  private

  def serve(sock)
    Thread.new do
      loop do
        req = read_request(sock) or break
        @requests << req
        status, headers, body = @replies.length > 1 ? @replies.shift : @replies.first
        body = body.to_s.b
        h = { "content-length" => body.bytesize.to_s }.merge(headers)
        sock.write "HTTP/1.1 #{status} X\r\n#{h.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n#{body}"
      end
    rescue StandardError
      nil
    ensure
      sock.close rescue nil
    end
  end

  def read_request(io)
    head = +""
    head << io.readpartial(4096) until head.include?("\r\n\r\n")
    line, *hdrs = head.split("\r\n\r\n", 2).first.split("\r\n")
    headers = hdrs.to_h { |h| k, v = h.split(": ", 2); [k.downcase, v] }
    body = head.split("\r\n\r\n", 2)[1].to_s.b
    body << io.readpartial(4096) while body.bytesize < headers["content-length"].to_i
    method, target, = line.split(" ")
    Request.new(method: method, target: target, headers: headers, body: body)
  rescue EOFError, IOError
    nil
  end
end

# HTTP proxy double: records the first request line of each proxied connection and forwards the
# bytes to 127.0.0.1:<upstream_port> (absolute-form for http targets, as Net::HTTP sends them).
class ProxyDouble
  attr_reader :port, :lines

  def initialize(upstream_port)
    @lines = []
    @tcp = TCPServer.new("127.0.0.1", 0)
    @port = @tcp.addr[1]
    @thread = Thread.new do
      loop do
        s = @tcp.accept
        Thread.new do
          head = +""
          head << s.readpartial(4096) until head.include?("\r\n\r\n")
          @lines << head.lines.first
          up = TCPSocket.new("127.0.0.1", upstream_port)
          up.write(head)
          t = Thread.new { IO.copy_stream(s, up) rescue nil }
          IO.copy_stream(up, s) rescue nil
          t.join(1)
        rescue StandardError
          nil
        ensure
          s.close rescue nil
        end
      end
    end
  end

  def url = "http://127.0.0.1:#{port}"

  def close
    @thread.kill
    @tcp.close
  end
end
