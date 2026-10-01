# frozen_string_literal: true

# Ruby-vs-Rust transport parity. Each legacy transport mode (spec §4) runs against the gem's own
# Faraday transport (Honeymaker::Clients::Kraken) and against honeymaker-client (examples/probe),
# each on a fresh copy of the same local double. Compared: the outcome class deltabadger derives
# (see `oracle`), rejection/complete HTTP error strings, success values, and signed wire requests.
# One mode mismatch (both calls) is expected and asserted: a proxy that never answers CONNECT (Ruling R2). The
# plan's "Divergences from the gem" section lists every other difference; none shows up as a row.
#   bundle exec ruby -Ilib script/parity/kraken_transport.rb
require "honeymaker"
require "json"
require "open3"
require "openssl"
require "rbconfig"
require "socket"
require "stringio"
require "tmpdir"
require "timeout"
require "zlib"

ROOT = File.expand_path("../..", __dir__)

def issue(dir, name)
  ca_key = OpenSSL::PKey::EC.generate("prime256v1")
  ca = OpenSSL::X509::Certificate.new
  ca.version = 2
  ca.serial = rand(1..(2**31))
  ca.subject = ca.issuer = OpenSSL::X509::Name.parse("/CN=parity-#{name}-ca")
  ca.public_key = ca_key
  ca.not_before = Time.now - 60
  ca.not_after = Time.now + 3600
  ef = OpenSSL::X509::ExtensionFactory.new(ca, ca)
  ca.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
  ca.add_extension(ef.create_extension("keyUsage", "keyCertSign,cRLSign", true))
  ca.sign(ca_key, OpenSSL::Digest.new("SHA256"))
  key = OpenSSL::PKey::EC.generate("prime256v1")
  leaf = OpenSSL::X509::Certificate.new
  leaf.version = 2
  leaf.serial = rand(1..(2**31))
  leaf.subject = OpenSSL::X509::Name.parse("/CN=localhost")
  leaf.issuer = ca.subject
  leaf.public_key = key
  leaf.not_before = ca.not_before
  leaf.not_after = ca.not_after
  ef = OpenSSL::X509::ExtensionFactory.new(ca, leaf)
  leaf.add_extension(ef.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1"))
  leaf.add_extension(ef.create_extension("extendedKeyUsage", "serverAuth"))
  leaf.sign(ca_key, OpenSSL::Digest.new("SHA256"))
  File.write(File.join(dir, "#{name}_ca.pem"), ca.to_pem)
  File.write(File.join(dir, "#{name}_leaf.pem"), leaf.to_pem)
  File.write(File.join(dir, "#{name}_key.pem"), key.to_pem)
end

# Trust and the resolver double must be installed before Ruby/OpenSSL starts. The parent
# owns the temporary PKI/library and removes them even if the child fails. Clear ambient proxies.
unless ENV["HM_PARITY_DIR"]
  system("cargo", "build", "--locked", "--quiet", "-p", "honeymaker-client", "--example", "probe",
         chdir: ROOT, exception: true)
  Dir.mktmpdir("hm-parity") do |dir|
    issue(dir, "trusted")
    issue(dir, "untrusted")
    library = File.join(dir, "resolve.so")
    darwin = RUBY_PLATFORM.include?("darwin")
    system("cc", "-Wall", "-Wextra", "-Werror", darwin ? "-dynamiclib" : "-shared", "-fPIC",
           File.join(__dir__, "resolve.c"), "-o", library, exception: true)
    env = %w[http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY].to_h { |k| [k, nil] }
    env.merge!("HM_PARITY_DIR" => dir, "SSL_CERT_FILE" => File.join(dir, "trusted_ca.pem"),
               "SSL_CERT_DIR" => dir, darwin ? "DYLD_INSERT_LIBRARIES" : "LD_PRELOAD" => library)
    exit(system(env, RbConfig.ruby, "-I#{ROOT}/lib", __FILE__, *ARGV) ? 0 : 1)
  end
end
DIR = ENV.fetch("HM_PARITY_DIR")
$stdout.sync = true

def ctx(name)
  OpenSSL::SSL::SSLContext.new.tap do |c|
    c.cert = OpenSSL::X509::Certificate.new(File.read(File.join(DIR, "#{name}_leaf.pem")))
    c.key = OpenSSL::PKey.read(File.read(File.join(DIR, "#{name}_key.pem")))
  end
end
TRUSTED = ctx("trusted")
UNTRUSTED = ctx("untrusted")

PROBE = File.join(ROOT, "target/debug/examples/probe")

Honeymaker::Client.send(:remove_const, :OPTIONS)
Honeymaker::Client.const_set(:OPTIONS, { request: { open_timeout: 1, read_timeout: 1.5, write_timeout: 2 } }.freeze)

SECRET = Base64.strict_encode64("test_secret_key_1234567890123456")
NONCE = 1_727_000_000_000_001
ORDER = { ordertype: "market", type: "buy", volume: "0.0012", pair: "XBTEUR", oflags: ["viqc"],
          cl_ord_id: "6f1c1a52-7c8e-4d0e-9a57-0b6f0f1d2e3a", deadline: "2026-09-30T12:00:10.000Z" }.freeze
RUST_ORDER = { pair: "XBTEUR", kind: "market", volume: "0.0012", quote_volume: true,
               cl_ord_id: ORDER[:cl_ord_id], deadline: ORDER[:deadline] }.freeze
TICKER = '{"error":[],"result":{"XXBTZEUR":{"a":["50000.2","1","1.000"],"b":["49990.1","1","1.000"],"c":["49995.3","0.001"]}}}'
ADDED = '{"error":[],"result":{"descr":{"order":"buy"},"txid":["OTX-1"]}}'

# --- doubles (as in the 2026-09-30 capture) ---
# Every fixture is disposed before the next one. Unexpected server errors fail the row.
class Doubles
  attr_reader :requests, :connects, :errors

  def initialize
    @sockets, @threads, @requests, @connects, @errors = [], [], [], [], []
  end

  def socket(s)
    @sockets << s
    s
  end

  def thread(&block)
    worker = Thread.new do
      block.call
    rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE, OpenSSL::SSL::SSLError
      # Clients intentionally abort TLS and close timed-out streams.
    rescue StandardError => e
      @errors << e
    end
    @threads << worker
    worker
  end

  def close
    @threads.each(&:kill)
    @threads.each(&:join)
    @sockets.reverse_each { |s| s.close rescue nil }
  end
end

Req = Struct.new(:line, :accept_encoding, :body, :api_key, :api_sign)

def read_request(io)
  buf = +""
  buf << io.readpartial(4096) until buf.include?("\r\n\r\n")
  head, body = buf.split("\r\n\r\n", 2)
  body = body.to_s
  len = head[/content-length: (\d+)/i, 1].to_i
  body << io.readpartial(4096) while body.bytesize < len
  Req.new(head.lines.first.strip, head[/^accept-encoding: ([^\r]*)/i, 1], body,
          head[/^api-key: ([^\r]*)/i, 1], head[/^api-sign: ([^\r]*)/i, 1])
rescue EOFError, IOError
  nil
end

def server(tls: nil, &handler)
  tcp = @doubles.socket(TCPServer.new("127.0.0.1", 0))
  seen = @doubles.requests
  scope = @doubles
  scope.thread do
    loop do
      sock = scope.socket(tcp.accept)
      scope.thread do
        io = if tls
               scope.socket(OpenSSL::SSL::SSLSocket.new(sock, tls)).tap { |s| s.sync_close = true; s.accept }
             else
               sock
             end
        handler.call(io, sock, seen)
      ensure
        io&.close rescue nil
        sock.close rescue nil
      end
    end
  end
  [tcp.addr[1], seen]
end

def respond(io, status, ctype, body, encoding: nil)
  io.write "HTTP/1.1 #{status} X\r\n#{ctype ? "Content-Type: #{ctype}\r\n" : ''}" \
           "#{encoding ? "Content-Encoding: #{encoding}\r\n" : ''}Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
  io.write body
  io.close
end

def gz(text)
  z = StringIO.new
  g = Zlib::GzipWriter.new(z)
  g.mtime = 0
  g.write(text)
  g.close
  z.string
end

def encoded(status, body, encoding) = after_request { |io, _| respond(io, status, "application/json", body, encoding: encoding) }

def after_request(&act) = ->(io, sock, seen) { (r = read_request(io)) and seen << r; act.call(io, sock) }
def answering(status, ctype, body) = after_request { |io, _| respond(io, status, ctype, body) }
def closed_port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }

