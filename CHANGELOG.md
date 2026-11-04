v5.0.0
======

cent 5 is a rewrite, to the [Centrifugo server SDK specification](https://github.com/centrifugal/gocent/blob/master/spec.md), version 0.3, which gocent and the other Centrifugo server SDKs follow too. It needs Ruby 3.4 or newer and supports Centrifugo v6 - OSS and PRO; the map and shared poll methods need v6.8.0 or newer, `ApiError#temporary?` v6.10.0 or newer. The json gem is its only dependency: Faraday and jwt are gone. Migrating from cent 4: see [MIGRATING.md](https://github.com/centrifugal/rubycent/blob/master/MIGRATING.md); an application which needs time to move can stay on `gem "cent", "~> 4.0"`.

**Client and calls**

* A method for every API method, generated from Centrifugo's `api.proto` with its documentation - the map, shared poll and Centrifugo PRO methods included - taking its request's fields as keyword arguments: `client.publish(channel: "news", data: ...)`. A nested message is its class or a Hash of its fields; an unknown keyword or field is refused, with a suggestion.
* Results are `Data` objects - `res.offset`, not `res["result"]["offset"]` - with `to_h`, `as_json` and `to_json` giving wire names, nested results too: `render json: result` in Rails.
* Fields the protos mark required are required keywords, of the methods and of the nested messages' classes - `Cent::RateLimitPolicy.new(rate:, interval_ms:)` - and are checked for a value before sending: given `nil`, `""`, `0`, `[]` or a message with nothing set, a call raises `InvalidRequestError` naming the field's path, `limit_strategy.rate_limit.policies[0].rate is required`.
* A field at its zero value is not sent, nor a nested message with nothing set - but for `device_update`'s `user_update`, `timezone_update`, `locale_update` and `meta_update`, sent whenever given, even empty: `timezone_update: { timezone: "" }` clears the timezone, `user_update: { user: "" }` detaches the devices from their user. `BoolValue` fields are `true`, `false` or nil, which leaves the server's setting alone.
* The client is created once and shared: safe for concurrent use from threads, and under a fiber scheduler (Async, Falcon) calls wait without blocking other fibers. A client used in a forked process - Puma's `preload_app!`, a Sidekiq swarm - starts its own connections and batch threads there.
* Its configuration is checked when it is created, `InvalidConfigError` naming the option and the fix: `api_endpoint:` (required, no default) or `api_endpoint_func:`, `api_key:` (nil for none) or `bearer_token_func:`, `headers:`, `request_timeout:`, `http_options:`, `http_client:`, `auto_batch:`, `on_request:`, `batch_context:`. `inspect` hides credentials.
* An endpoint from `api_endpoint_func`, or a token from `bearer_token_func`, which cannot be sent fails the call with `InvalidConfigError` before sending. An exception of either function's own fails the call with `Cent::FunctionError`: its `function` is the option's name, its `cause` the exception, and `Cent.retryable?` judges it by that cause.
* Net::HTTP connections kept alive in a pool, up to 256 to a host, idle ones closed after 50 seconds. Redirects are not followed: a redirect is an `HTTPError` hinting to check `api_endpoint`'s scheme and path. `http_options:` for TLS settings, `http_client:` for another HTTP library or a fake in tests.
* `close` refuses new calls with `ClosedError` and waits for those in progress, automatic batches included; with `timeout:` it raises `TimeoutError` when they have not finished.

**Timeouts**

* `request_timeout` - 10 seconds, also when nil - bounds every call: connecting and TLS, sending, and the reply, however slowly it comes. A watchdog thread finishes a connection at its call's deadline through Net::HTTP's public `finish`, so a reply's headers trickling in no longer outlast it; it starts afresh in a forked process. However a call times out, it raises `Cent::TimeoutError`.
* A call's `timeout:` replaces `request_timeout` for that call, longer or shorter. Ruby has no deadline a call runs under for cent to read: a `Timeout.timeout` around a call only cuts it short.
* A timeout cannot be turned off: `request_timeout: 0` is refused with `InvalidConfigError`, and a call's `timeout: 0` with `InvalidRequestError`, as negative values are.

**Errors**

* `Cent::ApiError` with a subclass per known code - `UnknownChannelError`, `NotFoundError`, `BadRequestError`, `NotAvailableError`, `TooManyRequestsError`, `UnrecoverablePositionError`, `ConflictError`, `InternalError` - and `code`, `server_message`, `temporary?`; an unknown code is an `ApiError` itself.
* `HTTPError` (`status_code`, `body`, `headers`) and its `UnauthorizedError` for rejected credentials, `DecodeError`, `InvalidRequestError`, `InvalidConfigError`, `FunctionError`, `NetworkError`, `TimeoutError`, `ClosedError`, `BatchSentError`, `BatchNotSentError`: all `Cent::Error`. Messages carry hints: a 404 says whether the endpoint lacks the API prefix or the server is Centrifugo OSS answering a PRO method.
* Centrifugo's transport error mode gives the same errors as a 200 reply.

**Retries and idempotency**

* `Cent.retryable?(err)` says whether a new attempt may succeed; `Cent.exponential_backoff(base, limit)` for waits.
* `broadcast_with_retry` retries only the channels which failed for a temporary reason, with one `idempotency_key` on every attempt - made for the call when none is given - up to `max_attempts:`. `timeout:` bounds the whole call, waits included; `attempt_timeout:` is each attempt's own timeout, replacing `request_timeout`, the call's `timeout:` still ending an attempt sooner. Its block sees each failed attempt, returns the wait, and raises to stop.
* The docs say how to choose keys: one per publication, reused only to retry it, naming the event; the memory, Redis and PostgreSQL brokers keep keys, the NATS broker ignores them.

**Broadcast and batch**

* **Breaking:** a broadcast or batch in which some parts failed raises `BroadcastFailedChannelsError` or `BatchFailedCommandsError`, whose `result` holds every part's outcome and whose `failed` lists the failed parts, also when every part failed - cent 4 returned the response with the errors inside. Rescue them for best-effort sends: see [MIGRATING.md](https://github.com/centrifugal/rubycent/blob/master/MIGRATING.md#broadcasts-and-batches-now-raise). A broadcast or batch failing as a whole raises its own error instead, and every pending command of a batch returns that error.
* `client.new_batch` has the client's methods, each adding a command and returning a `Cent::Pending` whose `value` is its result; `batch.send`, once; `client.new_batch(parallel: true)` for Centrifugo to run the commands concurrently. A command the client can tell is invalid fails the batch before sending, naming its index.

**Automatic batching**

* `auto_batch: Cent::AutoBatch.new(max_in_flight:, max_batch_size:)`: below `max_in_flight` concurrent requests every call goes alone, at once; at the cap, calls queue and go out together in one batch request as one returns. Every call keeps its own result, error and timeout; a batch lasts until the latest of its calls' deadlines, at least `request_timeout`. `batch_context:` carries values such as a tracing span into the batch's thread.

**Pages and positions**

* `history_all`, `device_list_all`, `device_topic_list_all`, `user_topic_list_all` and `map_read_state_all` read page after page, with a block or as an `Enumerator` reading a page when the iteration reaches it. `page_timeout:` bounds each page's request, replacing `request_timeout` for it; an iteration lasts as long as the caller's loop.
* `history_all` yields each publication as a `Cent::HistoryItem`, with its `position`; it needs a `limit` of 1 or more and reads forward only. `map_read_state_all` yields each entry as a `Cent::MapStateItem`, with the state's `position`, and reads every page after the first at the first one's revision, so that a map reset between pages raises `UnrecoverablePositionError` instead of mixing two states.
* `position`, a `Cent::StreamPosition`, on the results of `publish`, `history`, `map_publish`, `map_remove`, `map_read_state` and `map_read_stream`: what a publish returned is the `since:` of the history call reading what came after it.

**Constants**

* A constant per value of the fields with a fixed set of values, named as the specification pins them for every SDK: `Cent::PROVIDER_FCM`, `Cent::PLATFORM_IOS`, `Cent::OP_ADD`, `Cent::STATUS_DELIVERED`, `Cent::KEY_MODE_IF_NEW`, `Cent::FILTER_NODE_OP_AND`, `Cent::CMP_EQ`, and in `Cent::Proxy` `PROTOCOL_JSON`, `ENCODING_BINARY`, `ALLOW_SUB`, `CAPABILITY_MATCH_WILDCARD`, `CHANNEL_EVENT_TYPE_OCCUPIED` and the rest. The fields stay strings: a value Centrifugo adds can be sent before cent names it.

**Payloads**

* `data`, `info`, `meta` and the other payloads are Ruby values `JSON.generate` writes, or a `JSON::Fragment` sent as its text; a payload from a reply sent back unchanged is the same JSON value. NaN, infinities, binary strings, invalid UTF-8 and values JSON cannot hold are refused before sending, naming where they are. nil is no payload: JSON null is `JSON::Fragment.new("null")`.

**Tokens and JWKS**

* `Cent::Token.connection` and `Cent::Token.subscription` with every claim Centrifugo reads - `profile:` included, the compression profile of Centrifugo PRO - signed with `Cent::Token::Key.hmac`, `.rsa`, `.ecdsa`, `.ed25519` or `.from_pem` (HS256, RS256, ES256/384/512, EdDSA) from Ruby's OpenSSL. An expiry is required: a `Time`, or `:never` chosen explicitly.
* `Cent::Token.jwks(*keys)` and the `Cent::Endpoints::JWKS` Rack app serve the public keys for Centrifugo's [`client.token.jwks_public_endpoint`](https://centrifugal.dev/docs/server/authentication), for key rotation without a restart.

**API tokens (Centrifugo PRO)**

* `Cent::Token.api` signs server API tokens; `Cent::Token::ApiTokenSource` issues them for `bearer_token_func:`, reusing each for half its lifetime, its key fixed or from `current_key:` as keys rotate.

**Endpoints for client SDKs**

* `Cent::Endpoints::ConnectionToken`, `SubscriptionToken` and `SharedPollSignature`: the endpoints the `getToken` and `getSignature` callbacks of client SDKs call, as Rack apps with a framework-free core. Raising `Cent::Endpoints::ForbiddenError` answers 403, on which client SDKs stop asking - they report it as their `UnauthorizedError`; it is not `Cent::UnauthorizedError`, the API refusing your credentials.

**Shared poll**

* `Cent::SharedPoll.sign` for shared poll signatures, its expiry required: a `Time`, or `:never`.

**Proxy handlers**

* `Cent::Proxy`: a handler for every proxy type - `ConnectHandler`, `RefreshHandler`, `SubscribeHandler`, `PublishHandler`, `RPCHandler`, `SubRefreshHandler`, `MapPublishHandler`, `MapRemoveHandler`, `SharedPollRefreshHandler`, and Centrifugo PRO's `NotifyCacheEmptyHandler` and `NotifyChannelStateHandler` - with the request and result types generated from `proxy.proto`, `ConnectResult#profile` included. A block returns a result, or raises `Cent::Proxy::ProxyError` or `Cent::Proxy::Disconnect`; anything else, or a block returning nil, is a 500 reported to `on_error:`. Each is a Rack app.

**Commands for async consumers**

* `Cent::Command.publish(...)` and a method like it for every API method, checked as a call is: `method` and `payload` for an outbox table, `to_json` for a Kafka message, `as_json` with the payload as a Hash.

**Observability**

* `on_request:` is called after every HTTP request with a `Cent::RequestInfo`: method, commands, failed, automatic batch or not, duration, status, error.

**Testing**

* A fake `http_client:` answers as Centrifugo does, without stubbing HTTP. `Cent::Pending.resolved` and the public constructors of `BroadcastFailedChannelsError`, `BatchFailedCommandsError`, `BroadcastResult` and `ChannelResult` make test doubles of your own.

3.0.0
=====

Not using changelog anymore. See [Github releases](https://github.com/centrifugal/rubycent/releases) now.

2.2.0
=====

* Fix `ArgumentError: wrong number of arguments` when creating `ResponseError` in Ruby 3, [#21](https://github.com/centrifugal/rubycent/pull/21)

2.1.0
=====

* Increase Faraday dependency's maximum version to 3.0.0 [#19](https://github.com/centrifugal/rubycent/pull/19)

2.0.2
=====

* Loosen JWT dependency version requirement: `~> 2.2` instead of `~> 2.2.1`.

2.0.1
=====

* Weaken faraday dependency: require faraday version >1.0.0.

2.0.0
=====

* Complete rewrite of a Ruby Client to work with Centrifugo V2 Server API

1.2.0
=====

* update assets to latest library versions: SockJS to 1.1.1 and centrifuge-js to 1.3.7
