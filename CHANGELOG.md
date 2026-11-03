v5.0.0
======

A rewrite to the [Centrifugo server SDK specification](https://github.com/centrifugal/gocent/blob/master/spec.md).
Migrating from cent 4: see [MIGRATING.md](MIGRATING.md).

* Ruby 3.4 or newer, Centrifugo v6. The json gem is the only dependency: Faraday and jwt are gone.
* Every API method takes its request's fields as keyword arguments - `client.publish(channel: "news", data: ...)` - on the client, a batch and `Cent::Command` alike; results are `Data` objects, with `to_h` and `to_json` converting nested results too - `render json: result` in Rails. All generated from Centrifugo's `api.proto`, with its documentation: every API method, including the map and shared poll methods and those of Centrifugo PRO.
* Net::HTTP connections kept alive in a pool; one deadline per call - its `timeout:`, or `request_timeout` - over the whole request, a reply trickling in included. Redirects are not followed. Calls under a fiber scheduler (Async, Falcon) wait without blocking other fibers. `http_options:` for TLS settings, `http_client:` for another HTTP library or a fake in tests.
* **Breaking:** a broadcast or batch in which some parts failed raises `BroadcastFailedChannelsError` or `BatchFailedCommandsError`, carrying every part's outcome - cent 4 returned the response with the errors inside. Rescue them for best-effort sends: see [MIGRATING.md](MIGRATING.md#broadcasts-and-batches-now-raise).
* Errors: `ApiError` with a subclass per known code, `HTTPError`, `UnauthorizedError`, `DecodeError`, `InvalidRequestError`, `InvalidConfigError`, `NetworkError`, `TimeoutError`, `ClosedError`; `Cent.retryable?`; hints in messages; Centrifugo's transport error mode.
* Payloads: Ruby values or `JSON::Fragment`, sent as the same JSON value; NaN, binary strings, invalid UTF-8 and values JSON cannot hold refused before sending, naming where they are; a payload from a reply sent back unchanged is the same JSON value.
* `broadcast_with_retry`, `Cent.exponential_backoff`; automatic batching of concurrent calls (`auto_batch:`); `on_request:` for metrics; `close` waiting for calls in progress.
* `Cent::Command.publish(...)` and the like for Centrifugo's async consumers; `as_json` gives the payload as a Hash.
* `Cent::Token`: connection, subscription and Centrifugo PRO server API tokens with every claim (HS256, RS256, ES256/384/512, EdDSA), from Ruby's OpenSSL; JWKS; `ApiTokens`.
* `Cent::Endpoints`: the token and shared poll signature endpoints client SDKs call, and the JWKS endpoint. `Cent::Proxy`: a handler for every proxy type, generated from `proxy.proto`. Each is a Rack app, with a framework-free core.
* `Cent::SharedPoll.sign` for shared poll signatures, its expiry required: a `Time`, or `:never`.
* Fields the protos mark required are required keywords. A client used in a forked process - Puma's `preload_app!`, a Sidekiq swarm - starts its own connections and batch threads there. `api_key: nil` means no key; `inspect` hides credentials. `Cent::Pending.resolved` and the public constructors of the partial-failure errors make test doubles.
* Spec 0.3: a required field is checked for a value before sending - given `nil`, `""`, `0`, `[]` or a message with nothing set, a call raises `InvalidRequestError` naming its path, `limit_strategy.rate_limit.policies[0].rate is required`, where Centrifugo refused it with code 107 - and the required fields of nested messages are required keywords of their classes, `Cent::RateLimitPolicy.new(rate:, interval_ms:)`.
* Spec 0.3: `device_update`'s `user_update`, `timezone_update`, `locale_update` and `meta_update` are sent whenever given, even empty: `timezone_update: { timezone: "" }` clears the timezone, `user_update: { user: "" }` detaches the devices from their user. Any other message with nothing set is not sent.
* Spec 0.3: constants for the fields with a fixed set of values, named as the specification's table pins them for every SDK - `Cent::PROVIDER_FCM`, `Cent::OP_ADD`, `Cent::FILTER_NODE_OP_AND`, and in `Cent::Proxy` `FILTER_NODE_OP_AND`, `ENCODING_BINARY`, `CAPABILITY_MATCH_WILDCARD`, `CHANNEL_EVENT_TYPE_OCCUPIED` and the rest; the fields stay strings.
* Spec 0.3: `history_all`, `device_list_all`, `device_topic_list_all`, `user_topic_list_all` and `map_read_state_all` read page after page, with a block or as an `Enumerator`, `history_all` yielding each publication as a `Cent::HistoryItem` and `map_read_state_all` each entry as a `Cent::MapStateItem`, both with `position`; `position`, a `StreamPosition`, on every result holding an offset and an epoch: those of `publish`, `history`, `map_publish`, `map_remove`, `map_read_state` and `map_read_stream`.
* Spec 0.3: `Cent::Token.connection` takes `profile:`, and `Cent::Proxy::ConnectResult` has `profile`: the connection's compression profile (Centrifugo PRO).
* Spec 0.3: `request_timeout` bounds every call, and a call's `timeout:` replaces it, longer or shorter; `broadcast_with_retry`'s `attempt_timeout:` replaces it for each attempt, the call's `timeout:` still ending an attempt sooner. An automatic batch request may outlast a call's timeout, which still returns at it.
* **Breaking**, spec 0.3: `Cent::Endpoints::Unauthorized` is renamed `Cent::Endpoints::ForbiddenError` - the token and shared poll endpoints' 403, which client SDKs report as their `UnauthorizedError` - so that it is not mistaken for `Cent::UnauthorizedError`, the API refusing your credentials.
* Spec 0.3: a call whose `api_endpoint_func` returns an endpoint failing `api_endpoint`'s rules, or whose `bearer_token_func` returns an empty or malformed token, fails with `InvalidConfigError` before sending. An exception of either function's own fails the call with `Cent::FunctionError`, naming the function, the exception its `cause` - before, a network error there was a `NetworkError` and any other went through as it was.
* Before the release: `proto/` is from Centrifugo's master (centrifugal/centrifugo#1308, #1309, #1310), not yet tagged - sync it again from the release tag.

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