def proxy(&connect)
  scope = @doubles
  server do |io, sock, _|
    request = read_request(io)
    raise "missing CONNECT" unless request&.line&.start_with?("CONNECT ")
    scope.connects << request
    connect.call(io, sock)
  end.first
end

def tunnel_to(port)
  scope = @doubles
  proxy do |io, _|
    up = scope.socket(TCPSocket.new("127.0.0.1", port))
    io.write "HTTP/1.1 200 Connection established\r\n\r\n"
    forward = scope.thread { IO.copy_stream(io, up); up.close_write rescue nil }
    begin
      IO.copy_stream(up, io)
    ensure
      forward.kill
      forward.join
    end
  end
end

# A bound, non-listening socket black-holes SYNs on macOS. Linux instead needs a full
# accept queue. Retain all sockets until the row finishes; never rely on an unroutable host.
def stalled_tcp
  sock = @doubles.socket(Socket.new(:INET, :STREAM))
  sock.bind(Socket.sockaddr_in(0, "127.0.0.1"))
  port = sock.local_address.ip_port
  unless RUBY_PLATFORM.include?("darwin")
    sock.listen(0)
    loop do
      filler = @doubles.socket(Socket.new(:INET, :STREAM))
      result = filler.connect_nonblock(Socket.sockaddr_in(port, "127.0.0.1"), exception: false)
      break if result == :wait_writable && !IO.select(nil, [filler], nil, 0.1)
    end
  end
  ["https://127.0.0.1:#{port}", nil, []]
