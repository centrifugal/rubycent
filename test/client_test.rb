# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  def setup
    @fake = Fake.new
    @client = @fake.client
  end

  # Calls.

  def test_publish
    res = @client.publish(channel: "news", data: { text: "hi" }, tags: { "k" => "v" }, skip_history: true)

    assert_equal Cent::PublishResult.new(offset: 1, epoch: "e1"), res
    req = @fake.requests.last

    assert_equal "#{Fake::ENDPOINT}/publish", req.url
    want = { "channel" => "news", "data" => { "text" => "hi" }, "skip_history" => true, "tags" => { "k" => "v" } }

    assert_equal want, req.json
    assert_equal "key", req.headers["X-API-Key"]
    assert_equal "application/json", req.headers["Content-Type"]
    assert_equal "rubycent/5", req.headers["User-Agent"]
  end

  def test_every_method_reaches_its_endpoint_with_its_result
    methods = Cent::ClientMethods.public_instance_methods(false) - %i[broadcast broadcast_with_retry]

    assert_operator methods.size, :>, 35
    methods.each do |m|
      args = m == :publish ? { channel: "c", data: 1 } : {}
      res = @client.public_send(m, **args)

      assert_equal "#{Fake::ENDPOINT}/#{m}", @fake.requests.last.url
      assert_equal "#{m.to_s.split("_").map(&:capitalize).join}Result", res.class.name.delete_prefix("Cent::"), m
    end
  end

  def test_client_batch_and_command_take_the_same_arguments
    params = lambda(&:parameters)
    Cent::ClientMethods.public_instance_methods(false).each do |m|
      next if m == :broadcast_with_retry

      fields = params.call(Cent::Client.instance_method(m))

      assert_equal %i[key timeout], fields.pop, m
      assert_equal fields, params.call(Cent::Batch.instance_method(m)), m
      assert_equal fields, params.call(Cent::Command.method(m)), m
      assert_empty(fields.to_h.except(:key), m)
    end
    retry_params = params.call(Cent::Client.instance_method(:broadcast_with_retry)).map(&:last)
    broadcast = params.call(Cent::Client.instance_method(:broadcast)).map(&:last)[0...-1]

    assert_equal broadcast, retry_params.first(broadcast.size)
    assert_equal %i[max_attempts attempt_timeout timeout on_attempt_error], retry_params.drop(broadcast.size)
  end

  def test_unknown_keyword_is_refused
    assert_raises(ArgumentError) { @client.publish(chanel: "x", data: 1) }
    assert_empty @fake.requests
  end

  def test_nested_message_as_a_hash_or_its_class
    @client.history(channel: "c", since: { offset: 5, epoch: "e" })
    @client.history(channel: "c", since: Cent::StreamPosition.new(offset: 5, epoch: "e"))
    a, b = @fake.bodies("history")

    assert_equal a, b
    assert_equal({ "offset" => 5, "epoch" => "e" }, a["since"])

    err = assert_raises(Cent::InvalidRequestError) { @client.history(channel: "c", since: { ofset: 5 }) }
    assert_equal "invalid history request: since.ofset is not a field of StreamPosition: did you mean offset?",
                 err.message
    err = assert_raises(Cent::InvalidRequestError) { @client.history(channel: "c", since: { "offset" => 5 }) }
    assert_match(/field names are Symbols - offset:/, err.message)
    err = assert_raises(Cent::InvalidRequestError) { @client.history(channel: "c", since: 5) }
    assert_match(/since must be a StreamPosition or a Hash of its fields, not an Integer/, err.message)
  end

  def test_field_types_are_checked
    {
      { channel: 1, data: 1 } => "channel must be a String, not an Integer, 1",
      { channel: "c", data: 1, skip_history: "yes" } => "skip_history must be true or false",
      { channel: "c", data: 1, version: 1.5 } => "version must be an Integer",
      { channel: "c", data: 1, tags: [] } => "tags must be a Hash",
      { channel: "c", data: 1, tags: { "k" => 1 } } => "tags[\"k\"] must be a String"
    }.each do |args, message|
      err = assert_raises(Cent::InvalidRequestError) { @client.publish(**args) }
      assert_includes err.message, message
    end
    assert_empty @fake.requests
  end

  def test_symbols_are_strings
    @client.publish(channel: :news, data: { status: :ok }, tags: { kind: :x })

    assert_equal({ "channel" => "news", "data" => { "status" => "ok" }, "tags" => { "kind" => "x" } },
                 @fake.bodies.last)
  end

  def test_zero_values_are_left_out
    @client.publish(channel: "c", data: 1, b64data: "", skip_history: false, version: 0, tags: {})

    assert_equal({ "channel" => "c", "data" => 1 }, @fake.bodies.last)
  end

  def test_bool_value_fields
    @client.subscribe(channel: "c", user: "u", override: { presence: false, join_leave: true })

    assert_equal({ "presence" => { "value" => false }, "join_leave" => { "value" => true } },
                 @fake.bodies.last["override"])
  end

  def test_empty_request_methods_take_no_argument
    @client.info

    assert_equal({}, @fake.bodies.last)
  end

  # Errors.

  def test_api_error_by_code
    { 100 => Cent::InternalError, 102 => Cent::UnknownChannelError, 104 => Cent::NotFoundError,
      107 => Cent::BadRequestError, 108 => Cent::NotAvailableError, 111 => Cent::TooManyRequestsError,
      112 => Cent::UnrecoverablePositionError, 113 => Cent::ConflictError, 999 => Cent::ApiError }.each do |code, klass|
      @fake.on("publish", Cent::ApiError.new(code, "m"))
      err = assert_raises(Cent::ApiError) { @client.publish(channel: "c", data: 1) }
      assert_instance_of klass, err
      assert_equal code, err.code
      assert_equal "m", err.server_message
      assert_equal "m (code #{code})", err.message
    end
  end

  def test_temporary_and_internal_errors_are_retryable
    assert Cent.retryable?(Cent::ApiError.new(103, temporary: true))
    assert Cent.retryable?(Cent::InternalError.new(100))
    refute Cent.retryable?(Cent::UnknownChannelError.new(102))
  end

  def test_http_errors
    @fake.on("publish", [503, { "Retry-After" => "5" }, "unavailable"])
    err = assert_raises(Cent::HTTPError) { @client.publish(channel: "c", data: 1) }
    assert_equal 503, err.status_code
    assert_equal "unavailable", err.body
    assert_equal "5", err.headers["retry-after"]
    assert Cent.retryable?(err)

    @fake.on("publish", [401, {}, ""])
    err = assert_raises(Cent::UnauthorizedError) { @client.publish(channel: "c", data: 1) }
    assert_match(/check the credentials/, err.message)
    refute Cent.retryable?(err)

    @fake.on("publish", [429, {}, ""])

    assert Cent.retryable?(assert_raises(Cent::HTTPError) { @client.publish(channel: "c", data: 1) })
    @fake.on("publish", [302, { "Location" => "https://x" }, ""])
    err = assert_raises(Cent::HTTPError) { @client.publish(channel: "c", data: 1) }
    assert_match(/a redirect, which cent does not follow/, err.message)
  end

  def test_404_hints
    @fake.on("publish", [404, {}, ""])

    assert_match(/is api_endpoint the API base URL/,
                 assert_raises(Cent::HTTPError) { @client.publish(channel: "c", data: 1) }.message)
    @fake.on("connections", [404, {}, ""])

    assert_match(/connections is a Centrifugo PRO method/,
                 assert_raises(Cent::HTTPError) { @client.connections }.message)
  end

  def test_error_body_is_bounded
    @fake.on("publish", [500, {}, "x" * 10_000])

    assert_equal 512, assert_raises(Cent::HTTPError) { @client.publish(channel: "c", data: 1) }.body.size
  end

  def test_transport_error_mode
    @fake.on("publish", [400, {}, '{"code":102,"message":"unknown channel"}'])
    err = assert_raises(Cent::UnknownChannelError) { @client.publish(channel: "c", data: 1) }
    assert_equal 102, err.code
    @fake.on("publish", [429, {}, '{"code":429,"message":"slow down"}'])

    assert_equal 429, assert_raises(Cent::HTTPError) { @client.publish(channel: "c", data: 1) }.status_code
    @fake.on("publish", [500, {}, '{"code":100,"message":"internal","temporary":true}'])

    assert_predicate assert_raises(Cent::InternalError) { @client.publish(channel: "c", data: 1) }, :temporary?
  end

  def test_decode_errors
    ["<html>", "[]", '{"result":[]}', '{"result":{"offset":"x"}}'].each do |body|
      @fake.on("publish", [200, {}, body])
      err = assert_raises(Cent::DecodeError) { @client.publish(channel: "c", data: 1) }
      refute Cent.retryable?(err)
    end
  end

  def test_unknown_fields_in_replies_are_ignored_and_missing_ones_zero
    @fake.on("publish", [200, {}, '{"result":{"offset":3,"new_field":1}}'])

    assert_equal Cent::PublishResult.new(offset: 3, epoch: ""), @client.publish(channel: "c", data: 1)
  end

  def test_timeout_and_network_errors_from_the_transport
    client = Cent::Client.new(api_endpoint: Fake::ENDPOINT, http_client: ->(*) { raise Net::ReadTimeout })

    assert Cent.retryable?(assert_raises(Cent::TimeoutError) { client.info })
    client = Cent::Client.new(api_endpoint: Fake::ENDPOINT, http_client: ->(*) { raise Errno::ECONNREFUSED })
    err = assert_raises(Cent::NetworkError) { client.info }
    assert Cent.retryable?(err)
    assert_instance_of Errno::ECONNREFUSED, err.cause
  end

  def test_call_timeout_reaches_the_transport_and_is_checked
    @client.info(timeout: 2.5)

    assert_in_delta 2.5, @fake.requests.last.timeout, 0.1
    assert_raises(Cent::InvalidRequestError) { @client.info(timeout: -1) }
    assert_raises(Cent::TimeoutError) { @client.info(timeout: 0) }
  end

  # Validation and payloads.

  def test_validation
    [
      [{ data: 1 }, "invalid publish request: channel is required"],
      [{ channel: "a" }, "invalid publish request: data or b64data is required"],
      [{ channel: "a", data: Float::NAN }, "data is NaN, which is not a JSON number"],
      [{ channel: "a", data: Float::INFINITY }, "data is Infinity, which is not a JSON number"],
      [{ channel: "a", data: { x: [1, Object.new] } }, "data.x[1] is a Object, which is not a JSON value"],
      [{ channel: "a", data: "\xFF".b }, "data is a binary (ASCII-8BIT) string"],
      [{ channel: "a", data: (+"\xFF").force_encoding("UTF-8") }, "data is not valid UTF-8"],
      [{ channel: "a", data: { 1 => "x" } }, "data has a Integer key, 1: JSON object keys are strings"],
      [{ channel: "a", data: JSON::Fragment.new("{bad") }, "data is a JSON::Fragment which is not valid JSON"],
      [{ channel: "a", data: JSON::Fragment.new("NaN") }, "is not valid JSON"],
      [{ channel: "a", data: Time.now }, "data is a Time, which is not a JSON value: convert it"]
    ].each do |args, message|
      err = assert_raises(Cent::InvalidRequestError) { @client.publish(**args) }
      assert_includes err.message, message
      refute Cent.retryable?(err)
    end
    [
      [{ data: 1 }, "invalid broadcast request: channels is required"],
      [{ channels: ["a"] }, "data or b64data is required"],
      [{ channels: ["a", ""], data: 1 }, "channels[1] is empty"]
    ].each do |args, message|
      assert_includes assert_raises(Cent::InvalidRequestError) { @client.broadcast(**args) }.message, message
    end
    assert_empty @fake.requests
    # Only those rules: a publication with b64data alone is Centrifugo's to judge.
    @client.publish(channel: "a", b64data: "AA==")

    assert_equal 1, @fake.requests.size
  end

  def test_cyclic_payload_is_refused
    a = []
    a << a

    assert_match(/nested too deeply, or contains itself/,
                 assert_raises(Cent::InvalidRequestError) { @client.publish(channel: "c", data: a) }.message)
  end

  def test_payloads_native_and_raw_send_the_same_value
    @client.publish(channel: "c", data: { "a" => [1, 2.5, nil, true] })
    @client.publish(channel: "c", data: JSON::Fragment.new('{"a":[1,2.5,null,true]}'))
    a, b = @fake.bodies

    assert_equal a, b
    # Raw JSON keeps its number text.
    @client.publish(channel: "c", data: JSON::Fragment.new('{"n":1.0e3,"big":12345678901234567890123}'))

    assert_includes @fake.requests.last.body, '"data":{"n":1.0e3,"big":12345678901234567890123}'
    # Also inside a value.
    @client.publish(channel: "c", data: { "doc" => JSON::Fragment.new("[1, 2]") })

    assert_includes @fake.requests.last.body, '"data":{"doc":[1, 2]}'
  end

  def test_a_string_is_a_json_string
    @client.publish(channel: "c", data: '{"a":1}')

    assert_equal '{"a":1}', @fake.bodies.last["data"]
  end

  def test_payload_round_trip
    reply = '{"result":{"publications":[{"data":{"e":{},"z":{"0":"a"},"f":1.0,"big":123456789012345678901234567890}}]}}'
    @fake.on("history", [200, {}, reply])
    pub = @client.history(channel: "c").publications.first

    assert_equal({ "e" => {}, "z" => { "0" => "a" }, "f" => 1.0, "big" => 123_456_789_012_345_678_901_234_567_890 },
                 pub.data)
    @client.publish(channel: "c", data: pub.data)

    assert_includes @fake.requests.last.body,
                    '"data":{"e":{},"z":{"0":"a"},"f":1.0,"big":123456789012345678901234567890}'
  end

  # Configuration.

  def test_invalid_config
    [
      [{}, "api_endpoint is required"],
      [{ api_endpoint: "http://a/api", api_endpoint_func: -> {} }, "not both"],
      [{ api_endpoint: "localhost:8000/api" }, "must be an absolute http:// or https:// URL"],
      [{ api_endpoint: "ftp://a/api" }, "must be an absolute http:// or https:// URL"],
      [{ api_endpoint: "http:///api" }, "has no host"],
      [{ api_endpoint: "http://a/api?x=1" }, "must not have a query"],
      [{ api_endpoint: "http://u:p@a/api" }, "credentials"],
      [{ api_endpoint: "http://a/api/publish" }, "ends with the method \"publish\""],
      [{ api_endpoint: "http://a/api", api_key: "k", bearer_token_func: -> { "t" } }, "not both"],
      [{ api_endpoint: "http://a/api", api_key: "k\n" }, "api_key must be printable ASCII"],
      [{ api_endpoint: "http://a/api", headers: { "X-API-Key" => "x" } }, "use api_key"],
      [{ api_endpoint: "http://a/api", headers: { "authorization" => "x" } }, "use bearer_token_func"],
      [{ api_endpoint: "http://a/api", headers: { "Content-Type" => "x" } }, "Content-Type"],
      [{ api_endpoint: "http://a/api", headers: { "Bad Name" => "x" } }, "not a valid HTTP header name"],
      [{ api_endpoint: "http://a/api", headers: { "X" => "a\r\nb" } }, "printable ASCII"],
      [{ api_endpoint: "http://a/api", headers: { "Host" => "" } }, "Host must not be empty"],
      [{ api_endpoint: "http://a/api", request_timeout: 0 }, "request_timeout must be a positive"],
      [{ api_endpoint: "http://a/api", http_options: { read_timeout: 1 } }, "read_timeout is cent's to set"],
      [{ api_endpoint: "http://a/api", http_options: { nope: 1 } }, "nope is not a Net::HTTP setting"],
      [{ api_endpoint: "http://a/api", http_client: 1 }, "http_client must respond to call"],
      [{ api_endpoint: "http://a/api", batch_context: -> {} }, "batch_context is for auto_batch"]
    ].each do |opts, message|
      err = assert_raises(Cent::InvalidConfigError, opts.inspect) { Cent::Client.new(**opts) }
      assert_includes err.message, message, opts.inspect
    end
  end

  def test_endpoint_is_normalized
    Cent::Client.new(api_endpoint: "HTTP://a:80/api//", http_client: @fake).info

    assert_equal "http://a/api/info", @fake.requests.last.url
  end

  def test_headers_and_user_agent
    client = Cent::Client.new(api_endpoint: Fake::ENDPOINT, http_client: @fake,
                              headers: { "X-Tenant" => "t1", "User-Agent" => "app/1" })
    client.info
    h = @fake.requests.last.headers

    assert_equal "t1", h["X-Tenant"]
    assert_equal "app/1", h["User-Agent"]
    refute h.key?("X-API-Key")
  end

  def test_endpoint_and_token_funcs
    endpoints = ["http://a/one", "http://b/two"]
    tokens = %w[t1 t2]
    client = Cent::Client.new(api_endpoint_func: -> { endpoints.shift }, bearer_token_func: -> { tokens.shift },
                              http_client: @fake)
    client.info
    client.info

    assert_equal ["http://a/one/info", "http://b/two/info"], @fake.requests.map(&:url)
    assert_equal(["Bearer t1", "Bearer t2"], @fake.requests.map { it.headers["Authorization"] })
  end

  def test_bad_token_or_endpoint_fails_before_sending
    ["", nil, "t\n", "тест"].each do |t|
      client = Cent::Client.new(api_endpoint: Fake::ENDPOINT, bearer_token_func: -> { t }, http_client: @fake)
      assert_raises(Cent::InvalidConfigError) { client.info }
    end
    client = Cent::Client.new(api_endpoint_func: -> { "http://a/api/info" }, http_client: @fake)

    assert_match(/api_endpoint_func/, assert_raises(Cent::InvalidConfigError) { client.info }.message)
    assert_empty @fake.requests
  end

  def test_on_request
    infos = []
    client = @fake.client(on_request: ->(i) { infos << i })
    client.publish(channel: "c", data: 1)
    @fake.on("publish", [500, {}, ""])
    assert_raises(Cent::HTTPError) { client.publish(channel: "c", data: 1) }
    b = client.new_batch
    b.publish(channel: "c", data: 1)
    b.publish(channel: "bad", data: 1)
    @fake.on("publish") { |_m, body| body["channel"] == "bad" ? Cent::ApiError.new(102) : {} }
    assert_raises(Cent::BatchFailedCommandsError) { b.send }

    assert_equal([["publish", 1, 0, 200, nil], ["publish", 1, 0, 500, Cent::HTTPError], ["batch", 2, 1, 200, nil]],
                 infos.map { [it.method, it.commands, it.failed, it.status_code, it.error&.class] })
    assert(infos.all? { it.duration >= 0 && it.auto_batch == false })
  end

  def test_on_request_sees_failures_before_the_network
    infos = []
    client = Cent::Client.new(api_endpoint_func: -> { raise IOError, "discovery" }, http_client: @fake,
                              on_request: ->(i) { infos << i })
    assert_raises(Cent::NetworkError) { client.info }
    assert_equal([["info", 0, Cent::NetworkError]], infos.map { [it.method, it.status_code, it.error.class] })
  end

  def test_close
    @client.close
    assert_raises(Cent::ClosedError) { @client.info }
    assert_raises(Cent::ClosedError) { @client.new_batch.send }
    @client.close # again
  end

  def test_close_waits_for_calls_in_progress
    gate = Queue.new
    @fake.on("info") do
      gate.pop
      {}
    end
    call = Thread.new { @client.info }
    sleep 0.01 until @fake.requests.size == 1
    assert_raises(Cent::TimeoutError) { @client.close(timeout: 0.05) }
    gate << true
    @client.close(timeout: 5)
    call.join
    assert_raises(Cent::ClosedError) { @client.info }
  end

  # Broadcast.

  def test_broadcast
    res = @client.broadcast(channels: %w[a b], data: 1, idempotency_key: "k")

    assert_predicate res, :replied?
    assert_equal %w[a b], res.channels.map(&:channel)
    assert_equal([1, 1], res.channels.map { it.result.offset })
    assert_equal "k", res.idempotency_key
    assert_equal 1, res.attempts
    assert_empty res.failed
  end

  def test_broadcast_partial_failure
    err = assert_raises(Cent::BroadcastFailedChannelsError) do
      @client.broadcast(channels: %w[a bad:b flaky:c], data: 1)
    end
    refute_kind_of Cent::ApiError, err
    assert_equal %w[bad:b flaky:c], err.failed.map(&:channel)
    assert_equal 3, err.total
    assert_predicate err.result, :replied?
    assert_equal ["flaky:c"], err.retryable_channels
    assert Cent.retryable?(err)
    assert_equal "broadcast: 2 of 3 channels failed, 1 got the publication: bad:b: unknown channel (code 102); " \
                 "flaky:c: internal server error (code 100) (retry only retryable_channels, with the same " \
                 "idempotency_key)", err.message
  end

  def test_broadcast_into_one_unknown_channel_is_a_partial_error
    err = assert_raises(Cent::BroadcastFailedChannelsError) { @client.broadcast(channels: ["bad:a"], data: 1) }
    refute Cent.retryable?(err)
    assert_equal "broadcast: 1 of 1 channels failed: bad:a: unknown channel (code 102)", err.message
  end

  def test_broadcast_failure_message_is_bounded
    err = assert_raises(Cent::BroadcastFailedChannelsError) do
      @client.broadcast(channels: Array.new(10) { "bad:#{it}" }, data: 1)
    end
    assert_match(/bad:2: unknown channel \(code 102\); and 7 more\z/, err.message)
  end

  def test_broadcast_reply_count_mismatch
    @fake.on("broadcast", { "responses" => [] })
    assert_raises(Cent::DecodeError) { @client.broadcast(channels: %w[a b], data: 1) }
  end

  def test_broadcast_with_retry
    calls = 0
    @fake.on("broadcast") do |_m, body|
      calls += 1
      responses = body["channels"].map do |ch|
        if ch == "b" then { "error" => { "code" => 102, "message" => "unknown channel" } }
        elsif ch == "c" && calls == 1 then { "error" => { "code" => 111, "message" => "limit", "temporary" => true } }
        else { "result" => { "offset" => calls } }
        end
      end
      { "responses" => responses }
    end
    attempts = []
    err = assert_raises(Cent::BroadcastFailedChannelsError) do
      @client.broadcast_with_retry(channels: %w[a b c], data: 1) do |a|
        attempts << a
        0
      end
    end
    # b failed for good; c succeeded on the retry, which only sent c.
    assert_equal ["b"], err.failed.map(&:channel)
    assert_equal [1, 1, 2], err.result.channels.map(&:attempts)
    assert_equal 2, err.result.channels[2].result.offset
    assert_equal 2, err.result.attempts
    bodies = @fake.bodies("broadcast")

    assert_equal([%w[a b c], ["c"]], bodies.map { it["channels"] })
    key = bodies.first["idempotency_key"]

    assert_match(/\Arubycent-[\w-]{24}\z/, key)
    assert_equal [key], bodies.map { it["idempotency_key"] }.uniq
    assert_equal key, err.result.idempotency_key
    assert_equal 1, attempts.size
    assert_equal ["c"], attempts.first.retry.map(&:channel)
    assert_equal key, attempts.first.idempotency_key
  end

  def test_broadcast_with_retry_keeps_the_given_key
    @client.broadcast_with_retry(channels: %w[a], data: 1, idempotency_key: "mine")

    assert_equal "mine", @fake.bodies.last["idempotency_key"]
  end

  def test_broadcast_with_retry_stops_on_permanent_failure_and_gives_up
    @fake.on("broadcast", [401, {}, ""])
    assert_raises(Cent::UnauthorizedError) do
      @client.broadcast_with_retry(channels: ["a"], data: 1, max_attempts: 5) { flunk "called" }
    end
    assert_equal 1, @fake.requests.size

    @fake.on("broadcast", [503, {}, ""])
    assert_raises(Cent::HTTPError) { @client.broadcast_with_retry(channels: ["a"], data: 1, max_attempts: 3) { 0 } }
    assert_equal 4, @fake.requests.size
  end

  def test_broadcast_with_retry_stopped_by_the_block
    @fake.on("broadcast", [503, {}, ""])
    err = assert_raises(RuntimeError) do
      @client.broadcast_with_retry(channels: ["a"], data: 1, max_attempts: 5) { raise "stop" }
    end
    assert_equal "stop", err.message
    assert_instance_of Cent::HTTPError, err.cause
    assert_equal 1, @fake.requests.size
  end

  def test_broadcast_with_retry_options
    [{ max_attempts: 0 }, { max_attempts: -1 }, { attempt_timeout: 0 }, { attempt_timeout: -1.0 }].each do |opts|
      assert_raises(Cent::InvalidRequestError) { @client.broadcast_with_retry(channels: ["a"], data: 1, **opts) }
    end
    assert_raises(Cent::InvalidRequestError) { @client.broadcast_with_retry(channels: [""], data: 1) }
    assert_empty @fake.requests
  end

  def test_broadcast_with_retry_timeout_bounds_the_waits
    @fake.on("broadcast", [503, {}, ""])
    start = Cent::HTTP.now
    assert_raises(Cent::HTTPError) do
      @client.broadcast_with_retry(channels: ["a"], data: 1, max_attempts: 10, timeout: 0.2) { 60 }
    end
    assert_operator Cent::HTTP.now - start, :<, 2
  end

  def test_exponential_backoff
    d = Cent.exponential_backoff(0.1, 1.0)
    100.times do
      assert_includes 0.05..0.1, d.call(1)
      assert_includes 0.1..0.2, d.call(2)
      assert_includes 0.5..1.0, d.call(50)
    end
    assert_includes 0.05..0.1, d.call(0)
    assert_in_delta(0.0, Cent.exponential_backoff(-1, 5).call(1_000_000_000))
    assert_includes 0.5..1.0, Cent.exponential_backoff(1, 0.5).call(3)
  end

  # Batches.

  def test_batch
    b = @client.new_batch
    pub = b.publish(channel: "a", data: 1)
    stats = b.presence_stats(channel: "a")
    bc = b.broadcast(channels: %w[a b], data: 1)

    assert_equal 3, b.size
    assert_raises(Cent::BatchNotSentError) { pub.value }
    res = b.send

    assert_predicate res, :replied?
    assert_empty res.failed
    assert_equal 1, pub.value.offset
    assert_instance_of Cent::PresenceStatsResult, stats.value
    assert_equal %w[a b], bc.value.channels.map(&:channel)
    assert_equal [{ "publish" => { "channel" => "a", "data" => 1 } }, { "presence_stats" => { "channel" => "a" } },
                  { "broadcast" => { "channels" => %w[a b], "data" => 1 } }], @fake.bodies("batch").first["commands"]
    refute @fake.bodies("batch").first.key?("parallel")
    assert_raises(Cent::BatchSentError) { b.send }
    assert_raises(FrozenError) { b.info }
  end

  def test_batch_is_still_object_send
    b = @client.new_batch

    assert_equal 0, b.send(:size)
    assert_empty @fake.requests
  end

  def test_batch_parallel
    b = @client.new_batch(parallel: true)
    b.info
    b.send

    assert @fake.bodies("batch").first["parallel"]
  end

  def test_batch_partial_failure
    @fake.on("publish") { |_m, body| body["channel"] == "bad" ? Cent::ApiError.new(102, "unknown channel") : {} }
    b = @client.new_batch
    ok = b.publish(channel: "a", data: 1)
    bad = b.publish(channel: "bad", data: 1)
    bc = b.broadcast(channels: %w[a bad:b], data: 1)
    err = assert_raises(Cent::BatchFailedCommandsError) { b.send }
    assert_equal([[1, "publish"], [2, "broadcast"]], err.failed.map { [it.index, it.method] })
    assert_equal 3, err.total
    assert_predicate err.result, :replied?
    assert_instance_of Cent::PublishResult, ok.value
    assert_same err.failed[0].error, assert_raises(Cent::UnknownChannelError) { bad.value }
    assert_same err.failed[1].error, assert_raises(Cent::BroadcastFailedChannelsError) { bc.value }
    assert_match(/\Abatch: 2 of 3 commands failed, 1 succeeded: #1 publish: unknown channel \(code 102\); #2 /,
                 err.message)
  end

  def test_batch_pro_method_on_oss_hints
    @fake.on("connections", Cent::ApiError.new(104, "not found"))
    b = @client.new_batch
    p = b.connections
    assert_raises(Cent::BatchFailedCommandsError) { b.send }
    assert_match(/connections is a Centrifugo PRO method: is the server Centrifugo OSS\?/,
                 assert_raises(Cent::NotFoundError) { p.value }.message)
  end

  def test_batch_whole_failure
    @fake.on("batch", [503, {}, ""])
    b = @client.new_batch
    p = b.info
    err = assert_raises(Cent::HTTPError) { b.send }
    assert_same err, assert_raises(Cent::HTTPError) { p.value }
  end

  def test_batch_invalid_command_fails_before_sending
    b = @client.new_batch
    b.info
    b.publish(channel: "a")
    err = assert_raises(Cent::InvalidRequestError) { b.send }
    assert_equal "batch command #1: invalid publish request: data or b64data is required", err.message
    assert_empty @fake.requests
  end

  def test_batch_reply_count_mismatch
    @fake.on("batch", [200, {}, '{"replies":[]}'])
    b = @client.new_batch
    b.info
    assert_raises(Cent::DecodeError) { b.send }
  end

  def test_empty_batch
    res = @client.new_batch.send

    assert_predicate res, :replied?
    assert_empty @fake.requests
  end

  # Commands.

  def test_commands
    cmd = Cent::Command.publish(channel: "news", data: { text: "hi" })

    assert_equal "publish", cmd.method
    assert_equal '{"channel":"news","data":{"text":"hi"}}', cmd.payload
    assert_equal '{"method":"publish","payload":{"channel":"news","data":{"text":"hi"}}}', cmd.to_json
    assert_equal '{"method":"info","payload":{}}', Cent::Command.info.to_json
    assert_equal "invalid publish request: channel is required",
                 assert_raises(Cent::InvalidRequestError) { Cent::Command.publish(data: 1) }.message
    assert_raises(Cent::InvalidRequestError) { Cent::Command.broadcast(channels: ["a"], data: Float::NAN) }
  end

  # Results as Hashes and JSON.

  def test_results_convert_to_hashes_and_json_deeply
    @fake.on("history",
             [200, {},
              '{"result":{"publications":[{"data":{"text":"hi"},"offset":1,"info":{"user":"u"}}],"epoch":"e"}}'])
    res = @client.history(channel: "c")
    h = res.to_h

    assert_equal({ "text" => "hi" }, h[:publications][0][:data])
    assert_equal "u", h[:publications][0][:info][:user]
    info = { "user" => "u", "client" => "", "conn_info" => nil, "chan_info" => nil }
    pub = { "data" => { "text" => "hi" }, "info" => info, "offset" => 1, "tags" => {} }

    assert_equal({ "publications" => [pub], "epoch" => "e", "offset" => 0 }, JSON.parse(res.to_json))
    assert_equal res.to_json, JSON.generate(res)
    assert_equal({ "r" => JSON.parse(res.to_json) }, JSON.parse(JSON.generate({ r: res })))
    # The block form is Data's own.
    assert_equal %w[publications epoch offset], res.to_h { |k, v| [k.to_s, v] }.keys
  end

  def test_errors_in_results_are_their_messages_in_json
    err = assert_raises(Cent::BroadcastFailedChannelsError) { @client.broadcast(channels: %w[a bad:b], data: 1) }
    channels = JSON.parse(err.result.to_json)["channels"]

    assert_equal([nil, "unknown channel (code 102)"], channels.map { it["error"] })
    assert_instance_of Cent::UnknownChannelError, err.result.to_h[:channels][1][:error]
  end
end
