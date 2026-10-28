# frozen_string_literal: true

module Cent
  # The application side of Centrifugo's HTTP proxy: the requests Centrifugo
  # sends to the backend when a client connects, subscribes, publishes or calls
  # an RPC, the results the backend answers with, and a handler for each proxy
  # type which decodes the request, calls a block and encodes its answer. Each
  # handler is a {Handler}: a Rack app, with a framework-free core.
  #
  #   connect = Cent::Proxy::ConnectHandler.new do |req, http|
  #     user = session_user(http.headers["cookie"])    # passed on with http_headers
  #     raise Cent::Proxy::Disconnect.new(4501, "unauthorized") unless user
  #
  #     Cent::Proxy::ConnectResult.new(user:)          # or a Hash: { user: }
  #   end
  #   mount connect, at: "/centrifugo/connect"       # config/routes.rb
  #
  # and in Centrifugo's configuration:
  #
  #   "client": {"proxy": {"connect": {"enabled": true,
  #     "endpoint": "http://backend:3000/centrifugo/connect", "http_headers": ["Cookie"]}}}
  #
  # See https://centrifugal.dev/docs/server/proxy.
  #
  # The block gets the decoded request and the {HTTPRequest}, and returns a
  # result - the result type, or a Hash of its fields - to accept the request,
  # or raises:
  #
  # - {ProxyError} rejects the request with that error, which the client
  #   receives: use codes in [400, 1999]. The connect, subscribe, publish, RPC,
  #   map publish and map remove proxies pass it to the client; the shared poll
  #   refresh and channel state proxies take it as a failure.
  # - {Disconnect} closes the client's connection with that code: use codes in
  #   [4000, 4999] - [4500, 4999] to tell the client not to reconnect. Only the
  #   proxies which pass a ProxyError to the client honour it.
  # - Any other error, or one a proxy cannot carry, fails the request with HTTP
  #   status 500, and is passed to +on_error+ for logging. Centrifugo then
  #   answers the client with its temporary internal error; for refresh and sub
  #   refresh it keeps the connection or subscription for another minute and
  #   asks again.
  #
  # A ProxyError or Disconnect which is the cause of another error counts too.
  # The refresh and sub refresh proxies end a connection or subscription
  # through their result's expired, not an error. A handler answers with
  # exactly one of result, error and disconnect: Centrifugo would take a
  # response with none as accepting the request as the client sent it.
  #
  # Payloads - data, info, meta - arrive as JSON.parse gives them, and a result
  # takes them back as they are, or as JSON::Fragment. A proxy with
  # binary_encoding enabled sends them base64-encoded in the b64 fields, with
  # encoding "binary"; a result may answer with either field.
  #
  # Security: Centrifugo trusts what a proxy endpoint answers, and the endpoint
  # trusts what Centrifugo sends - a SubscribeRequest's user is the user
  # Centrifugo authenticated. Anyone else able to reach the endpoint could claim
  # any user. Keep proxy endpoints reachable by Centrifugo only: on an internal
  # network, or behind a check of a secret Centrifugo sends as a static header.
  #
  # Centrifugo's GRPC proxy is not covered: generate GRPC code from proxy.proto
  # for it.
  module Proxy
    # The default bound of a request's body, 16 MiB: far above what
    # Centrifugo's own limits on client messages let through, it only stops a
    # request which is not Centrifugo's from taking the memory it likes.
    DEFAULT_MAX_BODY = 16 << 20

    # Raised by a proxy block to reject the client's request with this error:
    # code in [400, 1999], which Centrifugo leaves to applications. temporary
    # tells the client that retrying may succeed.
    class ProxyError < StandardError
      # @return [Integer]
      attr_reader :code
      # @return [String]
      attr_reader :reason

      # @param code [Integer]
      # @param reason [String] the error's message, sent to the client
      # @param temporary [Boolean]
      def initialize(code, reason = "", temporary: false)
        @code = code
        @reason = reason
        @temporary = temporary
        super("#{reason} (code #{code})")
      end

      # @return [Boolean]
      def temporary? = @temporary
    end

    # Raised by a proxy block to close the client's connection: code in [4000,
    # 4999] - [4000, 4499] tells the client to reconnect, [4500, 4999] not to.
    # reason is a short description, at most 32 bytes.
    class Disconnect < StandardError
      # @return [Integer]
      attr_reader :code
      # @return [String]
      attr_reader :reason

      # @param code [Integer]
      # @param reason [String]
      def initialize(code, reason = "")
        @code = code
        @reason = reason
        super("disconnect: #{reason} (code #{code})")
      end
    end

    # @api private
    class ProxyHandler < Handler
      # @param on_error [#call, nil] told of every 500 and 400, with the
      #   {HTTPRequest} and the error
      # @param max_body [Integer] the largest request body read, in bytes
      def initialize(on_error: nil, max_body: DEFAULT_MAX_BODY, &) = super(max_body, on_error, &)

      private

      def start(req, body)
        return HTTPResponse.allow("POST") unless req.method == "POST"

        name, request_class, = self.class::SPEC
        [request_class.from_wire(JSON.parse(body, allow_nan: false, max_nesting: false), "#{name} request")]
      rescue JSON::ParserError, EncodingError, DecodeError => e
        failure(req, 400, ArgumentError.new("proxy: malformed #{name} request: #{e.message}"))
      end

      def finish(req, _args, out, error)
        name, _, result_class, answers = self.class::SPEC
        if error.nil?
          begin
            wire = { "result" => Wire.message(result_class, out, "result").to_wire("result.") }
          rescue InvalidRequestError => e
            return failure(req, 500, TypeError.new("proxy: the #{name} block returned an invalid result: #{e.message}"))
          end
        else
          d = find(error, Disconnect)
          e = find(error, ProxyError)
          if d && answers == :disconnect
            wire = { "disconnect" => { "code" => d.code, "reason" => d.reason } }
          elsif e && answers != :result
            wire = { "error" => { "code" => e.code, "message" => e.reason } }
            wire["error"]["temporary"] = true if e.temporary?
          elsif d || e
            # Centrifugo would ignore it in this proxy's response.
            return failure(req, 500, ArgumentError.new("proxy: the #{name} proxy cannot answer with #{error.inspect}"))
          else
            return failure(req, 500, error)
          end
        end
        HTTPResponse.new(status: 200, headers: { "content-type" => "application/json" }, body: Client.encode(wire))
      rescue InvalidRequestError => e
        # A payload which is not JSON, say: Centrifugo could not use the
        # response.
        failure(req, 500, e)
      end
    end

    # The connect proxy: the block authenticates a connecting client and
    # returns its user and initial state. ProxyError rejects the connection;
    # Disconnect closes it with that code.
    class ConnectHandler < ProxyHandler
      # @api private
      SPEC = ["connect", ConnectRequest, ConnectResult, :disconnect].freeze
    end

    # The refresh proxy: the block decides whether a connection about to expire
    # lives on, and until when. To end it, return a result with expired set.
    # Any error fails the request, and Centrifugo keeps the connection for
    # another minute before asking again.
    class RefreshHandler < ProxyHandler
      # @api private
      SPEC = ["refresh", RefreshRequest, RefreshResult, :result].freeze
    end

    # The subscribe proxy: the block decides whether a client may subscribe to
    # a channel. ProxyError rejects the subscription; Disconnect closes the
    # connection.
    class SubscribeHandler < ProxyHandler
      # @api private
      SPEC = ["subscribe", SubscribeRequest, SubscribeResult, :disconnect].freeze
    end

    # The publish proxy: the block decides whether a client may publish into a
    # channel, and may change the publication. ProxyError rejects it;
    # Disconnect closes the connection.
    class PublishHandler < ProxyHandler
      # @api private
      SPEC = ["publish", PublishRequest, PublishResult, :disconnect].freeze
    end

    # The RPC proxy: the block answers a client's RPC call. ProxyError fails the
    # call; Disconnect closes the connection.
    class RPCHandler < ProxyHandler
      # @api private
      SPEC = ["rpc", RPCRequest, RPCResult, :disconnect].freeze
    end

    # The sub refresh proxy: the block decides whether a subscription about to
    # expire lives on, and until when. To end it, return a result with expired
    # set. Any error fails the request, and Centrifugo keeps the subscription
    # for another minute before asking again.
    class SubRefreshHandler < ProxyHandler
      # @api private
      SPEC = ["sub refresh", SubRefreshRequest, SubRefreshResult, :result].freeze
    end

    # The map publish proxy: the block decides whether a client may publish a
    # key into a map channel, and may change the publication.
    class MapPublishHandler < ProxyHandler
      # @api private
      SPEC = ["map publish", MapPublishRequest, MapPublishResult, :disconnect].freeze
    end

    # The map remove proxy: the block decides whether a client may remove a key
    # from a map channel.
    class MapRemoveHandler < ProxyHandler
      # @api private
      SPEC = ["map remove", MapRemoveRequest, MapRemoveResult, :disconnect].freeze
    end

    # The shared poll refresh proxy: the block returns the current data of the
    # items tracked in a shared poll channel. ProxyError, or any other error,
    # fails the refresh: Centrifugo tries again at the next interval.
    class SharedPollRefreshHandler < ProxyHandler
      # @api private
      SPEC = ["shared poll refresh", SharedPollRefreshRequest, SharedPollRefreshResult, :error].freeze
    end

    # The cache empty proxy of Centrifugo PRO: the block learns that a client
    # subscribed to a channel in cache recovery mode with nothing to recover,
    # and may publish the current state - then it returns a result with
    # populated set, for Centrifugo to recover once more. Any error fails the
    # request, and the client which subscribed is disconnected to reconnect.
    class NotifyCacheEmptyHandler < ProxyHandler
      # @api private
      SPEC = ["cache empty", NotifyCacheEmptyRequest, NotifyCacheEmptyResult, :result].freeze
    end

    # The channel state proxy of Centrifugo PRO, in preview: the block receives
    # channels becoming occupied or vacated. ProxyError, or any other error,
    # fails the request.
    class NotifyChannelStateHandler < ProxyHandler
      # @api private
      SPEC = ["channel state", NotifyChannelStateRequest, NotifyChannelStateResult, :error].freeze
    end
  end
end
