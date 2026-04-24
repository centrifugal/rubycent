# cent

![Build Status](https://github.com/centrifugal/rubycent/actions/workflows/main.yml/badge.svg)

Ruby client for the [Centrifugo](https://centrifugal.dev) server HTTP API.

- `Cent::Client` — call server API methods (publish, broadcast, presence, history, …).
- `Cent::Notary` — issue connection and subscription JWTs.

Works with Centrifugo **v4 and newer** (tested against v6.7.1). Ruby 3.0+.

## Installation

```ruby
gem 'cent', '~> 4.0'
```

```sh
$ bundle install
```

## API client

```ruby
client = Cent::Client.new(api_key: 'your-api-key')
# Or pointing at a remote Centrifugo:
client = Cent::Client.new(
  api_key: 'your-api-key',
  endpoint: 'https://centrifugo.example.com/api',
  timeout: 5
)
```

Every method returns the parsed response body from Centrifugo:

- On success the body has a `"result"` key: `{ "result" => { ... } }`.
- On an API-level failure (e.g. unknown channel, namespace not found) `Cent::ResponseError` is raised with Centrifugo's numeric `code` and `message`.
- On a transport problem (network failure, timeout, non-2xx HTTP, malformed JSON) a `Cent::Error` subclass is raised.

`batch` and `broadcast` are different — see their sections below.

### Customizing the connection

The initializer yields the underlying [`Faraday::Connection`](https://lostisland.github.io/faraday/) so you can adjust headers, timeouts, adapter, etc.

```ruby
Cent::Client.new(api_key: 'k') do |conn|
  conn.headers['User-Agent'] = 'my-app/1.0'
  conn.options.open_timeout  = 3
  conn.options.timeout       = 7
  conn.adapter :typhoeus
end
```

### Publishing

```ruby
client.publish(channel: 'chat', data: { text: 'hello' })
# => {"result" => {"offset" => 1, "epoch" => "xyz"}}

client.publish(
  channel:         'chat',
  data:            { text: 'hello' },
  skip_history:    false,
  tags:            { 'author' => '42' },
  idempotency_key: 'my-idempotency-key',
  delta:           true
)
```

See [publish](https://centrifugal.dev/docs/server/server_api#publish).

### Broadcast

```ruby
response = client.broadcast(channels: %w[chat:1 chat:2], data: { text: 'hi' })
# response => { "result" => { "responses" => [ {"result" => {...}}, {"result" => {...}} ] } }
```

The outer call only raises `Cent::ResponseError` if the whole broadcast is rejected (e.g. malformed request). Per-channel failures are delivered as individual entries in `response["result"]["responses"]`, each of which may contain an `"error"` key — **these are not raised**. Walk the array to check them:

```ruby
response['result']['responses'].each_with_index do |r, i|
  warn "channel #{i} failed: #{r['error']['message']}" if r['error']
end
```

### Subscribe / Unsubscribe

```ruby
client.subscribe(user: '42', channel: 'chat')
client.unsubscribe(user: '42', channel: 'chat')
```

### Disconnect / Refresh

```ruby
client.disconnect(user: '42')
client.disconnect(user: '42', whitelist: %w[keep-this-client-id])

client.refresh(user: '42', expired: true)
```

### Presence / Presence stats

```ruby
client.presence(channel: 'chat')
client.presence_stats(channel: 'chat')
```

### History

```ruby
client.history(channel: 'chat', limit: 10)
client.history(channel: 'chat', limit: 10, reverse: true)
client.history(channel: 'chat', limit: 10, since: { 'offset' => 5, 'epoch' => 'xyz' })
client.history_remove(channel: 'chat')
```

### Channels

```ruby
client.channels
client.channels(pattern: 'chat:*')
```

### Info

```ruby
client.info
```

### Batch

Send many commands in one HTTP request — Centrifugo processes them sequentially (or in parallel with `parallel: true`) and returns one reply per command in the same order.

```ruby
response = client.batch(commands: [
  { 'publish'        => { 'channel' => 'a', 'data' => { 'x' => 1 } } },
  { 'publish'        => { 'channel' => 'b', 'data' => { 'x' => 2 } } },
  { 'presence_stats' => { 'channel' => 'a' } }
])
# => { "replies" => [ {"publish" => {...}}, {"publish" => {...}}, {"presence_stats" => {...}} ] }
```

Two things about batch are different from every other method:

1. **No `result` wrapper.** The response is `{ "replies" => [...] }` at the top level. This matches Centrifugo's wire format.
2. **Per-command errors are not raised.** Each entry in `replies` may instead be `{ "error" => { "code" => ..., "message" => ... } }`. Raising on the first would make partial-success responses impossible to inspect — so the caller is expected to walk the array:

   ```ruby
   response['replies'].each_with_index do |reply, i|
     if reply['error']
       warn "command #{i} failed: #{reply['error']['code']} #{reply['error']['message']}"
     end
   end
   ```

   `Cent::ResponseError` is still raised if Centrifugo rejects the batch request as a whole (e.g. malformed top-level body).

### Error handling

```ruby
begin
  response = client.publish(channel: 'chat', data: 'hi')
rescue Cent::ResponseError => e
  # Centrifugo rejected the request (e.g. unknown channel, namespace not found).
  puts "Centrifugo error #{e.code}: #{e.message}"
rescue Cent::TimeoutError
  # request timed out
rescue Cent::NetworkError
  # connection refused / DNS failure / etc.
rescue Cent::UnauthorizedError => e
  # HTTP 401 — API key is wrong
rescue Cent::TransportError => e
  # other 4xx/5xx — e.status has the HTTP code
rescue Cent::DecodeError
  # response body wasn't valid JSON
end
```

All of the above inherit from `Cent::Error`, so you can rescue that single class if you don't need to discriminate.

## Token generation

```ruby
notary = Cent::Notary.new(secret: 'hmac-secret')                       # HS256
notary = Cent::Notary.new(secret: rsa_private_key, algorithm: 'RS256') # RSA
notary = Cent::Notary.new(secret: ec_private_key,  algorithm: 'ES256') # ECDSA
```

### Connection token

Used by clients to establish a real-time connection. See [authentication](https://centrifugal.dev/docs/server/authentication).

```ruby
notary.issue_connection_token(sub: '42')
notary.issue_connection_token(sub: '42', exp: Time.now.to_i + 600, info: { name: 'Alex' })

# With any of the standard/Centrifugo claims:
notary.issue_connection_token(
  sub: '42', exp: 1735689600, iat: 1735686000, jti: SecureRandom.uuid,
  aud: 'centrifugo', iss: 'my-app',
  info: { role: 'admin' }, meta: { tenant: 'acme' },
  channels: %w[user:42 news],
  subs: { 'room:1' => { 'data' => { 'welcome' => true } } }
)
```

### Subscription token

Used by clients to subscribe to a channel that requires token authorization. See [channel token auth](https://centrifugal.dev/docs/server/channel_token_auth).

```ruby
notary.issue_channel_token(sub: '42', channel: 'private-chat', exp: 1735689600)
notary.issue_channel_token(
  sub: '42', channel: 'private-chat',
  info: { role: 'writer' },
  override: { 'presence' => { 'value' => true } }
)
```

## Migrating from v3

v4 is a breaking release. Expect to touch a few call sites.

- **Centrifugo v4+ is required.** v3 of this gem spoke the legacy `POST /api` JSON-RPC-style protocol; v4 uses the current per-method endpoints (`POST /api/publish`, `POST /api/broadcast`, …) and sends the API key as `X-API-Key` instead of `Authorization: apikey <key>`.
- **Error handling is unchanged for the common case.** `Cent::ResponseError` still exists and is still raised when Centrifugo returns a top-level API error. Existing `rescue Cent::ResponseError => e` blocks using `e.code` / `e.message` keep working. The new additions are typed transport errors — `Cent::TimeoutError`, `Cent::NetworkError`, `Cent::TransportError`, `Cent::UnauthorizedError`, `Cent::DecodeError` — all subclassed under `Cent::Error`.
- **Keyword arg rename**: `Cent::Notary#issue_channel_token(client:)` → `issue_channel_token(sub:)` to match Centrifugo's standard `sub` JWT claim.
- **`unsubscribe` takes `user:`** now (was previously `user:` too, but is now validated and paired with `channel:`).
- **Ruby 3.0+** is required (was 2.5+). Faraday 2 and Faraday 3 are both supported; JWT 2 and JWT 3 are both supported.
- **New methods** added for common Centrifugo operations: `subscribe`, `refresh`, `history_remove`, `batch`.
- **Richer kwargs** on existing methods (e.g. `publish` now accepts `tags`, `skip_history`, `idempotency_key`, `delta`, `version`, `version_epoch`, `b64data`; `history` accepts `limit`, `since`, `reverse`; `channels` accepts `pattern`).

See `release_v4.0.0.md` for the full list of changes.

## Development

```sh
$ bin/setup                # install dependencies
$ bundle exec rspec        # run unit tests
$ bundle exec rubocop      # lint
```

### Running integration tests

Integration tests under `spec/integration/` exercise a real Centrifugo server. They're skipped unless `CENTRIFUGO_API_URL` is set.

```sh
$ docker compose up -d
$ CENTRIFUGO_API_URL=http://localhost:8000/api CENTRIFUGO_API_KEY=api_key bundle exec rspec spec/integration
```

### Testing across Faraday / JWT versions

```sh
$ bundle exec appraisal install         # generate gemfiles/*.gemfile.lock
$ bundle exec appraisal rspec           # run the full matrix locally
```

## License

MIT — see [LICENSE.txt](LICENSE.txt).
