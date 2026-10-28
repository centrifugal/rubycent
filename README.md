# cent

Ruby SDK for the [HTTP server API](https://centrifugal.dev/docs/server/server_api)
of [Centrifugo](https://github.com/centrifugal/centrifugo): every API method,
including those of Centrifugo PRO, with typed results; batches, automatic
batching and retries; connection, subscription and server API tokens; the
proxy handlers and the endpoints client SDKs call, as Rack apps.

```ruby
gem "cent", "~> 5.0"   # json is the only dependency
```

| | Version |
|---|---|
| Ruby | 3.4 or newer |
| Centrifugo | v6, any release |
| Map and shared poll methods | Centrifugo v6.8.0 or newer |
| `ApiError#temporary?`, `TooManyRequestsError`, refused requests reported as such rather than as internal errors | Centrifugo v6.10.0 or newer |
| Ed25519 tokens verified without JWKS, by `client.token.ed25519_public_key` | Centrifugo v6.10.2 or newer |
| Methods marked "Centrifugo PRO only" | Centrifugo PRO v6 |

cent 5 replaces cent 4: see [MIGRATING.md](MIGRATING.md) - an application
which needs time to move can stay on `gem "cent", "~> 4.0"`. cent implements the
[Centrifugo server SDK specification](https://github.com/centrifugal/gocent/blob/v4_dev/spec.md),
version 0.2.

## Example

```ruby
require "cent"

client = Cent::Client.new(api_endpoint: "http://localhost:8000/api", api_key: ENV.fetch("CENTRIFUGO_API_KEY"))

res = client.publish(channel: "news", data: { text: "hello" })
puts "published at offset #{res.offset}"
```

There is a method for every API method, generated from Centrifugo's
`api.proto` with its documentation. It takes the fields of the method's
request as keyword arguments and returns its result - a `Data` object - raising
unless Centrifugo did everything asked. A nested message is its class or a
Hash of its fields: `since: { offset: 5, epoch: "xyz" }`. A batch and commands
have the same methods: `batch.publish(...)`, `Cent::Command.publish(...)`.

Create the client once and share it - a constant, an initializer: it is safe
for concurrent use from threads, and keeps its connections to Centrifugo alive
between calls. Under a fiber scheduler - Async, Falcon - calls wait without
blocking other fibers.

A result converts to a Hash and to JSON whole, nested results included:
`res.to_h`, `res.to_json`, `render json: res`.

## Rails

The client, configured once in an initializer and closed when the process
exits, so that calls in progress finish:

```ruby
# config/initializers/centrifugo.rb
CENTRIFUGO = Cent::Client.new(
  api_endpoint: ENV.fetch("CENTRIFUGO_API_ENDPOINT", "http://localhost:8000/api"),
  api_key: Rails.application.credentials.dig(:centrifugo, :api_key),
  request_timeout: 5
)
at_exit { CENTRIFUGO.close(timeout: 5) }
```

Publishing from a model or a job, and rendering a result:

```ruby
class Message < ApplicationRecord
  after_create_commit do
    CENTRIFUGO.publish(channel: "chat:#{room_id}", data: { id:, text:, user: user.name },
                       idempotency_key: "message-#{id}")
  end
end

class HistoryController < ApplicationController
  def show
    render json: CENTRIFUGO.history(channel: "chat:#{params[:room_id]}", limit: 50, reverse: true)
  end
end
```

Token endpoints, as plain actions behind your authentication - the token
functions are all you need from cent here:

```ruby
# config/initializers/centrifugo.rb
CENTRIFUGO_KEY = Cent::Token::Key.hmac(Rails.application.credentials.dig(:centrifugo, :token_secret))

# app/controllers/centrifugo_controller.rb
class CentrifugoController < ApplicationController
  # 403, not the 401 authenticate_user! answers: a client SDK stops asking only
  # on 403, and retries anything else.
  before_action { head :forbidden unless current_user }

  def connection_token
    token = Cent::Token.connection(CENTRIFUGO_KEY, user: current_user.id.to_s, expires_at: 15.minutes.from_now)
    render_token(token)
  end

  def subscription_token
    channel = params.require(:channel)
    # 403 tells the client SDK to stop asking, and to unsubscribe.
    return head :forbidden unless current_user.can_read?(channel)

    render_token(Cent::Token.subscription(CENTRIFUGO_KEY, user: current_user.id.to_s, channel:,
                                                          expires_at: 15.minutes.from_now))
  end

  private

  def render_token(token)
    response.headers["Cache-Control"] = "no-store"   # a token is never cached
    render json: { token: }
  end
end

# config/routes.rb
post "centrifugo/connection_token", to: "centrifugo#connection_token"
post "centrifugo/subscription_token", to: "centrifugo#subscription_token"
```

A client SDK treats a 403 from a token endpoint as final - it disconnects, or
unsubscribes - and retries anything else, a 401 or 500 included: a signed-out
user's browser answered 401 would ask again and again.

A proxy handler, which Centrifugo calls on an internal network, is mounted as
it is. Its block hands the request to a module of your app: the module is
reloaded in development, where the initializer is not, and its methods can
`return` early, which a block cannot:

```ruby
# config/initializers/centrifugo.rb
REPORT = ->(_http, err) { Rails.error.report(err) }

SUBSCRIBE_HANDLER = Cent::Proxy::SubscribeHandler.new(on_error: REPORT) do |req, http|
  CentrifugoProxy.subscribe(req, http)
end

# app/services/centrifugo_proxy.rb
module CentrifugoProxy
  def self.subscribe(req, _http)
    return {} if req.channel.start_with?("public:")
    raise Cent::Proxy::ProxyError.new(403, "permission denied") unless Room.readable_by?(req.user, req.channel)

    { info: { "role" => Room.role(req.user, req.channel) } }
  end
end

# config/routes.rb
mount SUBSCRIBE_HANDLER, at: "/centrifugo/subscribe"
```

The module's methods are plain to test:
`CentrifugoProxy.subscribe(Cent::Proxy::SubscribeRequest.new(user: "42", channel: "room:1"), nil)`.

## Payloads

`data`, `info`, `meta` and the other payloads are JSON values, given as the
Ruby values `JSON.generate` writes - `Hash`, `Array`, `String`, `Integer`,
`Float`, `true`, `false`, `nil`, Symbols as strings - and returned as
`JSON.parse` gives them, Hashes with String keys:

```ruby
client.publish(channel: "news", data: { text: "hi", tags: %w[a b] })

pub = client.history(channel: "news", limit: 1).publications.first
pub.data["text"]
client.publish(channel: "archive", data: pub.data)   # exactly the same JSON value
```

A payload from a reply has String keys, as JSON has: `pub.data["text"]`, not
`pub.data[:text]`, so that it goes back out as the same JSON value. To read it
with Symbols, convert a copy - `pub.data.transform_keys(&:to_sym)`, or
`pub.data.with_indifferent_access` in Rails - and send the original.

A String is a JSON string. JSON you already have, or encode with rules of your
own - dates, decimals, a faster encoder - goes in a `JSON::Fragment`, sent as it
is, also inside a Hash:

```ruby
client.publish(channel: "news", data: JSON::Fragment.new(row["payload_json"]))
client.publish(channel: "news", data: { meta:, doc: JSON::Fragment.new(json) })
```

A payload which is not JSON - NaN, a `Time`, a binary (ASCII-8BIT) string,
invalid UTF-8, a Hash with Integer keys - raises `Cent::InvalidRequestError`
naming where it is, before anything is sent. Binary data goes base64-encoded
in the `b64` fields, such as `b64data`.

Write integers which may pass 2^53 - a 64-bit ID, say - as JSON strings:
browsers and JavaScript backends decode JSON numbers as doubles, and round
larger integers silently.

## Timeouts

Each call takes `timeout:`, in seconds; without one, `request_timeout` - ten
seconds by default - bounds it:

```ruby
client.info(timeout: 0.5)
```

The timeout bounds the whole call - connecting, TLS, sending, and the reply,
also one trickling in, headers and all. However a call times out, it raises
`Cent::TimeoutError`. `broadcast_with_retry` makes several requests in one
call: its `timeout:` bounds them all, waits between them included, and
`attempt_timeout:` each one.

## Errors

| Error | Meaning |
|---|---|
| `Cent::ApiError` | Centrifugo refused the request or failed to carry it out: `code`, `server_message`, `temporary?`. Known codes are subclasses: `UnknownChannelError`, `NotFoundError`, `BadRequestError`, `NotAvailableError`, `TooManyRequestsError`, `InternalError`... |
| `Cent::BroadcastFailedChannelsError`, `Cent::BatchFailedCommandsError` | some parts of a broadcast or batch failed - see below |
| `Cent::HTTPError` | the request did not reach the API method: `status_code`, `body`, `headers`; `UnauthorizedError` for rejected credentials |
| `Cent::DecodeError` | the reply was not Centrifugo's - usually `api_endpoint` points elsewhere |
| `Cent::InvalidRequestError` | the client could tell the request is wrong and did not send it |
| `Cent::InvalidConfigError` | the client was not created: the message names the option and the fix |
| `Cent::NetworkError`, `Cent::TimeoutError`, `Cent::ClosedError` | as their names say |

All are `Cent::Error`. Centrifugo adds error codes over time: an unknown code
is still an `ApiError`, so rescue the codes you handle and treat the rest by
class.

## Retries

`Cent.retryable?(err)` reports whether a new attempt, with time left, may
succeed: the error came from a temporary condition - a broker being
unavailable, a rate limit, the network - not from the request.

A temporary error does not mean nothing was done: after a timeout, or even an
internal error, the publication may have happened. So retry a publication only
with an `idempotency_key`, and back off between a bounded number of attempts:

```ruby
backoff = Cent.exponential_backoff(0.2, 5.0)
attempt = 0
begin
  attempt += 1
  # The same key on every attempt: a publication which happened in an
  # earlier attempt, even one reported as failed, is not published again.
  client.publish(channel: "orders:42", data:, idempotency_key: "order-42-paid")
rescue Cent::Error => e
  raise unless Cent.retryable?(e) && attempt < 3

  sleep(backoff.(attempt))
  retry
end
```

Choosing keys:

- One key per publication or broadcast, reused only to retry that same one. A
  broadcast needs one key, not one per channel.
- Centrifugo remembers a key per channel, for five minutes by default. A retry
  within that time is answered with the first result and not published again -
  and so is a *different* publication into the same channel under the same
  key. A key built from an ID must name the event too: `order-42-paid`, not
  `order-42`.
- The memory, Redis and PostgreSQL brokers keep keys. The NATS broker ignores
  them, so with it a retry publishes again.

Retry a broadcast with `broadcast_with_retry` rather than a loop: see below.

## Broadcast and batch

`broadcast` publishes the same data into many channels in one request; a batch
sends many commands at once. Both raise unless every part succeeded:

```ruby
client.broadcast(channels: ["user:1", "user:2"], data: { text: "hello" }, idempotency_key: message_id)

batch = client.new_batch
pub = batch.publish(channel: "news", data:)
stats = batch.presence_stats(channel: "news")
batch.send
pub.value.offset        # each command has its own result, or raises its own error
stats.value.num_clients
```

Parts succeed or fail on their own. When Centrifugo carried the request out
and some parts failed, up to all, it raises `BroadcastFailedChannelsError` or
`BatchFailedCommandsError`: its `failed` lists them, and its `result` holds
every part's outcome. Any other error means the request failed as a whole - the
network, the credentials, an invalid request - and no part got a reply; after a
timeout or a network error Centrifugo may still have carried it out.

A partial error is not an error of its parts: `rescue Cent::UnknownChannelError`
does not catch a broadcast in which a channel was unknown, nor one into a
single channel - use `publish` for one channel. To go on despite some failed
parts:

```ruby
begin
  client.broadcast(channels:, data:)
rescue Cent::BroadcastFailedChannelsError => e
  logger.warn("broadcast failed in #{e.result.failed.map(&:channel)}")
end
```

Retrying:

- a **broadcast**: `broadcast_with_retry` does it. It sends again only the
  channels which may still succeed, all attempts with one `idempotency_key` -
  made for the call when none is given - and returns every channel's last
  outcome, as `broadcast` does:

  ```ruby
  res = client.broadcast_with_retry(channels:, data:, max_attempts: 5, attempt_timeout: 2, timeout: 10)
  ```

  By default it retries once, after about 100 milliseconds. Its block, when
  given, is called after each failed attempt which will be retried, with a
  `Cent::BroadcastAttempt` - the channels to retry and their errors: it returns
  the seconds to wait before the next attempt - or nil for the default
  backoff - and may log or count meanwhile; it raises to stop. A `HTTPError`
  in `attempt.error` carries the response's `headers`: wait at least its
  `retry-after` to honour one.

  ```ruby
  backoff = Cent.exponential_backoff(0.2, 5.0)
  client.broadcast_with_retry(channels:, data:) do |attempt|
    logger.info("attempt #{attempt.attempt}: #{attempt.retry.size} channels to retry")
    backoff.(attempt.attempt)
  end
  ```

  `res.idempotency_key` is the key the attempts used: to retry the broadcast
  later, after it gave up - from a job, say - send it with that key. Repeating
  `broadcast` on any error would instead send it to every channel again, those
  which already got it included.

  It waits between attempts with `sleep`, in the thread calling it. In a web
  request, give it a short `timeout:`, so that a Centrifugo which is down does
  not hold the request for every attempt's `request_timeout`. Retry for longer
  from a job - Sidekiq, Active Job - with an `idempotency_key` of its own, so
  that the job retries under the same key whichever way the call failed:

  ```ruby
  class BroadcastJob
    include Sidekiq::Job

    def perform(channels, data, key)
      CENTRIFUGO.broadcast_with_retry(channels:, data:, idempotency_key: key, max_attempts: 3)
    rescue Cent::BroadcastFailedChannelsError => e
      retried = e.retryable_channels
      self.class.perform_in(30, retried, data, key) unless retried.empty?
    end
  end
  ```
- a **batch**: build a new one, with the same keys, from the commands
  `e.failed` lists with a retryable error. A batch is sent once.

`new_batch` runs the commands one by one, in order; `parallel: true` runs them
concurrently. Centrifugo PRO sends a batch's publications to its broker
together: each channel's publications still take effect in order, but
publications into different channels may not, unless the namespace sets
`publication_grouping_disabled`.

## Automatic batching

With `auto_batch`, calls made concurrently - from Puma threads, Sidekiq
workers, fibers - go out together once enough requests are in flight, with no
delay otherwise, since nothing waits for a timer:

```ruby
client = Cent::Client.new(api_endpoint:, api_key:, auto_batch: Cent::AutoBatch.new(max_in_flight: 8))
```

Every call still gets its own result or error, and keeps its own timeout. Calls
sharing a batch share its request, though: if the request itself fails - the
network, a body too large for a proxy in front of Centrifugo (nginx refuses
bodies over 1 MB by default) - every call in it fails. A smaller
`max_in_flight` batches more; 8 suits most applications.

A batch belongs to no single caller: it runs in a thread of its own, with an
empty fiber storage, carrying no caller's `Fiber[]` values. `batch_context`
gets the callers' fiber storages and a block sending the batch - to tag its
logs, or start a tracing span linking each caller's:

```ruby
batch_context = lambda do |callers, &send_batch|
  Rails.logger.tagged("batch of #{callers.filter_map { it[:request_id] }.join(",")}") { send_batch.call }
end
```

## Authentication

`api_key` is sent in the `X-API-Key` header. `bearer_token_func` instead sends a
token as `Authorization: Bearer`, for Centrifugo PRO's JWKS authentication - it
is called for every request, so return a cached token. Leave both unset when
mutual TLS, set up in `http_options`, or a proxy authenticates instead.

To sign the tokens yourself, `Cent::Token::ApiTokens` issues them and reuses
each for half its lifetime:

```ruby
api_tokens = Cent::Token::ApiTokens.new(
  key: api_key,   # its own key - never one of the client tokens
  audience: "centrifugo-api", scope: ["centrifugo:api"]
)
client = Cent::Client.new(api_endpoint: "https://centrifugo.example.com/api",
                          bearer_token_func: api_tokens.method(:token))
```

Centrifugo PRO accepts a token signed with any key of `http_api.jwks.endpoint`,
and checks the audience, issuer and scope only when configured to. So keep API
tokens apart from the connection and subscription tokens your users hold - or
any user can call the server API with their connection token:

- publish the API keys with `Cent::Endpoints::JWKS.new(*api_keys)` at an
  endpoint of their own, not the one of `client.token.jwks_public_endpoint`;
- set `http_api.jwks.audience` and `http_api.jwks.scope` to values only API
  tokens carry - `Cent::Token.api` refuses claims with neither.

The API keys rotate as client keys do: see [Key rotation with JWKS](#key-rotation-with-jwks).

Rejected credentials make every call raise `Cent::UnauthorizedError`.

## HTTP, tracing and metrics

cent sends requests with Net::HTTP, from Ruby itself: up to 256 connections to
a host are kept alive, idle ones closed after 50 seconds; redirects are never
followed. TLS and other settings of the connections go in `http_options`:

```ruby
client = Cent::Client.new(api_endpoint:, http_options: { ca_file: "/etc/ssl/centrifugo-ca.pem",
                                                         cert: client_cert, key: client_key })
```

`http_client` sends requests another way - another HTTP library, or a fake in
tests: a callable taking the URL, the headers, the body and the seconds left,
and returning `[status, headers, body]`.

Tracing comes from the HTTP library: OpenTelemetry's Net::HTTP
instrumentation, `opentelemetry-instrumentation-net_http`, traces every
request. `on_request` is told of every request - method, commands and how many
failed, duration, status, error - for metrics without a dependency of cent's:

```ruby
on_request = ->(info) { StatsD.measure("centrifugo.#{info.method}", info.duration * 1000) }
```

## Shutdown

`client.close` refuses new calls with `ClosedError` and waits for the ones in
progress, automatic batches included, so that what was accepted is sent before
the process exits - from `at_exit`, Puma's `on_worker_shutdown` or Sidekiq's
`on(:shutdown)`. With `timeout:` it raises `Cent::TimeoutError` when calls are
still in progress then.

## HTTP handlers

The proxy handlers and the endpoints client SDKs call are Rack apps, which
Rails, Sinatra, Hanami and every Rack server mount:

```ruby
# config/routes.rb
mount CONNECT_HANDLER, at: "/centrifugo/connect"
```

Each takes a block and calls it with what the request asks for, and with a
`Cent::HTTPRequest`: the method, headers, query and the server's own request
in `raw` - the Rack env. Mounted in Rails, a handler runs behind the app's
middleware, so the env carries the session: for the connect proxy, with
`Cookie` in Centrifugo's `http_headers`, Devise's user is
`http.raw["warden"].user`.

Proxy handlers are mounted in every framework: Centrifugo calls them, and the
user is in the request. The endpoints client SDKs call - tokens, shared poll
signatures - suit an app without its own authentication layer: plain Rack,
Sinatra, Roda, a token service. In Rails, write those as controller actions
calling `Cent::Token`: see [Rails](#rails).

Any other server calls the framework-free core, `handle(method, headers, body)`,
which returns a `Cent::HTTPResponse`.

Pass every handler an `on_error:`, told of the request and the error whenever
the handler answers 500 or 400. Without it, an error in your block is answered
with 500 and logged nowhere: the handler catches it to answer Centrifugo, so it
never reaches your framework's error reporting.

## Proxy

`Cent::Proxy` is the backend side of Centrifugo's HTTP proxy, which calls your
application when a client connects, subscribes, publishes or makes an RPC
call: a handler per proxy type, taking a block.

```ruby
REPORT = ->(_http, err) { logger.error(err) }

SUBSCRIBE_HANDLER = Cent::Proxy::SubscribeHandler.new(on_error: REPORT) { |req, http| Proxy.subscribe(req, http) }

module Proxy
  # req: a Cent::Proxy::SubscribeRequest; http: the Cent::HTTPRequest, its
  # headers those Centrifugo passed on.
  def self.subscribe(req, _http)
    raise Cent::Proxy::ProxyError.new(403, "permission denied") unless can_read?(req.user, req.channel)

    {}   # a Cent::Proxy::SubscribeResult, or a Hash of its fields
  end
end
```

Return a result to accept the request, raise `Cent::Proxy::ProxyError` to
reject it with an error the client receives, or `Cent::Proxy::Disconnect` to
close the client's connection; any other error fails the request, and goes to
`on_error` to be logged - without `on_error`, nowhere. A block calling a method,
as here, keeps the logic where it can `return` early and be tested alone; see
[Rails](#rails) for where each part goes there. Keep proxy endpoints reachable by Centrifugo only:
whoever can call them can claim to be any user.

## Tokens

`Cent::Token` issues the JWTs Centrifugo authenticates clients with -
connection and subscription tokens, with Centrifugo's claims, signed with
HMAC, RSA, ECDSA or Ed25519 from Ruby's OpenSSL - and `Cent::Endpoints` serves
the endpoints the `getToken` callbacks of client SDKs call, in a Rack app or
Sinatra (in Rails, a controller action: see [Rails](#rails)):

```ruby
KEY = Cent::Token::Key.hmac(ENV.fetch("CENTRIFUGO_TOKEN_SECRET"))   # client.token.hmac_secret_key

CONNECTION_TOKEN = Cent::Endpoints::ConnectionToken.new(on_error: REPORT) do |req|
  user = session_user(req.raw)
  raise Cent::Endpoints::Unauthorized unless user   # 403: the client stops asking

  Cent::Token.connection(KEY, user: user.id.to_s, expires_at: Time.now + 3600)
end
```

An expiry is required: a `Time`, or `:never` for a token accepted forever.
`Cent::Endpoints::SubscriptionToken` serves subscription tokens the same way,
its block given the channel the client asks for. To rotate keys without
restarting Centrifugo, see [Key rotation with JWKS](#key-rotation-with-jwks).

## Key rotation with JWKS

By default Centrifugo verifies tokens with a single key from its
configuration: `client.token.hmac_secret_key`, or an RSA, ECDSA or Ed25519
public key. Changing that key means restarting Centrifugo, and from that moment
it refuses every token signed with the old key. To rotate keys without that,
your application can serve the keys itself, as a JSON Web Key Set (JWKS) at
Centrifugo's `client.token.jwks_public_endpoint`. Each key in the set has an
ID, and Centrifugo verifies a token with the key its `kid` header names:

```ruby
# An ID for each key, never reused for another key: Centrifugo caches keys by ID.
key = Cent::Token::Key.from_pem(File.read("keys/2026-10.pem")).with_key_id("2026-10")

JWKS = Cent::Endpoints::JWKS.new(key)   # mounted at the URL of jwks_public_endpoint
token = Cent::Token.connection(key, user: "42", expires_at:)
```

```json
{"client": {"token": {"jwks_public_endpoint": "https://app.example.com/centrifugo/jwks"}}}
```

Only RSA, ECDSA and Ed25519 keys can go in a set: an HMAC secret has no public
part to publish. Once `jwks_public_endpoint` is set, Centrifugo verifies tokens
with the set only, and refuses tokens signed with the key it was configured
with before. So moving to a JWKS is a one-time restart.

How Centrifugo reads the set:

- when a token names a key ID Centrifugo doesn't know, it fetches the set
  again, at most once every 5 seconds;
- it keeps the keys it fetched for 5 minutes (an hour before Centrifugo
  v6.10.2), so a key dropped from the set stops working within that time;
- when the endpoint can't be reached, it keeps using the keys it already has;
- a token whose key isn't in the set is refused as expired, and the client SDK
  asks for a new token.

Rotate a key in three steps. Each step is one deploy of your application, and
every instance should finish a step before any instance moves to the next:

1. **Publish the new key alongside the current one,** and keep signing with
   the current one: `Cent::Endpoints::JWKS.new(current, new)`.
2. **Sign with the new key.** Centrifugo fetches the set the first time it sees
   the new ID.
3. **Drop the old key** once every token it signed has expired: wait longer
   than the longest `expires_at` you give.

If a key leaks, do all three steps now, without waiting in step 3. Within 5
minutes Centrifugo refuses new connections with the leaked key's tokens.
Clients that connected before stay connected until their tokens expire:
disconnect them with the server API if needed.

Centrifugo PRO's API tokens rotate the same way, from a set of their own at
`http_api.jwks.endpoint` (see [Authentication](#authentication)).
`Cent::Token::ApiTokens.new(current_key: -> { ... })` takes the key to sign
with from a callable, so it can switch to the new key at step 2. Each API token
is reused for half its `ttl`, so in step 3 wait at least `ttl` after the
switch.

## Shared poll signatures

Clients tracking keys of a [shared poll](https://centrifugal.dev/docs/server/shared_poll)
channel need a signature from the backend. `Cent::SharedPoll.sign` makes one,
and `Cent::Endpoints::SharedPollSignature` serves the endpoint a subscription's
`getSignature` callback calls - in Rails, an action answering
`{signature:, keys:}` does the same:

```ruby
SIGNATURE = Cent::Endpoints::SharedPollSignature.new(on_error: REPORT) do |channel, keys, req|
  user = session_user(req.raw)
  allowed = readable_keys(user, channel, keys)   # the rest are revoked
  [allowed, Cent::SharedPoll.sign(SECRET, user: user.id.to_s, channel:, keys: allowed, expires_at: Time.now + 3600)]
end
```

Shared poll subscriptions are experimental in Centrifugo, and this part
follows their changes.

## Commands for async consumers

`Cent::Command.publish(...)` - and a method like it for every API method -
checks a call as a client would and encodes it, for Centrifugo's
[async consumers](https://centrifugal.dev/docs/server/consumers): its `method`
and `payload` for an outbox table, or `to_json` for a Kafka message.

```ruby
cmd = Cent::Command.publish(channel: "news", data: { text: "hi" })
CentrifugoOutbox.create!(method: cmd.method, payload: cmd.payload, partition: 0)
```

A consumer keeps commands in order only within a partition: to keep a
channel's commands in order, derive their partition from the channel the same
way in every writer.

## Streaming AI output

Publish a model's output into a channel of its own, in a namespace with history
and recovery, from one thread - each publish waiting for the previous one - in
chunks of what arrived every 50 ms or so, not a publication per token. See
[Centrifugo for AI apps](https://centrifugal.dev/docs/getting-started/ai_apps),
which also covers sizing history for a whole response.

## More

- The API reference, every class, method and field, from the YARD docs:
  [rubydoc.info/gems/cent](https://rubydoc.info/gems/cent), or `yard server`
  locally.
- Docs for agents and LLMs: [centrifugal.dev/llms.txt](https://centrifugal.dev/llms.txt),
  an index of the current (v6) documentation.
- Development: see [AGENTS.md](AGENTS.md); `bundle exec rake check` runs what
  CI does but the integration tests, `bundle exec rake test:integration` those.

MIT license. Centrifugo PRO, which the methods marked "Centrifugo PRO only"
call, is commercial software under its own
[license](https://centrifugal.dev/license).
