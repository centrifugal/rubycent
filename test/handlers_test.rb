# frozen_string_literal: true

require "test_helper"

class HandlersTest < Minitest::Test
  E = Cent::Endpoints
  P = Cent::Proxy

  def setup
    @errors = []
    @on_error = ->(req, err) { @errors << [req.method, err] }
  end

  def rack(handler, method, body = "", query: "", headers: {})
    env = { "REQUEST_METHOD" => method, "QUERY_STRING" => query, "PATH_INFO" => "/x",
            "rack.input" => StringIO.new(body), "CONTENT_TYPE" => "application/json" }
    headers.each { |k, v| env["HTTP_#{k.upcase.tr("-", "_")}"] = v }
    handler.call(env)
  end

  # Endpoints.

  def test_connection_token
    seen = nil
    h = E::ConnectionToken.new do |req|
      seen = req
      "tok"
    end
    status, headers, body = rack(h, "POST", "ignored", headers: { "Cookie" => "s=1", "X-Many" => "a" })

    assert_equal 200, status
    assert_equal({ "content-type" => "application/json", "cache-control" => "no-store" }, headers)
    assert_equal ['{"token":"tok"}'], body
    assert_equal "s=1", seen.headers["cookie"]
    assert_equal "POST", seen.method
    assert_equal "/x", seen.path
    assert_kind_of Hash, seen.raw
    assert_equal 200, h.handle("GET").status
    assert_equal([405, "GET, POST"], h.handle("PUT").to_a.then { [it[0], it[1]["allow"]] })
  end

  def test_unauthorized_is_403_and_not_an_error
    h = E::ConnectionToken.new(on_error: @on_error) { raise E::Unauthorized }

    assert_equal 403, h.handle("GET").status
    wrapped = E::ConnectionToken.new(on_error: @on_error) do
      raise E::Unauthorized
    rescue E::Unauthorized
      raise "wrapped"
    end

    assert_equal 403, wrapped.handle("GET").status
    assert_empty @errors
  end

  def test_other_errors_are_500_and_reported
    h = E::ConnectionToken.new(on_error: @on_error) { raise "db down" }

    assert_equal [500, "Internal Server Error"], h.handle("GET").to_a.values_at(0, 2)
    assert_equal([["GET", "db down"]], @errors.map { [it[0], it[1].message] })
    bad = E::ConnectionToken.new(on_error: @on_error) { 42 }

    assert_equal 500, bad.handle("GET").status
    assert_match(/returned Integer, not a token/, @errors.last[1].message)
  end

  def test_subscription_token
    h = E::SubscriptionToken.new(on_error: @on_error) { |channel, _req| "tok-#{channel}" }

    assert_equal '{"token":"tok-news"}', h.handle("POST", {}, '{"channel":"news"}').body
    assert_equal ['{"token":"tok-news"}'], rack(h, "GET", query: "channel=news&channel=other")[2]
    assert_equal 400, h.handle("POST", {}, "{}").status
    assert_equal 400, h.handle("POST", {}, '{"channel":1}').status
    assert_equal 400, h.handle("POST", {}, "[").status
    assert_equal 400, h.handle("GET").status
    assert_equal 4, @errors.size
  end

  def test_shared_poll_signature
    h = E::SharedPollSignature.new(on_error: @on_error) { |channel, keys, _req| [keys - ["secret"], "sig-#{channel}"] }
    resp = h.handle("POST", {}, '{"channel":"poll:p","keys":["a","secret"]}')

    assert_equal({ "signature" => "sig-poll:p", "keys" => ["a"] }, JSON.parse(resp.body))
    assert_equal({ "signature" => "sig-poll:p", "keys" => [] },
                 JSON.parse(h.handle("POST", {}, '{"channel":"poll:p"}').body))
    assert_equal 405, h.handle("GET").status
    rogue = E::SharedPollSignature.new(on_error: @on_error) { [["other"], "sig"] }

    assert_equal 500, rogue.handle("POST", {}, '{"channel":"c","keys":["a"]}').status
    assert_match(/did not ask for/, @errors.last[1].message)
  end

  def test_body_limit
    h = E::SubscriptionToken.new(on_error: @on_error) { "t" }

    assert_equal 400, h.handle("POST", {}, %({"channel":"#{"x" * (1 << 20)}"})).status
    assert_equal 400, rack(h, "POST", "x" * ((1 << 20) + 10))[0]
  end

  def test_jwks_endpoint
    key = Cent::Token::Key.ed25519(OpenSSL::PKey.generate_key("ED25519")).with_key_id("k")
    h = E::JWKS.new(key)
    resp = h.handle("GET")

    assert_equal({ "content-type" => "application/json", "cache-control" => "public, max-age=300" }, resp.headers)
    assert_equal(["k"], JSON.parse(resp.body)["keys"].map { it["kid"] })
    assert_equal "", h.handle("HEAD").body
    assert_equal 405, h.handle("POST").status
    assert_raises(Cent::Token::Error) { E::JWKS.new(Cent::Token::Key.hmac("s").with_key_id("h")) }
  end

  def test_a_block_is_required
    assert_raises(ArgumentError) { E::ConnectionToken.new }
    assert_raises(ArgumentError) { P::ConnectHandler.new }
    assert_raises(ArgumentError) { P::ConnectHandler.new(max_body: 0) { nil } }
  end

  # Proxy.

  def test_connect_proxy
    h = P::ConnectHandler.new(on_error: @on_error) do |req, http|
      assert_equal "ws", req.transport
      assert_equal({ "a" => 1 }, req.data)
      assert_equal "secret", http.headers["x-token"]
      P::ConnectResult.new(user: "42", channels: ["news"], info: { "name" => "Alice" })
    end
    resp = h.handle("POST", { "X-Token" => "secret" }, '{"client":"c1","transport":"ws","data":{"a":1}}')

    assert_equal 200, resp.status
    assert_equal({ "result" => { "user" => "42", "channels" => ["news"], "info" => { "name" => "Alice" } } },
                 JSON.parse(resp.body))
  end

  def test_result_as_a_hash_and_empty_result
    h = P::SubscribeHandler.new { { info: { "x" => 1 } } }

    assert_equal({ "result" => { "info" => { "x" => 1 } } }, JSON.parse(h.handle("POST", {}, "{}").body))
    empty = P::SubscribeHandler.new { {} }

    assert_equal({ "result" => {} }, JSON.parse(empty.handle("POST", {}, "{}").body))
  end

  def test_proxy_answers
    h = P::PublishHandler.new { raise P::ProxyError.new(1000, "no", temporary: true) }

    assert_equal({ "error" => { "code" => 1000, "message" => "no", "temporary" => true } },
                 JSON.parse(h.handle("POST", {}, "{}").body))
    h = P::RPCHandler.new { raise P::Disconnect.new(4500, "bye") }

    assert_equal({ "disconnect" => { "code" => 4500, "reason" => "bye" } }, JSON.parse(h.handle("POST", {}, "{}").body))
    h = P::RPCHandler.new do
      raise P::Disconnect.new(4500, "bye")
    rescue P::Disconnect
      raise ArgumentError, "wrapped"
    end

    assert_equal "disconnect", JSON.parse(h.handle("POST", {}, "{}").body).keys.first
    h = P::SharedPollRefreshHandler.new { raise P::ProxyError.new(1001, "later") }

    assert_equal "error", JSON.parse(h.handle("POST", {}, "{}").body).keys.first
  end

  def test_proxy_refusals
    [
      [P::RefreshHandler.new(on_error: @on_error) { raise P::ProxyError.new(1000, "no") }, "cannot answer with"],
      [P::SharedPollRefreshHandler.new(on_error: @on_error) do
        raise P::Disconnect.new(4000, "no")
      end, "cannot answer with"],
      [P::ConnectHandler.new(on_error: @on_error) { raise "boom" }, "boom"],
      [P::ConnectHandler.new(on_error: @on_error) { 42 }, "must be a Proxy::ConnectResult"],
      [P::ConnectHandler.new(on_error: @on_error) { { usr: "1" } }, "did you mean user?"],
      [P::ConnectHandler.new(on_error: @on_error) { { data: Float::NAN } }, "result.data is NaN"]
    ].each do |h, message|
      assert_equal 500, h.handle("POST", {}, "{}").status
      assert_includes @errors.last[1].message, message
    end
    h = P::ConnectHandler.new(on_error: @on_error) { flunk }

    assert_equal 400, h.handle("POST", {}, "{bad").status
    assert_equal 400, h.handle("POST", {}, '{"client":5}').status
    assert_equal 405, h.handle("GET").status
  end

  def test_proxy_payload_round_trip
    body = '{"channel":"c","data":{"e":{},"z":{"0":"a"},"f":1.0,"big":123456789012345678901234567890}}'
    h = P::PublishHandler.new { |req| { data: req.data } }

    assert_equal %({"result":{"data":#{JSON.parse(body)["data"].then { JSON.generate(it) }}}}),
                 h.handle("POST", {}, body).body
    assert_includes h.handle("POST", {}, body).body, '"f":1.0,"big":123456789012345678901234567890'
  end

  def test_proxy_binary_mode
    h = P::PublishHandler.new { |req| { b64data: req.b64data } }
    out = JSON.parse(h.handle("POST", {}, '{"channel":"c","b64data":"AAE=","encoding":"binary"}').body)

    assert_equal({ "result" => { "b64data" => "AAE=" } }, out)
  end

  def test_refresh_expired
    h = P::RefreshHandler.new { { expired: true } }

    assert_equal({ "result" => { "expired" => true } }, JSON.parse(h.handle("POST", {}, "{}").body))
  end

  def test_every_non_streaming_proxy_type_has_a_handler
    handlers = P.constants.map { P.const_get(it) }.select { it.is_a?(Class) && it < P::ProxyHandler }

    assert_equal 11, handlers.size
    handlers.each { assert_kind_of Class, it::SPEC[1] }
  end
end
