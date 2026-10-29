# frozen_string_literal: true

require_relative "helper"

# The API client against a real Centrifugo.
class ApiTest < IntegrationTest
  def test_publish_and_history
    ch = unique
    raw = JSON::Fragment.new('{"n":1.0,"big":18446744073709551617,"empty":{},"keys":{"0":"a"}}')
    res = client.publish(channel: ch, data: raw, tags: { "k" => "v" })

    assert_equal 1, res.offset
    refute_empty res.epoch
    pub, = client.history(channel: ch, limit: 10).publications

    assert_equal({ "k" => "v" }, pub.tags)
    assert_equal({ "n" => 1.0, "big" => 18_446_744_073_709_551_617, "empty" => {}, "keys" => { "0" => "a" } }, pub.data)
    # Sent back unchanged, the payload is the same JSON value.
    client.publish(channel: ch, data: pub.data)
    again = client.history(channel: ch, limit: 10, reverse: true).publications.first

    assert_equal pub.data, again.data
    assert_kind_of Float, again.data["n"]
    client.history_remove(channel: ch)

    assert_empty client.history(channel: ch, limit: 10).publications
  end

  def test_idempotency_key
    ch = unique
    first = client.publish(channel: ch, data: 1, idempotency_key: "k1")
    second = client.publish(channel: ch, data: 2, idempotency_key: "k1")

    assert_equal first.offset, second.offset
    assert_equal 1, client.history(channel: ch, limit: 10).publications.size
  end

  def test_broadcast
    a = unique("a-")
    b = unique("b-")
    res = client.broadcast(channels: [a, b], data: { x: 1 })

    assert_equal([1, 1], res.channels.map { it.result.offset })
    err = assert_raises(Cent::BroadcastFailedChannelsError) { client.broadcast(channels: [a, "unknown:x"], data: 2) }
    assert_equal ["unknown:x"], err.failed.map(&:channel)
    assert_instance_of Cent::UnknownChannelError, err.failed.first.error
    refute_nil err.result.channels.first.result
    refute Cent.retryable?(err)
  end

  def test_broadcast_with_retry
    a = unique
    res = client.broadcast_with_retry(channels: [a], data: 1)

    assert res.idempotency_key.start_with?("rubycent-")
    # Retried later with the key, nothing is published again.
    client.broadcast(channels: [a], data: 1, idempotency_key: res.idempotency_key)

    assert_equal 1, client.history(channel: a, limit: 10).publications.size
  end

  def test_batch
    ch = unique
    b = client.new_batch
    pub = b.publish(channel: ch, data: 1)
    hist = b.history(channel: ch, limit: 1)
    bad = b.publish(channel: "unknown:x", data: 1)
    err = assert_raises(Cent::BatchFailedCommandsError) { b.send }
    assert_equal [2], err.failed.map(&:index)
    assert_equal 1, pub.value.offset
    assert_equal 1, hist.value.publications.size
    assert_raises(Cent::UnknownChannelError) { bad.value }
  end

  def test_refused_request_is_not_retryable
    refute Cent.retryable?(assert_raises(Cent::ApiError) { client.history(channel: "unknown:x") })
  end

  # A PRO method on Centrifugo OSS: a 404 which says so, and in a batch a 104
  # which says so too. Against Centrifugo PRO it succeeds.
  def test_pro_method
    begin
      client.connections(user: "nobody")
      skip "Centrifugo PRO: its methods succeed, see ProTest"
    rescue Cent::HTTPError => e
      err = e
    end

    assert_equal 404, err.status_code
    assert_includes err.message, "Centrifugo PRO method"
    b = client.new_batch
    conns = b.connections(user: "nobody")
    assert_raises(Cent::BatchFailedCommandsError) { b.send }
    assert_match(/Centrifugo PRO method/, assert_raises(Cent::NotFoundError) { conns.value }.message)
  end

  def test_info
    info = client.info

    refute_empty info.nodes
    refute_empty info.nodes.first.version
  end

  def test_map
    ch = "map:#{unique}"
    client.map_publish(channel: ch, key: "k1", data: { v: 1 })
    client.map_publish(channel: ch, key: "k2", data: { v: 2 })

    assert_equal %w[k1 k2], client.map_read_state(channel: ch, limit: 10).entries.map(&:key).sort
    client.map_remove(channel: ch, key: "k1")

    assert_equal 1, client.map_stats(channel: ch).num_keys
    client.map_clear(channel: ch)
  end

  def test_shared_poll_publish
    client.shared_poll_publish(channel: "poll:#{unique}", key: "k", version: 1, data: { v: 1 })
  end

  def test_auto_batch_under_concurrency
    infos = Queue.new
    c = Cent::Client.new(api_endpoint: ADDR, api_key: API_KEY, auto_batch: Cent::AutoBatch.new(max_in_flight: 2),
                         on_request: ->(i) { infos << i })
    ch = unique
    workers = Array.new(16) do |w|
      Thread.new { 20.times { |n| c.publish(channel: "#{ch}-#{w}", data: { n: }) } }
    end
    workers.each(&:join)
    c.close(timeout: 10)

    assert(Array.new(infos.size) { infos.pop }.any?(&:auto_batch))
    16.times do |w|
      # One after another: in order.
      assert_equal((0...20).to_a, client.history(channel: "#{ch}-#{w}", limit: 100).publications.map { it.data["n"] })
    end
  end

  # Tokens from Cent::Token connect a real client - HMAC, and Ed25519 verified
  # by client.token.ed25519_public_key (the public key of the seed below, set in
  # testdata/centrifugo.json) - and the server-side methods act on it.
  def test_connection_with_tokens
    exp = Time.now + 3600
    keys = {
      "hmac" => Cent::Token::Key.hmac("client_secret"),
      "ed25519" => Cent::Token::Key.ed25519(OpenSSL::PKey.new_raw_private_key("ED25519", "\x02" * 32))
    }
    keys.each do |kind, key|
      user = unique("#{kind}-")
      ch = "#{user}-news"
      tok = Cent::Token.connection(key, user:, expires_at: exp, info: { "name" => "Alice" }, channels: [ch])
      s = stream({ token: tok })
      msg = s.next

      assert msg.key?("connect"), msg
      assert_includes JSON.generate(msg), ch
      pres = client.presence(channel: ch)

      assert_equal([[user, { "name" => "Alice" }]], pres.presence.values.map { [it.user, it.conn_info] })
      assert_equal 1, client.presence_stats(channel: ch).num_users
      client.publish(channel: ch, data: { text: "hello" })

      assert_includes JSON.generate(s.next), "hello"
      other = "#{ch}-2"
      client.subscribe(user:, channel: other)

      assert_includes JSON.generate(s.next), other
      client.refresh(user:, expire_at: exp.to_i)
      client.disconnect(user:)
      s.drain
    end
    # A token signed with another key is refused.
    bad = Cent::Token.connection(Cent::Token::Key.ed25519(OpenSSL::PKey.generate_key("ED25519")),
                                 user: "u", expires_at: exp)
    msg = stream({ token: bad }).next

    assert(msg.nil? || msg.key?("disconnect"))
  end
end
