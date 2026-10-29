v5.0.0
======

A rewrite to the [Centrifugo server SDK specification](https://github.com/centrifugal/gocent/blob/v4_dev/spec.md).
Migrating from cent 4: see [MIGRATING.md](MIGRATING.md).

* Ruby 3.4 or newer, Centrifugo v6. The json gem is the only dependency: Faraday and jwt are gone.
* Every API method takes its request's fields as keyword arguments - `client.publish(channel: "news", data: ...)` - on the client, a batch and `Cent::Command` alike; results are `Data` objects, with `to_h` and `to_json` converting nested results too - `render json: result` in Rails. All generated from Centrifugo's `api.proto`, with its documentation: every API method, including the map and shared poll methods and those of Centrifugo PRO.
* Net::HTTP connections kept alive in a pool; one deadline per call - its `timeout:`, or `request_timeout` - over connecting, each read and write and the reply's body. Redirects are not followed. Calls under a fiber scheduler (Async, Falcon) wait without blocking other fibers. `http_options:` for TLS settings, `http_client:` for another HTTP library or a fake in tests.
* **Breaking:** a broadcast or batch in which some parts failed raises `BroadcastFailedChannelsError` or `BatchFailedCommandsError`, carrying every part's outcome - cent 4 returned the response with the errors inside. Rescue them for best-effort sends: see [MIGRATING.md](MIGRATING.md#broadcasts-and-batches-now-raise).
* Errors: `ApiError` with a subclass per known code, `HTTPError`, `UnauthorizedError`, `DecodeError`, `InvalidRequestError`, `InvalidConfigError`, `NetworkError`, `TimeoutError`, `ClosedError`; `Cent.retryable?`; hints in messages; Centrifugo's transport error mode.
* Payloads: Ruby values or `JSON::Fragment`, sent as the same JSON value; NaN, binary strings, invalid UTF-8 and values JSON cannot hold refused before sending, naming where they are; a payload from a reply sent back unchanged is the same JSON value.
* `broadcast_with_retry`, `Cent.exponential_backoff`; automatic batching of concurrent calls (`auto_batch:`); `on_request:` for metrics; `close` waiting for calls in progress.
* `Cent::Command.publish(...)` and the like for Centrifugo's async consumers.
* `Cent::Token`: connection, subscription and Centrifugo PRO server API tokens with every claim (HS256, RS256, ES256/384/512, EdDSA), from Ruby's OpenSSL; JWKS; `ApiTokens`.
* `Cent::Endpoints`: the token and shared poll signature endpoints client SDKs call, and the JWKS endpoint. `Cent::Proxy`: a handler for every proxy type, generated from `proxy.proto`. Each is a Rack app, with a framework-free core.
* `Cent::SharedPoll.sign` for shared poll signatures.

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
