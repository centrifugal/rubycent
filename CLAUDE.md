# CLAUDE.md

See [AGENTS.md](AGENTS.md). It is the guide for working on this gem and applies
here in full: the layout, the invariants, how to run the suite, how to update
to a new Centrifugo API, and the list of things that look wrong but are
deliberate.

Three points from it are worth repeating, because they are the ones most easily
lost:

- **Never edit `lib/cent/generated/`.** Change `proto/` or `gen/`, then run
  `bundle exec rake generate`.
- **Every call raises unless it did everything asked.** A broadcast or batch in
  which some parts failed raises `BroadcastFailedChannelsError` or
  `BatchFailedCommandsError`, carrying every part's outcome.
- **One deadline per call, through public APIs only**: the time left as
  Net::HTTP's timeouts, again before each body chunk; no hooks into its
  internals.

Run `bundle exec rake check` before reporting a change as done, and
`bundle exec rake test:integration` with Centrifugo running for a change to the
transport, errors, batching or handlers.