end

def tls(handler) = server(tls: TRUSTED, &handler).then { |port, seen| ["https://127.0.0.1:#{port}", nil, seen] }
def plain(handler) = server(&handler).then { |port, seen| ["http://127.0.0.1:#{port}", nil, seen] }
def via(proxy_port) = ["https://127.0.0.1:443", "http://127.0.0.1:#{proxy_port}", []]

# Repeated header fields are joined with ", " by Net::HTTP. Use both orders so the
# result cannot accidentally pass with a first-header-only or last-header-only parser.
def raw_answer(headers, body, framing: :length)
  after_request do |io, _|
    tail = case framing
           when :length then "Content-Length: #{body.bytesize}\r\n"
           when :chunked then "Transfer-Encoding: chunked\r\n"
           when :close then ""
           end
    io.write "HTTP/1.1 200 OK\r\n#{headers}#{tail}Connection: close\r\n\r\n"
    io.write(framing == :chunked ? "#{body.bytesize.to_s(16)}\r\n#{body}\r\n0\r\n\r\n".b : body)
    io.close
  end
end

def good_body(call) = call == :add_order ? ADDED : TICKER

def truncated_gzip(framing)
  tls(raw_answer("Content-Type: application/json\r\nContent-Encoding: gzip\r\n",
                 gz('{"a":1}').byteslice(0, 12), framing: framing))
end

