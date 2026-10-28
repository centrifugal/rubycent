# Working on cent

cent is the Ruby SDK for Centrifugo's HTTP server API, written to the
[Centrifugo server SDK specification](https://github.com/centrifugal/gocent/blob/v4_dev/spec.md),
whose reference implementation is gocent. Applications use it on their hot
paths, from Puma threads, Sidekiq workers and fibers, so it has to be correct
under concurrency and hard to misuse. Read this before changing code.

## Layout

| Path | What |
|---|---|
| `proto/api.proto`, `proto/proxy.proto` | Copies of Centrifugo's protos, from a released tag (`CENTRIFUGO_REF=v6.10.2 bundle exec rake proto:sync`) |
| `gen/` | The generator: `proto.rb` parses the protos, `generate.rb` writes `lib/cent/generated/` |
| `lib/cent/generated/` | Generated - never edited: the result and message types, the methods of Client, Batch and Command (`methods.rb`), the proxy types |
| `lib/cent/client.rb` | `Client`: configuration, the request path, broadcast and its retry, close |
| `lib/cent/http.rb` | The default transport: a pool of Net::HTTP connections, each request bounded by one deadline |
| `lib/cent/wire.rb`, `lib/cent/payload.rb`, `lib/cent/reply.rb` | Encoding requests, payloads, decoding replies, the rules checked before sending |
| `lib/cent/errors.rb` | The errors and `Cent.retryable?` |
| `lib/cent/broadcast.rb`, `lib/cent/batch.rb`, `lib/cent/auto_batch.rb`, `lib/cent/retry.rb` | Broadcast results, batches, automatic batching, backoff |
| `lib/cent/handler.rb` | The HTTP handlers' framework-free core and their Rack adapter |
| `lib/cent/endpoints.rb`, `lib/cent/proxy.rb`, `lib/cent/token.rb`, `lib/cent/shared_poll.rb`, `lib/cent/command.rb` | Endpoints for client SDKs, proxy handlers, tokens, shared poll signatures, commands |
| `test/`, `test/integration/` | Unit tests against a fake Centrifugo and a local HTTP server; integration tests against a real Centrifugo |
| `testdata/` | The Centrifugo config and the Centrifugo PRO compose file the integration tests use |

## Invariants

These are not preferences. A change that breaks one is wrong even if every test
passes; if you find yourself about to break one, stop and say so instead.

1. **The generated files are never edited.** Change `proto/` or `gen/`, then
   `bundle exec rake generate`; `rake generate:check` fails when they are
   stale. The generator's output passes RuboCop as it is.
2. **A call raises unless it did everything asked.** A broadcast or batch in
   which some parts failed raises `BroadcastFailedChannelsError` or
   `BatchFailedCommandsError`, whose `result` holds every part's outcome. A
   partial error is never an `ApiError` of its parts - also with one channel.
3. **Errors follow Centrifugo's model.** A Centrifugo error is an `ApiError`,
   raised as the subclass of its code when the code is known, and as `ApiError`
   itself otherwise. Centrifugo's transport error mode gives the same error as a
   200 reply.
4. **One deadline per call.** Its `timeout:`, or `request_timeout`, bounds the
   whole call - the endpoint and token functions, connecting and TLS, the reply
   read. Net::HTTP bounds each read on its own, so `HTTP::Connection` swaps its
   socket, in Net::HTTP's `on_connect` hook, for a `DeadlineIO` whose every read
   and write is bounded by the time left: a reply trickling in - headers
   included - stops at the deadline. Any timeout raises `Cent::TimeoutError`.
5. **A payload is carried exactly.** A payload from a reply sent back unchanged
   is the same JSON value; a `JSON::Fragment` is sent as its text, checked to
   be JSON; NaN, infinities, binary strings, invalid UTF-8 and values JSON
   cannot hold never leave the client.
6. **Automatic batching never delays a call below `max_in_flight`**, never
   gives a caller a reply which is not its own, never sends a call whose caller
   gave up while it queued, and `close` waits for batches whose callers left. A
   batch runs in a thread of its own with an empty fiber storage, which carries
   callers' values only through `batch_context`.
7. **The client, a batch and `Command` take the same arguments**, generated
   together; `test_client_batch_and_command_take_the_same_arguments` checks it.
8. **A handler answers with exactly one of result, error and disconnect,** as
   its proxy type can carry them; anything else is a 500 reported to
   `on_error`.

## Running things

```
bundle install
bundle exec rake check              # generated code, RuboCop, unit tests, docs: what CI runs
bundle exec rake test:integration   # against Centrifugo on :8100
```

The integration tests need a Centrifugo set up as `testdata/` says:

```
docker compose -f testdata/centrifugo-pro.compose.yml up -d --wait
RUBYCENT_TEST_PRO=1 bundle exec rake test:integration
```

They serve the proxy handlers on port 3100 and an API JWKS on 3101 of the host,
which Centrifugo reaches as `host.docker.internal`.

`rake docs` fails unless every public class, method and constant is documented:
internals are marked `@api private`, which `.yardopts` hides.

## Updating to a new Centrifugo API

1. `CENTRIFUGO_REF=vX.Y.Z bundle exec rake proto:sync` - always a released tag.
2. Read the diff of `proto/`: a removed field is a breaking change.
3. `bundle exec rake check`, then the integration tests against the new
   release.
4. Bump the Centrifugo image in `.github/workflows/ci.yml` and
   `testdata/centrifugo-pro.compose.yml`, and the versions table in the README
   when a feature needs the new release.

## Releasing

Set `Cent::VERSION` in `lib/cent/version.rb`, add the CHANGELOG entry, and push
a tag `vX.Y.Z`: `release.yml` checks the tag against the version, runs the
tests, pushes the gem to RubyGems with the `RUBYGEMS_API_KEY` secret and
creates the GitHub release.

## Things that look wrong but are deliberate

- **Net::HTTP, not Faraday.** No dependency whose major version an application
  must match (spec 3.4, Stable), and one deadline per request, which Faraday's
  per-operation timeouts cannot give. `http_client:` takes any other library.
- **Keyword arguments, a method per API method**, as the spec says for Ruby
  (3.3): `client.publish(channel: ..., data: ...)`, `batch.publish(...)`,
  `Cent::Command.publish(...)`. Ruby refuses an unknown keyword itself. A
  nested message is its class or a Hash of its fields, unknown ones refused
  with a suggestion.
- **`Data` classes for results**, `class X < Data.define(...)`: immutable, with
  keyword defaults, and how YARD documents them (RuboCop's
  `Style/DataInheritance` is off).
- **A member named `method`** on `RequestInfo`, `Command`, `FailedCommand`,
  `HTTPRequest` and the RPC proxy's request: the spec's word, on value objects
  where shadowing `Object#method` costs nothing.
- **`Batch#send` is still `Object#send`** when given a method name: sending
  the batch is the spec's word, and reflection keeps working.
- **`Pending#value`**, as `Thread#value`: the outcome, or its error raised.
- **`broadcast_with_retry` takes a block** for the spec's `on_attempt_err`: it
  returns the wait, or nil for the default, and raises to stop - its error's
  cause the attempt's. A block which only logs cannot stop the retries by
  accident.
- **`expires_at: :never`**: an expiry is one value, chosen explicitly; Ruby's
  closest sum type is a Time or a Symbol.
- **A generated type named `Process`** shadows Ruby's inside `Cent`: write
  `::Process` there.
- **Only partial errors carry `result`.** A broadcast or batch failing as a
  whole raises its own error: its result would only say that every part failed
  with it.
- **No `wait(deadline, d)` helper** (spec 6): Ruby has no deadline object;
  `broadcast_with_retry` bounds its own waits by its timeout.
- **`rpc` is not offered**: it calls server API extensions, which Centrifugo
  does not provide.
- **`BoolValue` fields are `true`, `false` or nil.** nil leaves the server's
  setting alone, which `false` cannot say.
- **An automatic batch always goes to `/api/batch`**, even with one command,
  and with `parallel: true`: its calls were made concurrently.
