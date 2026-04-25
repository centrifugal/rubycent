# frozen_string_literal: true

require 'faraday'
require 'cent/error'

module Cent
  # Cent::Client
  #
  # Ruby client for Centrifugo server HTTP API (Centrifugo v4+).
  #
  # Every API method returns the raw parsed response body from Centrifugo —
  # typically `{ "result" => { ... } }` on success. If Centrifugo rejects the
  # request with a top-level `error`, {Cent::ResponseError} is raised with
  # Centrifugo's numeric `code` and `message`. Transport-level problems
  # (network failure, timeout, non-2xx HTTP status, unparseable body) raise
  # other {Cent::Error} subclasses.
  #
  # {#batch} and {#broadcast} are special: their responses contain an array
  # of independent sub-replies, each of which may carry its own `error`
  # field. Those sub-reply errors are NOT raised — callers inspect them
  # manually. See {#batch} for details.
  #
  # @example Basic usage
  #   client = Cent::Client.new(api_key: 'secret')
  #   client.publish(channel: 'chat', data: { text: 'hi' })
  #   # => {"result" => {}}
  #
  # @example Custom Faraday configuration
  #   Cent::Client.new(api_key: 'k', endpoint: 'https://c.example.com/api') do |conn|
  #     conn.options.open_timeout = 3
  #     conn.options.timeout      = 7
  #     conn.adapter :typhoeus
  #   end
  class Client
    DEFAULT_ENDPOINT = 'http://localhost:8000/api'
    DEFAULT_TIMEOUT  = 10

    attr_reader :connection

    # @param api_key  [String]  Centrifugo HTTP API key (sent as `X-API-Key`).
    # @param endpoint [String]  Centrifugo HTTP API base URL.
    # @param timeout  [Numeric] Request timeout in seconds.
    # @yield [Faraday::Connection] optional block to further configure the connection.
    def initialize(api_key:, endpoint: DEFAULT_ENDPOINT, timeout: DEFAULT_TIMEOUT, &block)
      headers = {
        'Content-Type' => 'application/json',
        'X-API-Key' => api_key
      }

      base = endpoint.end_with?('/') ? endpoint : "#{endpoint}/"

      @connection = Faraday.new(base, headers: headers) do |conn|
        conn.options.timeout      = timeout
        conn.options.open_timeout = timeout
        conn.request :json
        conn.response :json
        conn.response :raise_error
        block&.call(conn)
      end
    end

    # Publish data into a channel.
    # @see https://centrifugal.dev/docs/server/server_api#publish
    def publish(channel:, data:, skip_history: nil, tags: nil, b64data: nil,
                idempotency_key: nil, delta: nil, version: nil, version_epoch: nil)
      send_command('publish', {
                     'channel' => channel,
                     'data' => data,
                     'skip_history' => skip_history,
                     'tags' => tags,
                     'b64data' => b64data,
                     'idempotency_key' => idempotency_key,
                     'delta' => delta,
                     'version' => version,
                     'version_epoch' => version_epoch
                   })
    end

    # Publish the same data into many channels.
    # @see https://centrifugal.dev/docs/server/server_api#broadcast
    def broadcast(channels:, data:, skip_history: nil, tags: nil, b64data: nil,
                  idempotency_key: nil, delta: nil, version: nil, version_epoch: nil)
      send_command('broadcast', {
                     'channels' => channels,
                     'data' => data,
                     'skip_history' => skip_history,
                     'tags' => tags,
                     'b64data' => b64data,
                     'idempotency_key' => idempotency_key,
                     'delta' => delta,
                     'version' => version,
                     'version_epoch' => version_epoch
                   })
    end

    # Subscribe a user's active session to a channel (server-side subscription).
    # @see https://centrifugal.dev/docs/server/server_api#subscribe
    def subscribe(user:, channel:, info: nil, b64info: nil, client: nil, session: nil,
                  data: nil, b64data: nil, recover_since: nil, override: nil)
      send_command('subscribe', {
                     'user' => user,
                     'channel' => channel,
                     'info' => info,
                     'b64info' => b64info,
                     'client' => client,
                     'session' => session,
                     'data' => data,
                     'b64data' => b64data,
                     'recover_since' => recover_since,
                     'override' => override
                   })
    end

    # Unsubscribe a user from a channel.
    # @see https://centrifugal.dev/docs/server/server_api#unsubscribe
    def unsubscribe(user:, channel:, client: nil, session: nil)
      send_command('unsubscribe', {
                     'user' => user,
                     'channel' => channel,
                     'client' => client,
                     'session' => session
                   })
    end

    # Disconnect a user by ID.
    # @see https://centrifugal.dev/docs/server/server_api#disconnect
    def disconnect(user:, client: nil, session: nil, whitelist: nil, disconnect: nil)
      send_command('disconnect', {
                     'user' => user,
                     'client' => client,
                     'session' => session,
                     'whitelist' => whitelist,
                     'disconnect' => disconnect
                   })
    end

    # Refresh a user connection (for unidirectional transports).
    # @see https://centrifugal.dev/docs/server/server_api#refresh
    def refresh(user:, client: nil, session: nil, expired: nil, expire_at: nil)
      send_command('refresh', {
                     'user' => user,
                     'client' => client,
                     'session' => session,
                     'expired' => expired,
                     'expire_at' => expire_at
                   })
    end

    # Get channel presence (all currently subscribed clients).
    # @see https://centrifugal.dev/docs/server/server_api#presence
    def presence(channel:)
      send_command('presence', { 'channel' => channel })
    end

    # Get short presence stats for a channel.
    # @see https://centrifugal.dev/docs/server/server_api#presence_stats
    def presence_stats(channel:)
      send_command('presence_stats', { 'channel' => channel })
    end

    # Get channel history (recent publications).
    # @see https://centrifugal.dev/docs/server/server_api#history
    def history(channel:, limit: nil, since: nil, reverse: nil)
      send_command('history', {
                     'channel' => channel,
                     'limit' => limit,
                     'since' => since,
                     'reverse' => reverse
                   })
    end

    # Remove all publications from a channel's history.
    # @see https://centrifugal.dev/docs/server/server_api#history_remove
    def history_remove(channel:)
      send_command('history_remove', { 'channel' => channel })
    end

    # List active channels (channels with at least one subscriber).
    # @see https://centrifugal.dev/docs/server/server_api#channels
    def channels(pattern: nil)
      send_command('channels', { 'pattern' => pattern })
    end

    # Get information about running Centrifugo nodes.
    # @see https://centrifugal.dev/docs/server/server_api#info
    def info
      send_command('info', {})
    end

    # Send many commands in a single request.
    #
    # The response is shaped `{ "replies" => [<reply>, ...] }` — note there
    # is no top-level `result` wrapper, unlike every other method. Each reply
    # in the array corresponds to one command (in the order they were sent
    # when `parallel` is not set) and has the shape `{ "<method>" => <result> }`
    # on success or `{ "error" => { "code" => ..., "message" => ... } }` on a
    # per-command failure.
    #
    # These per-command errors are **not** raised as {Cent::ResponseError} —
    # that would make partial-failure responses impossible to inspect. The
    # caller is expected to walk `response["replies"]` and check each entry.
    # If Centrifugo rejects the batch request as a whole (e.g. malformed
    # top-level body), the top-level `error` field is present and
    # {Cent::ResponseError} is raised normally.
    #
    # @example
    #   response = client.batch(commands: [
    #     { 'publish' => { 'channel' => 'a', 'data' => {} } },
    #     { 'publish' => { 'channel' => 'unknown:b', 'data' => {} } }
    #   ])
    #   response['replies'].each do |reply|
    #     if reply['error']
    #       warn "command failed: #{reply['error']['code']} #{reply['error']['message']}"
    #     end
    #   end
    #
    # @param commands [Array<Hash>] Each element is a command object of the
    #   form `{ "publish" => { ... } }`, `{ "broadcast" => { ... } }`, etc.
    # @param parallel [Boolean, nil] When true, Centrifugo processes commands
    #   in parallel (lower latency, order not guaranteed).
    # @see https://centrifugal.dev/docs/server/server_api#batch
    def batch(commands:, parallel: nil)
      send_command('batch', {
                     'commands' => commands,
                     'parallel' => parallel
                   })
    end

    private

    def send_command(method, params)
      body = connection.post(method, params.compact).body
      check_response_error!(body)
      body
    rescue Faraday::TimeoutError => e
      raise Cent::TimeoutError, e.message
    rescue Faraday::ConnectionFailed => e
      raise Cent::NetworkError, e.message
    rescue Faraday::UnauthorizedError => e
      raise Cent::UnauthorizedError.new(status: 401, message: e.message)
    rescue Faraday::ClientError, Faraday::ServerError => e
      status = e.response_status || e.response&.dig(:status)
      raise Cent::TransportError.new(status: status, message: e.message)
    rescue Faraday::ParsingError => e
      raise Cent::DecodeError, e.message
    end

    # Top-level `error` means Centrifugo rejected the whole request. Batch
    # and broadcast sub-reply errors live inside arrays and are NOT raised —
    # callers inspect them manually (see #batch docs).
    def check_response_error!(body)
      return unless body.is_a?(Hash) && body['error'].is_a?(Hash)

      raise Cent::ResponseError.new(
        code: body['error']['code'],
        message: body['error']['message']
      )
    end
  end
end
