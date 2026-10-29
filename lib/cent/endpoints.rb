# frozen_string_literal: true

module Cent
  # The HTTP endpoints client SDKs call: for connection and subscription tokens
  # - what their getToken callbacks fetch - and for shared poll signatures, plus
  # the JSON Web Key Set Centrifugo fetches. Each is a {Handler}: a Rack app,
  # with a framework-free core.
  #
  #   conn = Cent::Endpoints::ConnectionToken.new(on_error: ->(_http, err) { logger.error(err) }) do |req|
  #     user = session_user(req.raw)                     # the Rack env
  #     raise Cent::Endpoints::Unauthorized unless user
  #
  #     Cent::Token.connection(key, user:, expires_at: Time.now + 15 * 60)
  #   end
  #   mount conn, at: "/centrifugo/connection_token"   # config/routes.rb
  #
  # An endpoint answers a JSON object, never cached; Unauthorized - also as the
  # cause of another error - with 403, on which client SDKs stop asking, and
  # disconnect or unsubscribe; any other error with 500, which they retry. A
  # malformed request gets 400, a wrong method 405. +on_error+, when set, is
  # told of every 500 and 400, with the request and the error - without it, an
  # error in the block is logged nowhere.
  module Endpoints
    # Bodies are read up to 1 MiB.
    MAX_BODY = 1 << 20

    # Raised by the block of an endpoint when the user may not have a token or
    # signature: answered with 403, on which client SDKs stop asking. It is the
    # endpoints' own, named after client SDKs' UnauthorizedError - not the API
    # client's {Cent::UnauthorizedError}, which means Centrifugo refused the
    # SDK's credentials.
    class Unauthorized < StandardError
      def initialize(msg = "unauthorized") = super
    end

    # @api private
    class Endpoint < Handler
      # @param on_error [#call, nil] told of every 500 and 400, with the
      #   request and the error; it must not raise. Pass one: without it, an
      #   error in the block is answered with 500 and logged nowhere.
      def initialize(on_error: nil, &) = super(MAX_BODY, on_error, &)

      private

      def answer(req, body, error)
        if error
          return HTTPResponse.text(403, "Forbidden") if find(error, Unauthorized)

          return failure(req, 500, error)
        end
        HTTPResponse.json(JSON.generate(body))
      end

      def token(req, out, error)
        if error.nil? && !(out.is_a?(String) && !out.empty?)
          error = TypeError.new("the block returned #{out.class}, not a token")
        end
        answer(req, error ? nil : { "token" => out }, error)
      end
    end

    # The endpoint a client's getToken callback calls. Its block, given the
    # {HTTPRequest}, returns the connection token of the request's user - from
    # {Token.connection}, say - or raises Unauthorized. It takes GET and POST,
    # the body ignored.
    class ConnectionToken < Endpoint
      private

      def start(req, _body)
        return HTTPResponse.allow("GET, POST") unless %w[GET POST].include?(req.method)

        []
      end

      def finish(req, _args, out, error) = token(req, out, error)
    end

    # The endpoint a subscription's getToken callback calls. Its block, given
    # the channel and the {HTTPRequest}, returns the token of the request's
    # user for the channel - from {Token.subscription}, say - or raises
    # Unauthorized when the user may not subscribe. The channel comes from a
    # POST's JSON body, +{"channel": ...}+, or from a GET's channel query
    # parameter; it is required.
    #
    #   Cent::Endpoints::SubscriptionToken.new do |channel, req|
    #     user = session_user(req.raw)
    #     raise Cent::Endpoints::Unauthorized unless user && may_read?(user, channel)
    #
    #     Cent::Token.subscription(key, user:, channel:, expires_at: Time.now + 15 * 60)
    #   end
    class SubscriptionToken < Endpoint
      private

      def start(req, body)
        case req.method
        when "GET" then channel = req.query.fetch("channel", "")
        when "POST"
          d = parse_json(req, body)
          return d if d.is_a?(HTTPResponse)

          channel = d.fetch("channel", "")
          unless channel.is_a?(String)
            return failure(req, 400,
                           ArgumentError.new("malformed request: channel is not a string"))
          end
        else return HTTPResponse.allow("GET, POST")
        end
        return failure(req, 400, ArgumentError.new("subscription token request without a channel")) if channel.empty?

        [channel]
      end

      def finish(req, _args, out, error) = token(req, out, error)
    end

    # The endpoint a shared poll subscription's getSignature callback calls: a
    # POST of +{"channel": ..., "keys": [...]}+, answered +{"signature": ...,
    # "keys": [...]}+.
    #
    # Its block, given the channel, the keys and the {HTTPRequest}, decides
    # which of the keys the user may track in the channel, signs them - with
    # {SharedPoll.sign}, say - and returns them, in the order signed, with the
    # signature: +[allowed, signature]+. The keys it leaves out are revoked:
    # the client stops tracking them. To end the subscription instead, it
    # raises Unauthorized. It may return only keys it was asked for: a
    # signature covering another would be refused, and such a key fails the
    # request with 500.
    class SharedPollSignature < Endpoint
      private

      def start(req, body)
        return HTTPResponse.allow("POST") unless req.method == "POST"

        d = parse_json(req, body)
        return d if d.is_a?(HTTPResponse)

        channel = d.fetch("channel", "")
        keys = d["keys"] || []
        unless channel.is_a?(String) && keys.is_a?(Array) && keys.all?(String)
          return failure(req, 400, ArgumentError.new("malformed request: channel and keys must be strings"))
        end
        return failure(req, 400, ArgumentError.new("signature request without a channel")) if channel.empty?

        [channel, keys]
      end

      def finish(req, args, out, error)
        return answer(req, nil, error) if error

        allowed, signature = out if out.is_a?(Array) && out.size == 2
        unless signature.is_a?(String) && allowed.is_a?(Array) && allowed.all?(String)
          return answer(req, nil, TypeError.new("the block must return [keys, signature]"))
        end

        extra = allowed - args[1]
        unless extra.empty?
          return answer(req, nil,
                        ArgumentError.new("signed key #{extra.first.inspect} the client did not ask for"))
        end

        # The SDK reads the keys as an array, empty included.
        answer(req, { "signature" => signature, "keys" => allowed }, nil)
      end
    end

    # Serves the JSON Web Key Set of +keys+ - see {Token.jwks} - at the URL
    # configured as Centrifugo's client.token.jwks_public_endpoint, or PRO's
    # http_api.jwks.endpoint. It answers GET and HEAD, cacheable for five
    # minutes. A set Token.jwks refuses fails here, when the endpoint is built.
    class JWKS < Handler
      # @param keys [Array<Token::Key>]
      # @raise [Token::Error]
      def initialize(*keys)
        super(MAX_BODY, nil)
        @body = Token.jwks(*keys)
      end

      private

      def answers_itself? = true

      def start(req, _body)
        return HTTPResponse.allow("GET, HEAD") unless %w[GET HEAD].include?(req.method)

        HTTPResponse.json(req.method == "GET" ? @body : "", "public, max-age=300")
      end
    end
  end
end
