# frozen_string_literal: true

require_relative "helper"

# The proxy handlers, called by a real Centrifugo: testdata/centrifugo.json
# points its connect and refresh proxies at port 3100 of the host, which it
# reaches as host.docker.internal, or RUBYCENT_TEST_PROXY_PORT.
class ProxyTest < IntegrationTest
  PORT = ENV.fetch("RUBYCENT_TEST_PROXY_PORT", "3100").to_i

  def test_connect_and_refresh
    user = unique("proxy-")
    ch = "#{user}-news"
    connects = Queue.new
    refreshes = Queue.new
    errors = []
    on_error = ->(_req, err) { errors << err }

    connect = Cent::Proxy::ConnectHandler.new(on_error:) do |req|
      connects << req
      raise Cent::Proxy::Disconnect.new(4501, "unauthorized") unless req.data["allow"]

      Cent::Proxy::ConnectResult.new(user:, expire_at: Time.now.to_i + 2, info: { "name" => "Alice" },
                                     data: { "welcome" => true }, channels: [ch])
    end
    refresh = Cent::Proxy::RefreshHandler.new(on_error:) do |req|
      refreshes << req
      { expired: true }
    end
    serve(PORT, { "/connect" => connect, "/refresh" => refresh })

    # Refused: the connection is closed with the disconnect's code.
    refused = stream({ data: { allow: false } })
    req = connects.pop(timeout: 10)

    assert_equal %w[uni_http_stream json json], [req.transport, req.protocol, req.encoding]
    refute_empty req.client
    assert_equal 4501, refused.next.dig("disconnect", "code")

    # Accepted: the result's data and server-side channel reach the client, and
    # so does a publication into that channel.
    s = stream({ data: { allow: true } })
    connects.pop(timeout: 10)
    reply = s.next

    assert_equal({ "welcome" => true }, reply.dig("connect", "data"))
    assert_includes reply.dig("connect", "subs"), ch
    client.publish(channel: ch, data: { text: "hello" })

    assert_includes JSON.generate(s.next), "hello"
    pres = client.presence(channel: ch)

    assert_equal([[user, { "name" => "Alice" }]], pres.presence.values.map { [it.user, it.conn_info] })

    # It expires: Centrifugo asks the refresh proxy, which ends it.
    ref = refreshes.pop(timeout: 30)

    refute_nil ref
    assert_equal user, ref.user
    assert_equal reply.dig("connect", "client"), ref.client
    s.drain

    assert_empty errors
  end
end