MODES = {
  refused: ->(_) { ["https://127.0.0.1:#{closed_port}", nil, []] },
  dns: ->(_) { ["https://honeymaker-nonexistent.invalid", nil, []] },
  tcp_timeout: ->(_) { stalled_tcp },
  tls_not_tls: ->(_) { ["https://127.0.0.1:#{server { |io, _, _| sleep 0.2; io.write("garbage\r\n\r\n"); io.close }.first}", nil, []] },
  tls_untrusted: ->(_) { ["https://127.0.0.1:#{server(tls: UNTRUSTED) { |io, _, _| io.close }.first}", nil, []] },
  tls_handshake_hang: ->(_) { ["https://127.0.0.1:#{server { |io, _, _| sleep 3; io.close }.first}", nil, []] },
  read_timeout: ->(_) { tls(after_request { |io, _| sleep 3; io.close }) },
  eof_after_request: ->(_) { plain(after_request { |io, _| io.close }) },
  tls_abrupt_close: ->(_) { tls(after_request { |_, sock| sock.close }) },
  rst_after_request: ->(_) { plain(after_request { |_, sock| sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii")); sock.close }) },
  partial_body: ->(_) { tls(after_request { |io, _| io.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 50\r\n\r\n{\"a\""; io.close }) },
  http_500_json: ->(_) { tls(answering(500, "application/json", '{"error":["EService:Unavailable"]}')) },
  http_500_empty: ->(_) { tls(answering(500, "text/plain", "")) },
  http_404_html: ->(_) { tls(answering(404, "text/html", "<h1>nf</h1> é")) },
  http_429_no_ctype: ->(_) { tls(answering(429, nil, "no")) },
  ok_invalid_json: ->(_) { tls(answering(200, "application/json", "{not json")) },
  ok_duplicate_keys: ->(_) { tls(answering(200, "application/json", '{"error":[],"result":{"txid":["A"],"txid":["B"]}}')) },
  ok_html: ->(_) { tls(answering(200, "text/html", "<p>maintenance</p>")) },
  ok_blank: ->(_) { tls(answering(200, "application/json", "  \n ")) },
  ok_top_array: ->(_) { tls(answering(200, "application/json", '[1,2.5,"x"]')) },
  venue_refusal: ->(_) { tls(answering(200, "application/json", '{"error":["EOrder:Insufficient funds"]}')) },
  venue_no_txid: ->(_) { tls(answering(200, "application/json", '{"error":[],"result":{"descr":{"order":"buy"}}}')) },
  venue_transient_refusal: ->(_) { tls(answering(200, "application/json", '{"error":["EService:Busy"]}')) },
  answered: ->(call) { tls(answering(200, "application/json", call == :add_order ? ADDED : TICKER)) },
  compressed_ok: ->(call) { tls(encoded(200, gz(call == :add_order ? ADDED : TICKER), "gzip")) },
  compressed_deflate_ok: ->(call) { tls(encoded(200, Zlib::Deflate.deflate(call == :add_order ? ADDED : TICKER), "deflate")) },
  compressed_refusal: ->(_) { tls(encoded(200, gz('{"error":["EOrder:Insufficient funds"]}'), "gzip")) },
  compressed_malformed: ->(_) { tls(encoded(200, "not gzip at all", "gzip")) },
  proxy_refused: ->(_) { via(closed_port) },
  proxy_connect_403: ->(_) { via(proxy { |io, _| io.write "HTTP/1.1 403 Filtered\r\nContent-Length: 0\r\n\r\n"; sleep 0.2; io.close }) },
  proxy_connect_500: ->(_) { via(proxy { |io, _| io.write "HTTP/1.1 500 Unable to connect\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nnope!"; sleep 0.2; io.close }) },
  proxy_connect_eof: ->(_) { via(proxy { |io, _| io.close }) },
  proxy_connect_hang: ->(_) { via(proxy { |io, _| sleep 3; io.close }) },
  proxy_tunnel_read_timeout: ->(_) {
    port, seen = server(tls: TRUSTED, &after_request { |io, _| sleep 3; io.close })
    ["https://localhost:#{port}", "http://127.0.0.1:#{tunnel_to(port)}", seen]
  },
  proxy_tunnel_ok: ->(call) {
    port, seen = server(tls: TRUSTED, &answering(200, "application/json", call == :add_order ? ADDED : TICKER))
    ["https://localhost:#{port}", "http://127.0.0.1:#{tunnel_to(port)}", seen]
  },
  address_fallback: ->(call) {
    port, seen = server(&answering(200, "application/json", good_body(call)))
    ["http://fallback.parity.invalid:#{port}", nil, seen]
  },
  gzip_truncated_length: ->(_) { truncated_gzip(:length) },
  gzip_truncated_chunked: ->(_) { truncated_gzip(:chunked) },
  gzip_truncated_close: ->(_) { truncated_gzip(:close) },
  repeated_type_json_first: ->(call) {
    tls(raw_answer("Content-Type: application/json\r\nContent-Type: text/plain\r\n", good_body(call)))
  },
  repeated_type_json_last: ->(call) {
    # Joined value is "text/plain, application/json", which still matches Faraday's /\bjson$/.
    tls(raw_answer("Content-Type: text/plain\r\nContent-Type: application/json\r\n", good_body(call)))
  },
  repeated_encoding: ->(call) {
    # The joined, unrecognized encoding passes plain JSON through. Taking either field
    # alone would instead attempt decompression and fail with Zlib::DataError.
    tls(raw_answer("Content-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Encoding: deflate\r\n",
                   good_body(call)))
  },
  json_invalid_utf8_string: ->(call) {
    body = good_body(call).b.sub('"error":[]', '"error":[],"ignored":"'.b + "\xff".b + '"')
    tls(answering(200, "application/json", body))
  },
  http_407_empty: ->(_) { tls(answering(407, nil, "")) },
  http_404_empty: ->(_) { tls(answering(404, nil, "")) }
}.freeze
EXPECTED_DIVERGENCE = { proxy_connect_hang: { legacy: [:ambiguous], rust: [:transient] } }.freeze

# Pin the mode as well as parity: two clients failing the same broken fixture must not pass.
EXPECTED = {
  refused: :transient, dns: :transient, tcp_timeout: :transient, tls_not_tls: :ambiguous,
  tls_untrusted: :ambiguous, tls_handshake_hang: :transient, read_timeout: :ambiguous,
  eof_after_request: :ambiguous, tls_abrupt_close: :ambiguous, rst_after_request: :ambiguous,
  partial_body: :ambiguous, http_500_json: :ambiguous, http_500_empty: :ambiguous,
  http_404_html: :rejected, http_429_no_ctype: :rejected, ok_invalid_json: :ambiguous,
  ok_duplicate_keys: :ambiguous, ok_html: :ambiguous, ok_blank: :ambiguous, ok_top_array: :ambiguous,
  venue_refusal: :rejected, venue_no_txid: :ambiguous,
  venue_transient_refusal: { add_order: :ambiguous, prices: :rejected },
  answered: :ok, compressed_ok: :ok, compressed_deflate_ok: :ok, compressed_refusal: :rejected,
  compressed_malformed: :ambiguous, proxy_refused: :transient, proxy_connect_403: :transient,
  proxy_connect_500: :ambiguous, proxy_connect_eof: :ambiguous, proxy_connect_hang: :ambiguous,
  proxy_tunnel_read_timeout: :ambiguous, proxy_tunnel_ok: :ok, address_fallback: :ok,
  gzip_truncated_length: :ambiguous, gzip_truncated_chunked: :ambiguous, gzip_truncated_close: :ambiguous,
  repeated_type_json_first: :ambiguous, repeated_type_json_last: :ok, repeated_encoding: :ok,
  json_invalid_utf8_string: :ok, http_407_empty: :rejected, http_404_empty: :rejected
}.freeze
NO_REQUEST = %i[refused dns tcp_timeout tls_not_tls tls_untrusted tls_handshake_hang
                proxy_refused proxy_connect_403 proxy_connect_500 proxy_connect_eof proxy_connect_hang].freeze
raise "unclassified modes" unless EXPECTED.keys.sort == MODES.keys.sort

# deltabadger's Exchange#ambiguous_placement_error? without its text rules (the caller applies those
# to rejection strings), using Client.most_specific_cause and Client.pre_transmission?.
PRE = %w[Net::OpenTimeout SocketError Socket::ResolutionError Resolv::ResolvError Errno::ECONNREFUSED Errno::EHOSTUNREACH
         Errno::EHOSTDOWN Errno::ENETUNREACH Errno::ENETDOWN Errno::EADDRNOTAVAIL Net::HTTPClientException].freeze
PREFERRED = [/\ANet::(Open|Read)Timeout\z/, /\AErrno::/, /\A(SocketError|Socket::Resolution|Resolv::)/,
             /\A(EOFError|OpenSSL::SSL::SSLError|Net::HTTPClientException)\z/].freeze

def cause(chain)
  PREFERRED.each { |p| (m = chain.find { |n| n.match?(p) }) and return m }
  chain.first
end

def utf8(errors) = errors.map { |e| e.to_s.dup.force_encoding(Encoding::UTF_8) }

# The text rules of ambiguous_placement_error?, which the Rust client applies to AddOrder (R19).
PLACEMENT_SAFE = ["Timestamp for this request is outside of the recvWindow", "Timestamp for this request was"].freeze
TRANSIENT_TEXT = ["Net::ReadTimeout", "Net::OpenTimeout", "Faraday::TimeoutError", "Faraday::ConnectionFailed", "execution expired",
                  "Connection reset", "Errno::ECONNRESET", "connection refused", "Connection refused", "Errno::ECONNREFUSED",
                  "end of file reached", "unexpected eof while reading", "EGeneral:Internal error", "EAPI:Invalid nonce",
                  "EService:Unavailable", "EService:Busy", "EService:Deadline elapsed"].freeze

def oracle(call, r)
  if r.success?
    return r.data[:order_id].to_s.empty? ? [:ambiguous] : [:ok] if call == :add_order
    return [:ambiguous] unless r.data.is_a?(Hash) # Rails' dig_or_raise raises on anything else

    errors = r.data["error"]
    return errors.is_a?(Array) && errors.any? ? [:rejected, utf8(errors)] : [:ok]
  end
  data = r.data.is_a?(Hash) ? r.data : {}
  chain = data[:error_chain]
  if chain && !chain.empty?
    return [PRE.include?(cause(chain)) || r.errors.join(" ").match?(/connection refused/i) ? :transient : :ambiguous]
  end
  if call == :add_order
    text = r.errors.map(&:to_s)
    return [:rejected, utf8(r.errors)] if text.any? { |m| PLACEMENT_SAFE.any? { |p| m.include?(p) } }
    return [:ambiguous] if text.any? { |m| TRANSIENT_TEXT.any? { |p| m.include?(p) } }
  end
  return [:ambiguous] if data[:unreadable] || data[:client_error]

  status = data[:status].to_i
  return [:ambiguous] if status >= 500 || (200..299).cover?(status)
  return [:ambiguous] if call == :add_order && r.errors.any? { |e| e.to_s.match?(/\bHTTP 5\d\d\b/) }

  [:rejected, utf8(r.errors)]
end

def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def legacy(call, url, proxy)
  c = Honeymaker::Clients::Kraken.new(api_key: "key", api_secret: SECRET, proxy: proxy)
  c.define_singleton_method(:nonce) { NONCE }
  c.instance_variable_set(:@connection, c.send(:build_client_connection, url))
  started = clock
  r = call == :add_order ? c.add_order(**ORDER) : c.get_ticker_information(pair: "XBTEUR")
  [oracle(call, r), clock - started, r]
end

def probe(input)
  Open3.popen3(PROBE) do |stdin, stdout, stderr, wait|
    errors = Thread.new { stderr.read }
    begin
      out = Timeout.timeout(10) do
        stdin.write(JSON.generate(input))
        stdin.close
        stdout.read
      end
      raise "probe failed: #{errors.value}" unless wait.value.success?
      r = JSON.parse(out)
      raise "probe omitted elapsed time: #{r.inspect}" unless r["ms"].is_a?(Numeric) && r["ms"] >= 0
      r
    ensure
      Process.kill("KILL", wait.pid) if wait.alive?
      wait.join
      errors.join
    end
  end
end

def rust(call, url, proxy)
  input = { base_url: url, proxy: proxy, timeouts: [1, 1.5, 2], ca_pem: File.join(DIR, "trusted_ca.pem"),
            fixed_nonce: NONCE, api_key: "key", api_secret: SECRET,
            call: call == :add_order ? "add_order" : "prices", args: call == :add_order ? RUST_ORDER : { pair: "XBTEUR" } }
  r = probe(input)
  [[r["class"].to_sym, *(r["class"] == "rejected" ? [r["errors"]] : [])], r.fetch("ms") / 1000.0, r]
end

# Run each stack on a fresh copy, with a watchdog independent of transport timeouts.
def exercise(stack, build, call)
  @doubles = Doubles.new
  url, prox, = build.call(call)
  result = Timeout.timeout(12) { send(stack, call, url, prox) }
  @doubles.close
  raise "double errors: #{@doubles.errors.inspect}" unless @doubles.errors.empty?
  [*result, @doubles.requests.map(&:to_a), @doubles.connects.map(&:to_a), url]
ensure
  @doubles&.close
end

def check(condition, message)
  raise message unless condition
end

def compare_row(name, call, l, r)
  lo, ls, lr, lw, lc, lu = l
  ro, rs, rr, rw, rc, ru = r
  expected = EXPECTED.fetch(name)
  expected = expected.fetch(call) if expected.is_a?(Hash)
  check(lo.first == expected, "legacy class #{lo.inspect}, expected #{expected}: #{lr.inspect}")
  if (want = EXPECTED_DIVERGENCE[name])
    check(lo == want[:legacy] && ro == want[:rust], "CONNECT ruling: #{lo.inspect} / #{ro.inspect}")
    check(rs.between?(0.8, 2.5) && ls >= 2.5, "CONNECT timing: legacy=#{ls}, rust=#{rs}")
  else
    normalized = ->(outcome, url) { outcome.first == :rejected ? [:rejected, outcome.last.map { |m| m.gsub(url, "<double>") }] : outcome }
    check(normalized.call(lo, lu) == normalized.call(ro, ru), "outcomes: #{lo.inspect} / #{ro.inspect}; legacy=#{lr.inspect}; rust=#{rr.inspect}")
  end
  check(lw == rw, "wire: #{lw.inspect} / #{rw.inspect}")
  count = NO_REQUEST.include?(name) ? 0 : 1
  check(lw.size == count && rw.size == count, "expected #{count} requests, got #{lw.size}/#{rw.size}")
  if count == 1
    line = call == :add_order ? "POST /0/private/AddOrder HTTP/1.1" : "GET /0/public/Ticker?pair=XBTEUR HTTP/1.1"
    check(lw.first[0] == line, "wrong request line: #{lw.first[0]}")
    check(lw.first[1] == "gzip;q=1.0,deflate;q=0.6,identity;q=0.3", "wrong Accept-Encoding")
    check(call != :add_order || (lw.first[3] == "key" && !lw.first[4].to_s.empty?), "missing signing headers")
  end
  proxy_count = name.to_s.start_with?("proxy_") && name != :proxy_refused ? 1 : 0
  check(lc.size == proxy_count && rc.size == proxy_count, "CONNECT counts: #{lc.size}/#{rc.size}")
  if proxy_count == 1
    # A fresh double has a fresh port; compare each CONNECT to its own exact authority.
    [[lc, lu], [rc, ru]].each do |connects, url|
      uri = URI(url)
      check(connects.first[0] == "CONNECT #{uri.host}:#{uri.port} HTTP/1.1", "wrong CONNECT target")
      check(connects.first[2].empty?, "CONNECT unexpectedly has a body")
    end
  end
  if name == :tcp_timeout || name == :tls_handshake_hang
    check(ls.between?(0.8, 2.5) && rs.between?(0.8, 2.5), "not an open timeout: #{ls}/#{rs}")
    check(lr.data[:error_chain].include?("Net::OpenTimeout"), "legacy did not time out opening")
    prefix = name == :tcp_timeout ? "Failed to open TCP connection to " : "Net::OpenTimeout"
    check(rr["message"].start_with?(prefix), "Rust did not fail in the open phase: #{rr.inspect}")
  end
  if %i[read_timeout proxy_tunnel_read_timeout].include?(name)
    check(ls.between?(1.3, 2.5) && rs.between?(1.3, 2.5), "not a read timeout: #{ls}/#{rs}")
    check(lr.data[:error_chain].include?("Net::ReadTimeout") && rr["message"].include?("Net::ReadTimeout"), "wrong timeout phase")
  end
  # R14: status/rejection text is exact; low-level OS/OpenSSL diagnostics are version-specific.
  # partial_body is an incomplete transport read in hyper (EOF), while Net::HTTP hands
  # partial bytes to Faraday. R14 permits different transport diagnostics; the brief compares
  # its ambiguous class. Complete HTTP responses below retain exact status/parser error text.
  if lr.failure? && lr.data.is_a?(Hash) && lr.data[:status] && name != :partial_body
    ruby_text = utf8(lr.errors).first.gsub(lu, "<double>")
    rust_text = (rr["message"] || rr.fetch("errors").first).gsub(ru, "<double>")
    check(ruby_text == rust_text, "HTTP text: #{ruby_text.inspect} / #{rust_text.inspect}")
  end
  if %i[http_500_empty http_404_empty].include?(name)
    method = call == :add_order ? "POST" : "GET"
    check(lr.errors.first.include?(" for #{method} "), "fallback method must be uppercase")
  end
  if name == :http_407_empty
    check(lo == [:rejected, ['407 "Proxy Authentication Required"']], "wrong empty-407 fallback")
  end
  if name == :dns
    check(lr.data[:error_chain].any? { |c| c.match?(/Socket.*Error|Resolv/) }, "legacy did not fail resolution")
    check(rr["message"].include?("getaddrinfo"), "Rust did not fail resolution")
  end
  if name == :compressed_malformed
    check(lr.data == { client_error: true } && lr.errors.first.start_with?("Zlib::DataError:"), "missing Ruby DataError")
    check(rr["message"].start_with?("Zlib::DataError:"), "missing Rust DataError")
  end
  if %i[gzip_truncated_length gzip_truncated_chunked].include?(name)
    check(call == :add_order ? lr.data == { unreadable: true } : lr.success? && lr.data.nil?,
          "length/chunked gzip must produce an empty successful transport body")
    check(rr["message"] == Honeymaker::Clients::Kraken::UNREADABLE, "unexpected gzip result")
  end
  if name == :gzip_truncated_close
    check(lr.data == { client_error: true } && lr.errors.first.start_with?("Zlib::BufError:"), "missing Ruby BufError")
    check(rr["message"] == lr.errors.first, "BufError text differs")
  end
  if lo.first == :ok
    value = call == :add_order ? lr.data[:order_id] :
      lr.data.fetch("result").values.first.then { |t| { "bid" => t.fetch("b").first, "ask" => t.fetch("a").first, "last" => t.fetch("c").first } }
    check(value == rr.fetch("value"), "success values: #{value.inspect} / #{rr["value"].inspect}")
  end
end

# Exercise all seven probe dispatch branches and their JSON projections, including fields
# unused by the two-call transport matrix. This is a local protocol check for Task 12's consumer.
def probe_contract!
  raw_order = { "status" => "open", "vol" => "2", "vol_exec" => "1", "cost" => "3", "price" => "3",
                "cl_ord_id" => ORDER[:cl_ord_id], "descr" => { "ordertype" => "limit", "type" => "sell", "price" => "3" } }
  state = { "txid" => "OTX-1", "status" => "open", "price" => "3", "amount" => "2", "quote_amount" => nil,
            "amount_exec" => "1", "quote_amount_exec" => "3", "limit" => true, "sell" => true }
  trade = { "ordertxid" => "OTX-1", "vol" => "1", "cost" => "3", "fee" => "0", "type" => "sell", "ordertype" => "limit" }
  envelope = ->(r) { JSON.generate(error: [], result: r) }
  since = "2026-09-30T00:00:00Z"
  cases = [
    ["prices", { pair: "XBTEUR" }, TICKER, { "bid" => "49990.1", "ask" => "50000.2", "last" => "49995.3" }],
    ["add_order", RUST_ORDER, ADDED, "OTX-1"],
    ["add_order_validate", RUST_ORDER.merge(kind: "limit", price: "3"), envelope.call({}), true],
    ["orders", { txids: ["OTX-1"] }, envelope.call("OTX-1" => raw_order), [state]],
    ["order_by_client_id", { cl_ord_id: ORDER[:cl_ord_id], since: since }, envelope.call("open" => { "OTX-1" => raw_order }), state],
    ["fills_from_trades", { txids: ["OTX-1"], since: since }, envelope.call("trades" => { "T1" => trade }, "count" => 1),
     [state.merge("status" => "closed", "amount" => nil, "price" => "3.000000000000000000000000000000000")]],
    ["balance", { asset: "EUR" }, envelope.call("ZEUR" => { "balance" => "1000", "hold_trade" => "1" }), "999"]
  ]
  cases.each do |call, args, body, value|
    begin
      @doubles = Doubles.new
      url, = tls(answering(200, "application/json", body))
      r = probe(base_url: url, ca_pem: File.join(DIR, "trusted_ca.pem"), fixed_nonce: NONCE,
                api_key: "key", api_secret: SECRET, call: call, args: args)
      check(r["class"] == "ok" && r["value"] == value, "probe #{call}: #{r.inspect}, expected #{value.inspect}")
      check(@doubles.requests.size == 1, "probe #{call} must send exactly once")
      if call == "add_order_validate"
        form = URI.decode_www_form(@doubles.requests.first.body).to_h
        check(form["validate"] == "true" && form["ordertype"] == "limit" && form["price"] == "3", "probe limit/validate order")
      end
      check(@doubles.errors.empty?, "probe double errors: #{@doubles.errors.inspect}")
    ensure
      @doubles.close
    end
  end
  r = probe(base_url: "http://127.0.0.1", proxy: "socks5://127.0.0.1:1", call: "prices", args: { pair: "XBTEUR" })
  check(r["class"] == "config" && r["message"].is_a?(String), "probe config: #{r.inspect}")
  puts "8 probe contract checks passed (7 calls + config)"
end

failures = 0
rows = 0
unknown = ARGV - MODES.keys.map(&:to_s)
abort "Unknown modes: #{unknown.join(', ')}" unless unknown.empty?
puts "Ruby #{RUBY_VERSION}; #{MODES.size} modes available; local doubles only"
probe_contract!
MODES.each do |name, build|
  next if ARGV.any? && !ARGV.include?(name.to_s)
  %i[add_order prices].each do |call|
    next if call == :prices && name == :venue_no_txid

    rows += 1
    begin
      l = exercise(:legacy, build, call)
      r = exercise(:rust, build, call)
      compare_row(name, call, l, r)
      printf("%-32s %-10s legacy=%-12s rust=%-12s ok (%.3fs / %.3fs)\n", name, call, l[0].first, r[0].first, l[1], r[1])
    rescue StandardError => e
      failures += 1
      puts "#{name} #{call} FAIL #{e.full_message}"
    end
  end
end
abort "#{failures} of #{rows} rows differ" if failures.positive?
puts "#{rows} rows: all match (#{ARGV.empty? ? '1 expected divergence asserted: proxy_connect_hang' : 'selected modes'})"
