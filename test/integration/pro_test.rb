# frozen_string_literal: true

require_relative "helper"

# Centrifugo PRO methods, API tokens and async consumers, against the Centrifugo
# PRO of testdata/centrifugo-pro.compose.yml: user status, user blocking and
# token revocation in Redis, devices in PostgreSQL, push notifications through
# webpush in dry run.
#
# The tests use Centrifugo PRO in sandbox mode, without a license key.
# Centrifugo PRO is commercial software, under the Centrifugal Labs License
# Agreement (https://centrifugal.dev/license), not under rubycent's MIT
# license.
class ProTest < IntegrationTest
  # A browser PushSubscription, as webpush devices are registered with.
  def webpush_token
    pub = OpenSSL::PKey::EC.generate("prime256v1").public_key.to_bn(:uncompressed).to_s(2)
    e = ->(b) { [b].pack("m0").tr("+/", "-_").delete("=") }
    JSON.generate({ "endpoint" => "https://fcm.googleapis.com/fcm/send/#{e.call(pub[0, 8])}",
                    "keys" => { "p256dh" => e.call(pub), "auth" => e.call("\0" * 16) } })
  end

  def test_user_status
    user = unique
    pro.update_user_status(users: [user], state: "away")
    st, = pro.get_user_status(users: [user]).statuses

    assert_equal [user, "away"], [st.user, st.state]
    assert_operator st.active, :>, 0
    pro.delete_user_status(users: [user])

    assert_equal 0, pro.get_user_status(users: [user]).statuses.first.active
  end

  def test_user_and_token_control
    user = unique
    expire = Time.now.to_i + 60
    pro.block_user(user:, expire_at: expire)
    pro.unblock_user(user:)
    pro.revoke_token(uid: "#{user}-jti", expire_at: expire)
    pro.invalidate_user_tokens(user:, issued_before: Time.now.to_i, expire_at: expire)
  end

  def test_devices_and_push
    user = unique
    reg = pro.device_register(provider: "webpush", platform: "web", token: webpush_token, user:,
                              meta: { "app" => "rubycent" }, topics: ["news"])

    refute_empty reg.id
    by_user = { users: [user] }
    list = pro.device_list(filter: by_user, include_meta: true, include_topics: true, include_total_count: true)

    assert_equal 1, list.total_count
    assert_equal reg.id, list.items.first.id
    assert_equal({ "app" => "rubycent" }, list.items.first.meta)
    assert_includes list.items.first.topics, "news"
    pro.device_topic_update(device_id: reg.id, op: "add", topics: ["sport"])
    topics = pro.device_topic_list(filter: Cent::DeviceTopicFilter.new(device_ids: [reg.id]), include_total_count: true)

    assert_equal 2, topics.total_count
    pro.device_update(ids: [reg.id], meta_update: { meta: { "app" => "updated" } })

    assert_equal({ "app" => "updated" }, pro.device_list(filter: by_user, include_meta: true).items.first.meta)
    pro.user_topic_update(user:, op: "add", topics: ["alerts"])

    assert_equal ["alerts"], pro.user_topic_list(filter: { users: [user] }).items.map(&:topic)
    push = pro.send_push_notification(
      recipient: { filter: by_user },
      notification: { webpush: { payload: { "title" => "hi" } } },
      send_at: Time.now.to_i + 3600
    )

    refute_empty push.uid
    pro.cancel_push(uid: push.uid)
    # Push status needs push analytics in ClickHouse; without it, the method
    # is not available.
    begin
      pro.update_push_status(analytics_uid: push.uid, status: "delivered", device_id: reg.id)
    rescue Cent::NotAvailableError
      nil
    end
    pro.device_remove(ids: [reg.id])

    assert_empty pro.device_list(filter: by_user).items
  end

  def test_pro_batch
    user = unique
    b = pro.new_batch
    b.update_user_status(users: [user], state: "busy")
    status = b.get_user_status(users: [user])
    reg = b.device_register(provider: "webpush", platform: "web", token: webpush_token, user:)
    conns = b.connections(user:)
    b.send

    assert_equal "busy", status.value.statuses.first.state
    id = reg.value.id

    assert_empty conns.value.connections

    # max_in_flight 1 queues every call made while another is in flight.
    auto = Cent::Client.new(api_endpoint: ADDR, api_key: API_KEY, auto_batch: Cent::AutoBatch.new(max_in_flight: 1))
    results = Array.new(20) { Thread.new { auto.device_list(filter: { users: [user] }).items.map(&:id) } }.map(&:value)
    auto.close

    assert_equal [[id]], results.uniq
    pro.device_remove(ids: [id])
  end

  # Tokens from Cent::Token::ApiTokens authenticate API calls to Centrifugo
  # PRO, which verifies them with the keys served here, at the endpoint of
  # testdata/centrifugo-pro.compose.yml: port 3101 of the host. Tokens without
  # the audience and scope it requires are refused, as are tokens signed with a
  # key not published.
  def test_api_tokens
    pro
    # The same keys on every run, from fixed seeds: Centrifugo caches keys by
    # ID, so a new key under a known ID would be refused.
    key = lambda do |kid, seed|
      Cent::Token::Key.ed25519(OpenSSL::PKey.new_raw_private_key("ED25519", seed.chr * 32)).with_key_id(kid)
    end
    api_key = key.call("gocent-api-test", 1)
    serve(ENV.fetch("RUBYCENT_TEST_API_JWKS_PORT", "3101").to_i, { "/api_jwks" => Cent::Endpoints::JWKS.new(api_key) })

    publish = lambda do |token_func|
      c = Cent::Client.new(api_endpoint: ADDR, bearer_token_func: token_func)
      c.publish(channel: unique, data: {})
    ensure
      c&.close
    end

    tokens = Cent::Token::ApiTokens.new(key: api_key, audience: "centrifugo-api", scope: ["centrifugo:api"])
    publish.call(tokens.method(:token))

    exp = Time.now + 60
    [{ audience: "centrifugo-api" }, { scope: ["centrifugo:api"] }].each do |claims|
      tok = Cent::Token.api(api_key, expires_at: exp, **claims)
      assert_raises(Cent::UnauthorizedError) { publish.call(-> { tok }) }
    end
    # A connection token signed with a published key: no audience or scope.
    conn = Cent::Token.connection(api_key, user: "42", expires_at: exp)
    assert_raises(Cent::UnauthorizedError) { publish.call(-> { conn }) }

    unpublished = Cent::Token::ApiTokens.new(key: key.call("gocent-unpublished", 2), audience: "centrifugo-api")
    assert_raises(Cent::UnauthorizedError) { publish.call(unpublished.method(:token)) }
  end

  def redis_xadd(addr, stream, *fields)
    host, port = addr.split(":")
    args = ["XADD", stream, "*", *fields]
    cmd = "*#{args.size}\r\n#{args.map { "$#{it.bytesize}\r\n#{it}\r\n" }.join}"
    TCPSocket.open(host, port.to_i) do |s|
      s.write(cmd)

      assert s.readpartial(1024).start_with?("$")
    end
  end

  # Commands from Cent::Command, written to a Redis stream, are run by
  # Centrifugo's async consumer: apart, as method and payload, and whole.
  def test_command_consumed
    pro
    addr = ENV.fetch("RUBYCENT_TEST_REDIS", "localhost:46379")
    ch = unique
    apart = Cent::Command.publish(channel: ch, data: { n: 1 })
    redis_xadd(addr, "rubycent_commands", "method", apart.method, "payload", apart.payload)
    whole = Cent::Command.publish(channel: ch, data: { n: 2 })
    redis_xadd(addr, "rubycent_commands", "payload", whole.to_json)
    deadline = Cent::HTTP.now + 15
    loop do
      pubs = pro.history(channel: ch, limit: 10).publications
      if pubs.size == 2
        assert_equal [{ "n" => 1 }, { "n" => 2 }], pubs.map(&:data)
        break
      end
      flunk "#{pubs.size} of 2 commands consumed after 15s" if Cent::HTTP.now > deadline
      sleep 0.1
    end
  end
end
