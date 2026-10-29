# frozen_string_literal: true

require "test_helper"
require "async"

# The default transport, Net::HTTP, against a real server.
class TransportTest < Minitest::Test
  def teardown
    @server&.close
    @client&.close
  end

  def serve(&)
    @server = TestServer.new(&)
    @client = Cent::Client.new(api_endpoint: @server.url, api_key: "key")
  end

  def ok(sock, body = '{"result":{}}') = TestServer.respond(sock, 200, body)

  def test_request_and_keep_alive
    seen = []
    serve do |line, headers, body, sock|
      seen << [line.split[0, 2], headers, body]
      ok(sock, '{"result":{"offset":7}}')
    end

    3.times { assert_equal 7, @client.publish(channel: "c", data: 1).offset }
    assert_equal 1, @server.connections
    line, headers, body = seen.first

    assert_equal ["POST", "/api/publish"], line
    assert_equal "key", headers["x-api-key"]
    assert_equal "application/json", headers["content-type"]
    assert_equal "rubycent/5", headers["user-agent"]
    assert_equal '{"channel":"c","data":1}', body
  end

  def test_concurrent_calls_use_their_own_connections
    gate = Queue.new
    serve do |_line, _headers, _body, sock|
      gate.pop
      ok(sock)
    end
    calls = Array.new(4) { Thread.new { @client.info } }
    sleep 0.01 until @server.connections == 4
    4.times { gate << true }
    calls.each(&:join)
    # Kept alive: the next calls reuse them.
    4.times { gate << true }
    4.times { @client.info }

    assert_equal 4, @server.connections
  end

  def test_redirect_is_not_followed
    requests = 0
    serve do |_line, _headers, _body, sock|
      requests += 1
      TestServer.respond(sock, 307, "", "Location" => "http://127.0.0.1:1/api/info")
    end
    err = assert_raises(Cent::HTTPError) { @client.info }
    assert_equal 307, err.status_code
    assert_equal 1, requests
  end

  def test_deadline_bounds_a_trickling_body
    serve do |_line, _headers, _body, sock|
      # The body a byte at a time: each read is quick, the whole is not.
      sock.write("HTTP/1.1 200 OK\r\nContent-Length: 40\r\n\r\n")
      40.times do
        sock.write(" ")
        sleep 0.05
      end
    end
    start = Cent::HTTP.now
    err = assert_raises(Cent::TimeoutError) { @client.info(timeout: 0.3) }
    assert_operator Cent::HTTP.now - start, :<, 1.0
    assert Cent.retryable?(err)
  end

  def test_deadline_bounds_a_silent_server
    serve { |*| sleep 5 }
    start = Cent::HTTP.now
    assert_raises(Cent::TimeoutError) { @client.info(timeout: 0.2) }
    assert_operator Cent::HTTP.now - start, :<, 1.0
  end

  def test_error_body_is_bounded_and_drained
    size = 10_000
    serve { |_line, _headers, _body, sock| TestServer.respond(sock, 500, "e" * size) }
    err = assert_raises(Cent::HTTPError) { @client.info }
    assert_equal "e" * 512, err.body
    assert_raises(Cent::HTTPError) { @client.info }
    # Drained, the connection was reused.
    assert_equal 1, @server.connections
    size = 1 << 20
    assert_raises(Cent::HTTPError) { @client.info }
    assert_raises(Cent::HTTPError) { @client.info }
    # Too much to drain: each is dropped, the next call opens another.
    assert_equal 2, @server.connections
    sleep 0.01 until @server.closed == 2
  end

  def test_large_reply_is_read_whole
    pubs = Array.new(2000) { |i| { "data" => { "i" => i, "pad" => "x" * 100 }, "offset" => i } }
    serve { |_line, _headers, _body, sock| ok(sock, JSON.generate({ "result" => { "publications" => pubs } })) }

    assert_equal 1999, @client.history(channel: "c").publications.last.offset
  end

  def test_a_connection_the_server_closed_is_replaced
    serve do |_line, _headers, _body, sock|
      ok(sock)
      sock.close
    end
    @client.info
    sleep 0.05
    @client.info

    assert_equal 2, @server.connections
  end

  def test_connection_refused_is_a_network_error
    port = TCPServer.open("127.0.0.1", 0) { it.addr[1] }
    client = Cent::Client.new(api_endpoint: "http://127.0.0.1:#{port}/api")
    err = assert_raises(Cent::NetworkError) { client.info }
    assert Cent.retryable?(err)
  end

  def test_not_http_is_a_decode_or_network_error
    serve { |_line, _headers, _body, sock| sock.write("garbage\r\n\r\n") }
    assert_raises(Cent::DecodeError) { @client.info }
  end

  def test_http_options_reach_net_http
    serve { |_line, _headers, _body, sock| ok(sock) }
    client = Cent::Client.new(api_endpoint: @server.url, http_options: { local_host: "127.0.0.1" })
    client.info
    client.close
  end

  def test_close_closes_idle_connections
    serve { |_line, _headers, _body, sock| ok(sock) }
    @client.info

    assert_equal 0, @server.closed
    @client.close
    sleep 0.01 until @server.closed == 1
  end

  # Under a fiber scheduler, calls in one thread wait together.
  def test_calls_under_a_fiber_scheduler_run_concurrently
    serve do |_line, _headers, _body, sock|
      sleep 0.3
      ok(sock, '{"result":{"offset":1}}')
    end
    start = Cent::HTTP.now
    results = Sync do
      Array.new(5) { |i| Async { @client.publish(channel: "c#{i}", data: i).offset } }.map(&:wait)
    end

    assert_equal [1] * 5, results
    assert_operator Cent::HTTP.now - start, :<, 1.0
  end

  # WebMock, which applications stub HTTP with in their tests, sees cent's
  # requests: cent makes its connections with whatever Net::HTTP is then.
  def test_webmock_sees_the_requests
    require "webmock"
    WebMock.enable!
    WebMock.disable_net_connect!
    WebMock::API.stub_request(:post, "http://centrifugo.test/api/publish")
                .to_return(status: 200, body: '{"result":{"offset":42}}')
    client = Cent::Client.new(api_endpoint: "http://centrifugo.test/api")

    assert_equal 42, client.publish(channel: "c", data: 1).offset
    assert_raises(WebMock::NetConnectNotAllowedError) { client.info }
  ensure
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
  end
end
