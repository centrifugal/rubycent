# Migrating from cent 4 to cent 5

cent 5 is a rewrite, to the
[Centrifugo server SDK specification](https://github.com/centrifugal/gocent/blob/master/spec.md).
It needs Ruby 3.4 or newer and Centrifugo v6, and depends on nothing but the
json gem: Faraday and the jwt gem are gone. An application which needs time to
move can stay on `gem "cent", "~> 4.0"`, which keeps working.

What changes:

- **Every API method** still takes keyword arguments, now every field of its
  request - generated from Centrifugo's `api.proto`, each documented - and
  returns a typed result: `res.offset` instead of `res["result"]["offset"]`.
  Every method of Centrifugo v6's API is there, the PRO ones included.
- **Errors** are Centrifugo's codes as classes - `Cent::UnknownChannelError`,
  `Cent::NotFoundError`, ... all `Cent::ApiError` - instead of
  `Cent::ResponseError`. **Broadcasts and batches raise** when parts of them
  failed: see [below](#broadcasts-and-batches-now-raise).
- **The client** takes `api_endpoint:`, which is required, and
  `request_timeout:`; each call takes `timeout:`, which bounds the whole
  request. The Faraday block is gone: TLS settings go in `http_options:`,
  another HTTP library in `http_client:`.
- **Tokens** are made with `Cent::Token.connection` and
  `Cent::Token.subscription`, with every claim Centrifugo reads, and HMAC, RSA,
  ECDSA or Ed25519 keys. An expiry is required: `:never` for a token accepted
  forever.
- **New:** batches with a result per command, automatic batching, retries,
  proxy handlers and the endpoints client SDKs call as Rack apps, JWKS,
  Centrifugo PRO's API tokens, shared poll signatures, commands for async
  consumers.

## Broadcasts and batches now raise

This is the change most likely to break code which moved over unchanged.

cent 4 returned Centrifugo's response for a broadcast or a batch, and a
channel or command which failed was only an `"error"` inside it. Code which
didn't look - most code - went on as if everything had been published.

cent 5 raises when any part failed, even when the others succeeded:
`Cent::BroadcastFailedChannelsError` for a broadcast,
`Cent::BatchFailedCommandsError` for a batch. Not rescuing it means an error
where cent 4 was silent - in a web request, an error page, although most
channels got the publication.

Decide, for each broadcast and batch, which you want:

- **A failure is an error** - an unknown channel is a bug, a broker failure
  needs attention: let it raise, and your error reporting sees it.
- **Best effort, as cent 4 behaved** - publish where it can, log the rest:
  rescue the error. It holds every part's outcome, and the parts which
  succeeded were published.

```ruby
begin
  client.broadcast(channels:, data:)
rescue Cent::BroadcastFailedChannelsError => e
  e.failed.each { logger.warn("broadcast to #{it.channel} failed: #{it.error.message}") }
end
```

## Side by side

Each pair prints the same, run against Centrifugo.

### Calls and errors

cent 4:

```ruby
require "cent"

client = Cent::Client.new(api_key: "api_key", endpoint: "http://localhost:8000/api", timeout: 5)

res = client.publish(channel: "news", data: { text: "hello" })
puts "published at offset #{res["result"]["offset"]}"

res = client.history(channel: "news", limit: 1, reverse: true)
puts "last: #{res["result"]["publications"][0]["data"]["text"]}"

# Centrifugo's errors are raised.
begin
  client.publish(channel: "unknown:news", data: { text: "hello" })
rescue Cent::ResponseError => e
  puts "error #{e.code}: #{e.message}"
end
```

cent 5:

```ruby
require "cent"

client = Cent::Client.new(api_endpoint: "http://localhost:8000/api", api_key: "api_key", request_timeout: 5)

res = client.publish(channel: "news", data: { text: "hello" })
puts "published at offset #{res.offset}"

res = client.history(channel: "news", limit: 1, reverse: true)
puts "last: #{res.publications[0].data["text"]}"

# Centrifugo's errors are raised, a class per code.
begin
  client.publish(channel: "unknown:news", data: { text: "hello" })
rescue Cent::ApiError => e
  puts "error #{e.code}: #{e.server_message}"
end
```

### Broadcast

A channel which failed is an error to rescue, not an entry to look for.

cent 4:

```ruby
require "cent"

client = Cent::Client.new(api_key: "api_key", endpoint: "http://localhost:8000/api")

channels = ["news", "unknown:alerts", "sport"]
res = client.broadcast(channels:, data: { text: "hello" })
res["result"]["responses"].each_with_index do |r, i|
  if r["error"]
    puts "#{channels[i]}: error #{r["error"]["code"]}"
  else
    puts "#{channels[i]}: offset #{r["result"]["offset"]}"
  end
end
```

cent 5:

```ruby
require "cent"

client = Cent::Client.new(api_endpoint: "http://localhost:8000/api", api_key: "api_key")

begin
  res = client.broadcast(channels: ["news", "unknown:alerts", "sport"], data: { text: "hello" })
rescue Cent::BroadcastFailedChannelsError => e
  # Some channels failed; the others got the publication.
  res = e.result
end
res.channels.each do |ch|
  if ch.error
    puts "#{ch.channel}: error #{ch.error.code}"
  else
    puts "#{ch.channel}: offset #{ch.result.offset}"
  end
end
```

### Batch

A batch has the client's methods, each adding a command with its own result.

cent 4:

```ruby
require "cent"

client = Cent::Client.new(api_key: "api_key", endpoint: "http://localhost:8000/api")

res = client.batch(commands: [
  { "publish" => { "channel" => "news", "data" => { "text" => "hi" } } },
  { "presence_stats" => { "channel" => "news" } }
])
puts "published at offset #{res["replies"][0]["publish"]["offset"]}"
puts "clients: #{res["replies"][1]["presence_stats"]["num_clients"] || 0}"
```

cent 5:

```ruby
require "cent"

client = Cent::Client.new(api_endpoint: "http://localhost:8000/api", api_key: "api_key")

batch = client.new_batch
pub = batch.publish(channel: "news", data: { text: "hi" })
stats = batch.presence_stats(channel: "news")
batch.send
puts "published at offset #{pub.value.offset}"
puts "clients: #{stats.value.num_clients}"
```

### Tokens

The claims are named for what they mean; the expiry is a `Time`, or `:never`.

cent 4:

```ruby
require "cent"
require "json"

notary = Cent::Notary.new(secret: "secret")
token = notary.issue_connection_token(sub: "42", exp: 1_900_000_000, info: { name: "Alice" }, channels: ["news"])
puts JSON.parse(token.split(".")[1].unpack1("m")).slice("sub", "exp", "info", "channels")

token = notary.issue_channel_token(sub: "42", channel: "news", exp: 1_900_000_000)
puts JSON.parse(token.split(".")[1].unpack1("m")).slice("sub", "exp", "channel")
```

cent 5:

```ruby
require "cent"

key = Cent::Token::Key.hmac("secret")
token = Cent::Token.connection(key, user: "42", expires_at: Time.at(1_900_000_000), info: { name: "Alice" },
                                    channels: ["news"])
puts JSON.parse(token.split(".")[1].unpack1("m")).slice("sub", "exp", "info", "channels")

token = Cent::Token.subscription(key, user: "42", channel: "news", expires_at: Time.at(1_900_000_000))
puts JSON.parse(token.split(".")[1].unpack1("m")).slice("sub", "exp", "channel")
```

## Mapping

| cent 4 | cent 5 |
|---|---|
| `Cent::Client.new(api_key:, endpoint:, timeout:)` | `Cent::Client.new(api_endpoint:, api_key:, request_timeout:)`; `api_endpoint` is required, without a default |
| the Faraday block: `conn.options...`, `conn.adapter` | `http_options: { ca_file:, cert:, key:, ... }`, or `http_client:` for another HTTP library; `timeout:` on a call bounds it whole |
| `publish(channel:, data:, ...)` and the other methods | the same names and keywords, every field of the request; a result object instead of the response Hash |
| `history(..., since: { "offset" => 5, "epoch" => "x" })` | `since: { offset: 5, epoch: "x" }`, or `Cent::StreamPosition.new(...)`: field names are Symbols |
| `disconnect(whitelist:)` | gone from Centrifugo v6 |
| `broadcast(...)` with errors in `responses` | raises `BroadcastFailedChannelsError` when a channel failed; `broadcast_with_retry` |
| `batch(commands: [...])` | `batch = client.new_batch; p = batch.publish(...); batch.send; p.value` |
| `Cent::ResponseError` (`code`, `message`) | `Cent::ApiError` (`code`, `server_message`, `temporary?`), a subclass per known code |
| `Cent::TransportError` (`status`) | `Cent::HTTPError` (`status_code`, `body`, `headers`) |
| `Cent::TimeoutError`, `Cent::NetworkError`, `Cent::UnauthorizedError`, `Cent::DecodeError` | the same names |
| `Cent::Notary.new(secret:, algorithm:)` | `Cent::Token::Key.hmac(secret)`, `.rsa(pkey)`, `.ecdsa(pkey)`, `.ed25519(pkey)`, `.from_pem(pem)`; HMAC tokens are HS256 |
| `issue_connection_token(sub:, exp:, iat:, jti:, aud:, iss:, ...)` | `Cent::Token.connection(key, user:, expires_at:, issued_at:, id:, audience:, issuer:, ...)` |
| `issue_channel_token(sub:, channel:, ...)` | `Cent::Token.subscription(key, user:, channel:, expires_at:, ...)` |
| a token without `exp`, which never expired | `expires_at: :never`, chosen explicitly |
| `expire_at:` claims as Unix seconds | `connection_expires_at:`, `subscription_expires_at:` as a `Time`, or `:never` |

For tests, give the client a fake `http_client:` instead of stubbing HTTP: a
callable returning `[status, headers, body]`.
