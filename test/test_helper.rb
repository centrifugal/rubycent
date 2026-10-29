# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "cent"
require "minitest/autorun"
require "socket"
require "stringio"

# Threads of the tests raise what the tests expect: their join or value
# raises it again.
Thread.report_on_exception = false

# A fake Centrifugo for the unit tests, behind the client's http_client hook:
# it answers each API method with what its handler returns - a result Hash
# (wrapped as {"result": ...}), an ApiError (as {"error": ...}), or
# [status, headers, body] as it is. Batches are answered command by command.
class Fake
  ENDPOINT = "http://centrifugo.test/api"

  Request = Data.define(:url, :headers, :body, :timeout) do
    def method_name = url.split("/").last
    def json = JSON.parse(body)
  end

  attr_reader :requests

  def initialize
    @handlers = {}
    @requests = []
    @lock = Mutex.new
  end

  def on(method, value = nil, &block)
    @handlers[method] = block || ->(_m, _b) { value }
  end

  def bodies(method = nil) = requests.select { method.nil? || it.method_name == method }.map(&:json)

  def call(url, headers, body, timeout)
    req = Request.new(url:, headers:, body:, timeout:)
    @lock.synchronize { @requests << req }
    method = req.method_name
    payload = JSON.parse(body, max_nesting: false)
    if method == "batch" && !@handlers.key?("batch")
      replies = payload["commands"].map do |cmd|
        m, b = cmd.first
        reply(m, answer(m, b))
      end
      return [200, {}, JSON.generate({ "replies" => replies })]
    end
    out = answer(method, payload)
    return out if out.is_a?(Array)

    [200, {}, JSON.generate(envelope(out))]
  end

  def client(**) = Cent::Client.new(api_endpoint: ENDPOINT, api_key: "key", http_client: self, **)

  # A plausible success for each method.
  def self.default_result(method, body)
    case method
    when "publish" then { "offset" => 1, "epoch" => "e1" }
    when "broadcast"
      responses = body["channels"].map do |ch|
        case ch
        when /\Abad:/ then { "error" => { "code" => 102, "message" => "unknown channel" } }
        when /\Afull:/ then { "error" => { "code" => 108, "message" => "not available" } }
        when /\Aflaky:/ then { "error" => { "code" => 100, "message" => "internal server error", "temporary" => true } }
        else { "result" => { "offset" => 1, "epoch" => "e1" } }
        end
      end
      { "responses" => responses }
    else {}
    end
  end

  private

  def answer(method, body)
    h = @handlers[method]
    h ? h.call(method, body) : Fake.default_result(method, body)
  end

  def envelope(out)
    return { "result" => out } unless out.is_a?(Cent::ApiError)

    e = { "code" => out.code, "message" => out.server_message }
    e["temporary"] = true if out.temporary?
    { "error" => e }
  end

  def reply(method, out)
    env = envelope(out)
    env.key?("error") ? env : { method => env["result"] }
  end
end

# A real HTTP/1.1 server on localhost, for the tests of the Net::HTTP
# transport: each request is answered by the block, given the request line,
# the headers and the body, and the socket to write the response to.
class TestServer
  attr_reader :port, :connections, :closed

  def initialize(host: "127.0.0.1", port: 0, &handler)
    @server = TCPServer.new(host, port)
    @port = @server.addr[1]
    @handler = handler
    @connections = 0
    @closed = 0
    @threads = []
    @accept = Thread.new { accept_loop }
  end

  def url = "http://127.0.0.1:#{port}/api"

  def close
    @server.close
    @accept.kill
    @threads.each(&:kill)
  end

  def self.respond(sock, status, body, headers = {})
    head = "HTTP/1.1 #{status} X\r\nContent-Length: #{body.bytesize}\r\n"
    headers.each { |k, v| head << "#{k}: #{v}\r\n" }
    sock.write("#{head}\r\n#{body}")
  end

  private

  def accept_loop
    loop do
      sock = @server.accept
      @connections += 1
      @threads << Thread.new(sock) { serve(it) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def serve(sock)
    loop do
      line = sock.gets or break
      headers = {}
      while (h = sock.gets) && h != "\r\n"
        k, v = h.split(":", 2)
        headers[k.downcase] = v.strip
      end
      body = sock.read(headers.fetch("content-length", "0").to_i)
      @handler.call(line, headers, body, sock)
    end
  rescue IOError, SystemCallError
    nil
  ensure
    @closed += 1
    sock.close unless sock.closed?
  end
end
