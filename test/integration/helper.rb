# frozen_string_literal: true

# The integration tests run against a real Centrifugo, set up as
# testdata/centrifugo.json says - history and presence for channels without a
# namespace, a "map" and a "poll" namespace, HMAC and Ed25519 client tokens,
# the unidirectional HTTP stream, the connect and refresh proxies:
#
#   docker compose -f testdata/centrifugo-pro.compose.yml up -d --wait   # Centrifugo PRO
#   bundle exec rake test:integration
#
# RUBYCENT_TEST_ADDR and RUBYCENT_TEST_API_KEY default to
# http://localhost:8100/api and "api_key". The PRO tests skip against
# Centrifugo OSS, unless RUBYCENT_TEST_PRO is set: then a server which is not
# PRO fails them.

require "test_helper"

class IntegrationTest < Minitest::Test
  ADDR = ENV.fetch("RUBYCENT_TEST_ADDR", "http://localhost:8100/api")
  API_KEY = ENV.fetch("RUBYCENT_TEST_API_KEY", "api_key")

  def setup
    @client = Cent::Client.new(api_endpoint: ADDR, api_key: API_KEY)
    begin
      @client.info
    rescue Cent::Error => e
      raise "Centrifugo not reachable at #{ADDR}: #{e.message}"
    end
    @servers = []
    @streams = []
  end

  def teardown
    @streams.each(&:close)
    @servers.each(&:close)
    @client.close
  end

  attr_reader :client

  # The client, when the server is Centrifugo PRO.
  def pro
    client.connections(user: "nobody")
    client
  rescue Cent::Error => e
    flunk "RUBYCENT_TEST_PRO is set, but the server is not Centrifugo PRO: #{e.message}" if ENV["RUBYCENT_TEST_PRO"]
    skip "not Centrifugo PRO: #{e.message}"
  end

  def unique(prefix = "")
    "#{prefix}rubycent-#{name}-#{::Process.clock_gettime(::Process::CLOCK_REALTIME, :nanosecond).to_s(16)}"
  end

  # Serves Rack apps by path on all interfaces at +port+, where Centrifugo
  # reaches them as host.docker.internal from its container.
  def serve(port, routes)
    @servers << TestServer.new(host: "0.0.0.0", port:) do |line, headers, body, sock|
      method, target = line.split
      path, query = target.split("?", 2)
      app = routes[path]
      next TestServer.respond(sock, 404, "") unless app

      env = { "REQUEST_METHOD" => method, "PATH_INFO" => path, "QUERY_STRING" => query.to_s,
              "rack.input" => StringIO.new(body), "CONTENT_TYPE" => headers["content-type"] }
      headers.each { |k, v| env["HTTP_#{k.upcase.tr("-", "_")}"] = v }
      status, resp_headers, resp_body = app.call(env)
      TestServer.respond(sock, status, resp_body.join, resp_headers)
    end
  end

  # A client connection over Centrifugo's unidirectional HTTP stream.
  class Stream
    def initialize(body)
      uri = URI("#{ADDR.delete_suffix("/api")}/connection/uni_http_stream")
      @messages = Queue.new
      @thread = Thread.new do
        Net::HTTP.start(uri.host, uri.port, read_timeout: 30) do |http|
          req = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
          req.body = JSON.generate(body)
          http.request(req) do |res|
            buf = +""
            res.read_body do |chunk|
              buf << chunk
              while (i = buf.index("\n"))
                line = buf.slice!(0..i).strip
                @messages << JSON.parse(line) unless line.empty? || line == "{}"
              end
            end
          end
        end
      rescue IOError, SystemCallError, Net::ReadTimeout
        nil
      ensure
        @messages << :closed
      end
    end

    # The next message, nil once the connection is closed; pings skipped.
    def next(timeout: 15)
      msg = @messages.pop(timeout:)
      raise "no message in #{timeout}s" if msg.nil?

      msg == :closed ? nil : msg
    end

    def drain = (nil while self.next)

    def close = @thread.kill
  end

  def stream(body)
    s = Stream.new(body)
    @streams << s
    s
  end
end
