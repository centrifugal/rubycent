# frozen_string_literal: true

require "openssl"

module Cent
  # Tokens: connection and subscription tokens for client SDKs, the JSON Web
  # Key Set Centrifugo verifies them with, and Centrifugo PRO's server API
  # tokens. See https://centrifugal.dev/docs/server/authentication.
  #
  #   key = Cent::Token::Key.hmac(ENV.fetch("CENTRIFUGO_TOKEN_SECRET"))   # client.token.hmac_secret_key
  #   Cent::Token.connection(key, user: "42", expires_at: Time.now + 15 * 60)
  #
  # Every expiry is chosen explicitly: a Time, or +:never+.
  module Token
    EC_ALGS = {
      "prime256v1" => ["ES256", "P-256", 32, "SHA256"],
      "secp384r1" => ["ES384", "P-384", 48, "SHA384"],
      "secp521r1" => ["ES512", "P-521", 66, "SHA512"]
    }.freeze
    private_constant :EC_ALGS

    # The error of a token or key which cannot be made: the message says why.
    class Error < Cent::Error; end

    # A key signing tokens, matching the one Centrifugo verifies with. Make one
    # with {.hmac}, {.rsa}, {.ecdsa}, {.ed25519} or {.from_pem}.
    class Key
      # @return [String] the JWS algorithm: HS256, RS256, ES256, ES384, ES512 or
      #   EdDSA
      attr_reader :alg
      # @return [String, nil] the key ID written as the tokens' "kid", if set
      attr_reader :kid

      # @api private
      attr_reader :jwk

      # @api private
      def initialize(alg, jwk, kid = nil, &sign)
        @alg = alg
        @jwk = jwk
        @kid = kid
        @sign = sign
        freeze
      end

      # The key, with +kid+ as the "kid" of the tokens it signs: the ID of its
      # public key in the JWKS Centrifugo verifies with. Never give the ID of a
      # key to another: Centrifugo caches keys by ID, and would refuse the other
      # key's tokens until its cache expires.
      #
      # @param kid [String]
      # @return [Key]
      def with_key_id(kid)
        raise Error, "a key ID must be a non-empty String" unless kid.is_a?(String) && !kid.empty?

        Key.new(@alg, @jwk, kid, &@sign)
      end

      # @api private
      def sign(data) = @sign.call(data)

      # @return [String] the algorithm and key ID, never the key
      def inspect = "#<Cent::Token::Key #{alg}#{" kid=#{kid.inspect}" if kid}>"

      # A key signing with HS256 and +secret+: Centrifugo's
      # client.token.hmac_secret_key.
      #
      # @param secret [String]
      # @return [Key]
      def self.hmac(secret)
        raise Error, "the HMAC secret must be a non-empty String" unless secret.is_a?(String) && !secret.empty?

        s = secret.b.freeze
        new("HS256", nil) { OpenSSL::HMAC.digest("SHA256", s, it) }
      end

      # A key signing with RS256, whose public key is Centrifugo's
      # client.token.rsa_public_key.
      #
      # @param pkey [OpenSSL::PKey::RSA] a private key
      # @return [Key]
      def self.rsa(pkey)
        unless pkey.is_a?(OpenSSL::PKey::RSA) && pkey.private?
          raise Error,
                "Key.rsa takes an OpenSSL::PKey::RSA private key"
        end

        jwk = { "kty" => "RSA", "n" => Token.b64(pkey.n.to_s(2)), "e" => Token.b64(pkey.e.to_s(2)) }
        new("RS256", jwk) { pkey.sign("SHA256", it) }
      end

      # A key signing with ES256, ES384 or ES512 - for a P-256, P-384 or P-521
      # key - whose public key is Centrifugo's client.token.ecdsa_public_key.
      #
      # @param pkey [OpenSSL::PKey::EC] a private key
      # @return [Key]
      def self.ecdsa(pkey)
        unless pkey.is_a?(OpenSSL::PKey::EC) && pkey.private?
          raise Error,
                "Key.ecdsa takes an OpenSSL::PKey::EC private key"
        end

        curve = pkey.group.curve_name
        alg, crv, size, digest = EC_ALGS[curve]
        raise Error, "ECDSA curve #{curve}: want P-256, P-384 or P-521" unless alg

        point = pkey.public_key.to_bn(:uncompressed).to_s(2)
        jwk = { "kty" => "EC", "crv" => crv, "x" => Token.b64(point[1, size]), "y" => Token.b64(point[1 + size, size]) }
        new(alg, jwk) do |data|
          # JWS wants r and s as fixed-size big-endian halves, not DER.
          r, s = OpenSSL::ASN1.decode(pkey.sign(digest, data)).value.map { it.value.to_s(2).rjust(size, "\0") }
          r + s
        end
      end

      # A key signing with EdDSA, whose public key is Centrifugo's
      # client.token.ed25519_public_key (Centrifugo v6.10.2+), or is published
      # in its JWKS with {Token.jwks}.
      #
      # @param pkey [OpenSSL::PKey::PKey] an Ed25519 private key
      # @return [Key]
      def self.ed25519(pkey)
        unless pkey.is_a?(OpenSSL::PKey::PKey) && pkey.oid == "ED25519" && private?(pkey)
          raise Error, "Key.ed25519 takes an Ed25519 private key: OpenSSL::PKey.generate_key(\"ED25519\"), say"
        end

        jwk = { "kty" => "OKP", "crv" => "Ed25519", "x" => Token.b64(pkey.raw_public_key) }
        new("EdDSA", jwk) { pkey.sign(nil, it) }
      end

      # The key of a PEM-encoded private key - RSA, ECDSA or Ed25519 - as
      # {.rsa}, {.ecdsa} or {.ed25519} make it.
      #
      # @param pem [String]
      # @param password [String, nil]
      # @return [Key]
      def self.from_pem(pem, password = nil)
        pkey = OpenSSL::PKey.read(pem, password)
        case pkey
        when OpenSSL::PKey::RSA then rsa(pkey)
        when OpenSSL::PKey::EC then ecdsa(pkey)
        else
          raise Error, "unsupported private key type #{pkey.oid}" unless pkey.oid == "ED25519"

          ed25519(pkey)
        end
      rescue OpenSSL::PKey::PKeyError => e
        raise Error, "not a PEM private key: #{e.message}"
      end

      def self.private?(pkey)
        pkey.raw_private_key
        true
      rescue OpenSSL::PKey::PKeyError
        false
      end
      private_class_method :private?
    end

    # The options of a server-side subscription in a connection token's +subs+.
    #
    # @!attribute [r] info
    #   @return [Object] channel-specific information about the connection
    # @!attribute [r] b64info
    #   @return [String, nil] binary info in base64, instead of info
    # @!attribute [r] data
    #   @return [Object] sent to the client with the subscription
    # @!attribute [r] b64data
    #   @return [String, nil] binary data in base64, instead of data
    # @!attribute [r] override
    #   @return [SubscribeOptionOverride, Hash, nil] channel options of the
    #     namespace overridden for this subscription
    # @!attribute [r] server_tags_filter
    #   @return [FilterNode, Hash, nil] only publications whose tags match it
    #     are delivered. Centrifugo PRO only.
    class SubscribeOptions < Data.define(:info, :b64info, :data, :b64data, :override, :server_tags_filter)
      def initialize(info: nil, b64info: nil, data: nil, b64data: nil, override: nil, server_tags_filter: nil) = super

      # @api private
      def to_wire(where = "")
        w = {}
        Wire.put(w, "info", info, where, :json)
        Wire.put(w, "b64info", b64info, where, :str)
        Wire.put(w, "data", data, where, :json)
        Wire.put(w, "b64data", b64data, where, :str)
        Wire.put(w, "override", override, where, SubscribeOptionOverride)
        Wire.put(w, "server_tags_filter", server_tags_filter, where, FilterNode)
        w
      end
    end

    # Operations granted in channels: a connection may do an operation in a
    # channel when any of its capabilities allows the operation and matches the
    # channel. Centrifugo PRO only.
    #
    # @!attribute [r] channels
    #   @return [Array<String>] the channels, or channel patterns, it applies to
    # @!attribute [r] allow
    #   @return [Array<String>] the operations: "sub" (subscribe), "pub"
    #     (publish), "hst" (history), "prs" (presence)
    # @!attribute [r] match
    #   @return [String, nil] how channels are matched: nil for exact names,
    #     "wildcard" or "regex"
    class ChannelsCapability < Data.define(:channels, :allow, :match)
      def initialize(channels: [], allow: [], match: nil) = super

      # @api private
      def to_wire(where = "")
        w = {}
        Wire.put(w, "channels", channels, where, :str, :list)
        Wire.put(w, "allow", allow, where, :str, :list)
        Wire.put(w, "match", match, where, :str)
        w
      end
    end

    module_function

    # A connection token, signed with +key+. See
    # https://centrifugal.dev/docs/server/authentication.
    #
    # @param key [Key]
    # @param expires_at [Time, :never] until when the token is accepted: the
    #   "exp" claim. +:never+ for a token accepted forever - and forever once
    #   leaked, for a trusted service's own connection, say. The connection
    #   expires then too, unless connection_expires_at says otherwise:
    #   Centrifugo asks the client for a new token, and closes the connection
    #   without one.
    # @param user [String] the ID of the connection's user: the "sub" claim.
    #   Empty for an anonymous connection.
    # @param connection_expires_at [Time, :never, nil] when set, when the
    #   connection expires instead of at expires_at: the "expire_at" claim.
    #   +:never+ makes the connection never expire - Centrifugo never asks for a
    #   new token - while expires_at still bounds when the token is accepted, on
    #   reconnects too. Most applications leave it unset.
    # @param issued_at [Time, nil] the "iat" claim; nil for now
    # @param id [String, nil] the "jti" claim, for Centrifugo PRO's token
    #   revocation
    # @param audience [String, nil] the "aud" claim: client.token.audience
    # @param issuer [String, nil] the "iss" claim: client.token.issuer
    # @param info [Object] information about the connection: in presence, join
    #   and leave events, and the client's publications
    # @param b64info [String, nil] binary info in base64, instead of info
    # @param channels [Array<String>] server-side channels to subscribe the
    #   connection to
    # @param subs [Hash{String => SubscribeOptions, Hash}] server-side channels
    #   to subscribe the connection to, each with its options. Set channels or
    #   subs, not both: Centrifugo ignores channels when subs is set.
    # @param meta [Object] custom data attached to the connection. Not visible
    #   to other clients - Centrifugo never sends it - but the token carries it,
    #   visible to the user owning the token: put nothing in it that user must
    #   not see.
    # @param caps [Array<ChannelsCapability, Hash>] capabilities granting the
    #   connection operations in channels. Centrifugo PRO only.
    # @param labels [Hash{String => String}] the connection's client labels:
    #   for metrics, targeted server API calls and CEL expressions. Centrifugo
    #   PRO only.
    # @return [String]
    # @raise [Error, InvalidRequestError]
    def connection(key, expires_at:, user: "", connection_expires_at: nil, issued_at: nil, id: nil, audience: nil,
                   issuer: nil, info: nil, b64info: nil, channels: [], subs: {}, meta: nil, caps: [], labels: {})
      exp = expiry(expires_at, "expires_at")
      unless channels.nil? || channels.empty? || subs.nil? || subs.empty?
        raise Error, "set channels or subs, not both: Centrifugo ignores channels when subs is set"
      end

      w = registered(user, exp, issued_at, id, audience, issuer)
      at = session_expiry(connection_expires_at, "connection_expires_at")
      w["expire_at"] = at unless at.nil?
      claims(w) do
        Wire.put(w, "info", info, "", :json)
        Wire.put(w, "b64info", b64info, "", :str)
        Wire.put(w, "channels", channels, "", :str, :list)
        Wire.put(w, "subs", subs, "", SubscribeOptions, :map)
        Wire.put(w, "meta", meta, "", :json)
        Wire.put(w, "caps", caps, "", ChannelsCapability, :list)
        Wire.put(w, "labels", labels, "", :str, :map)
      end
      sign(key, w)
    end

    # A subscription token, signed with +key+. See
    # https://centrifugal.dev/docs/server/channel_token_auth.
    #
    # @param key [Key]
    # @param channel [String] the channel the token allows to subscribe to
    # @param expires_at [Time, :never] until when the token is accepted: the
    #   "exp" claim. The subscription expires then too, unless
    #   subscription_expires_at says otherwise.
    # @param user [String] the ID of the connection's user: the "sub" claim
    # @param subscription_expires_at [Time, :never, nil] when set, when the
    #   subscription expires instead of at expires_at: the "expire_at" claim.
    #   +:never+ makes it never expire, while expires_at still bounds when the
    #   token is accepted: with a short expires_at, a token which subscribes
    #   once.
    # @param issued_at [Time, nil] the "iat" claim; nil for now
    # @param id [String, nil] the "jti" claim, for Centrifugo PRO's token
    #   revocation
    # @param audience [String, nil] the "aud" claim
    # @param issuer [String, nil] the "iss" claim
    # @param info [Object] channel-specific information about the connection
    # @param b64info [String, nil] binary info in base64, instead of info
    # @param data [Object] sent to the client in the subscribe reply
    # @param b64data [String, nil] binary data in base64, instead of data
    # @param override [SubscribeOptionOverride, Hash, nil] channel options of
    #   the namespace overridden for this subscription
    # @param allow [Array<String>] capabilities in the channel besides
    #   subscribing: "pub", "hst", "prs". Centrifugo PRO only.
    # @param server_tags_filter [FilterNode, Hash, nil] only publications whose
    #   tags match it are delivered. Centrifugo PRO only.
    # @return [String]
    # @raise [Error, InvalidRequestError]
    def subscription(key, channel:, expires_at:, user: "", subscription_expires_at: nil, issued_at: nil, id: nil,
                     audience: nil, issuer: nil, info: nil, b64info: nil, data: nil, b64data: nil, override: nil,
                     allow: [], server_tags_filter: nil)
      raise Error, "a subscription token needs a channel" unless channel.is_a?(String) && !channel.empty?

      w = registered(user, expiry(expires_at, "expires_at"), issued_at, id, audience, issuer)
      w["channel"] = channel
      at = session_expiry(subscription_expires_at, "subscription_expires_at")
      w["expire_at"] = at unless at.nil?
      claims(w) do
        Wire.put(w, "info", info, "", :json)
        Wire.put(w, "b64info", b64info, "", :str)
        Wire.put(w, "data", data, "", :json)
        Wire.put(w, "b64data", b64data, "", :str)
        Wire.put(w, "override", override, "", SubscribeOptionOverride)
        Wire.put(w, "allow", allow, "", :str, :list)
        Wire.put(w, "server_tags_filter", server_tags_filter, "", FilterNode)
      end
      sign(key, w)
    end

    # A token for Centrifugo PRO's server API, signed with +key+ - an asymmetric
    # key with an ID, published by {jwks}: Centrifugo PRO finds it by the
    # "kid". See https://centrifugal.dev/docs/pro/server_api_enhancements.
    #
    # A token passing Centrifugo PRO's checks can call every API method, and it
    # checks only what it is configured to: the signature by any key of the
    # JWKS endpoint, and audience, issuer and scope only when http_api.jwks
    # sets them. So the token must carry a claim no other token carries - above
    # all the connection and subscription tokens users hold:
    #
    # - sign API tokens with keys of their own, published at their own JWKS
    #   endpoint - never the one of client.token.jwks_public_endpoint;
    # - set audience, scope or both, to values only API tokens carry, and
    #   configure http_api.jwks.audience and scope to require them. api refuses
    #   claims with neither.
    #
    # See {ApiTokens} for one to send with every call.
    #
    # @param key [Key]
    # @param expires_at [Time] when the token expires: best minutes ahead.
    #   Centrifugo PRO would accept a token without "exp" for as long as its key
    #   is published, so api never signs one.
    # @param audience [String, nil] the "aud" claim: http_api.jwks.audience
    # @param scope [Array<String>] the "scope" claim, its scopes joined by
    #   spaces: http_api.jwks.scope is one of them
    # @param issuer [String, nil] the "iss" claim: http_api.jwks.issuer
    # @param subject [String] the "sub" claim: who calls the API, for the
    #   application's own logs
    # @param issued_at [Time, nil] the "iat" claim; nil for now
    # @param id [String, nil] the "jti" claim
    # @return [String]
    # @raise [Error]
    def api(key, expires_at:, audience: nil, scope: [], issuer: nil, subject: "", issued_at: nil, id: nil)
      raise Error, "key must be a Cent::Token::Key" unless key.is_a?(Key)
      if key.jwk.nil?
        raise Error, "an API token needs an RSA, ECDSA or Ed25519 key: " \
                     "Centrifugo PRO verifies it with the public keys of its JWKS endpoint"
      end
      raise Error, "an API token needs a key ID, by which Centrifugo PRO finds the key: use with_key_id" unless key.kid
      if (audience.nil? || audience.empty?) && scope.empty?
        raise Error, "set audience or scope, required by http_api.jwks, " \
                     "so that client tokens signed with the same keys can't call the server API"
      end
      if expires_at.nil? || expires_at == :never
        raise Error, "set expires_at: Centrifugo PRO accepts an API token without one while its key is published"
      end

      scope.each do |s|
        raise Error, "a scope is empty or has a space" if !s.is_a?(String) || s.empty? || s.match?(/\s/)
      end
      w = registered(subject, unix(expires_at, "expires_at"), issued_at, id, audience, issuer)
      w["scope"] = scope.join(" ") unless scope.empty?
      sign(key, w)
    end

    # The public keys of +keys+ as a JSON Web Key Set, for Centrifugo's
    # client.token.jwks_public_endpoint, which verifies tokens by their "kid".
    # Each key needs an ID - see {Key#with_key_id} - unique in the set. HMAC
    # keys have no public key to publish, and are refused, as is a set without
    # keys. Serve it with {Endpoints::JWKS}.
    #
    # A set is how keys rotate without restarting Centrifugo: publish the new
    # key next to the old one; once every instance of the application
    # publishes it, sign with it - from a time set ahead, say; drop the old key
    # once the tokens it signed have expired. Never give a key ID to another
    # key: Centrifugo caches keys by ID.
    #
    # Publish the keys of client tokens and of Centrifugo PRO's server API
    # tokens at separate endpoints: a token signed with any key of a set passes
    # Centrifugo's signature check.
    #
    # @param keys [Array<Key>]
    # @return [String] the JSON
    # @raise [Error]
    def jwks(*keys)
      raise Error, "a JWKS without keys" if keys.empty?

      seen = {}
      out = keys.each_with_index.map do |k, i|
        raise Error, "JWKS key ##{i} is not a Cent::Token::Key" unless k.is_a?(Key)
        raise Error, "JWKS key ##{i} has no public key to publish: an HMAC key" if k.jwk.nil?
        raise Error, "JWKS key ##{i} has no key ID: set one with with_key_id" unless k.kid
        raise Error, "JWKS key ID #{k.kid.inspect} used twice" if seen[k.kid]

        seen[k.kid] = true
        { "kty" => k.jwk["kty"], "kid" => k.kid, "use" => "sig", "alg" => k.alg, **k.jwk.except("kty") }
      end
      JSON.generate({ "keys" => out })
    end

    # @api private
    def b64(bytes) = [bytes].pack("m0").tr("+/", "-_").delete("=")

    def unix(t, name)
      t = t.to_time if !t.is_a?(Time) && t.respond_to?(:to_time)
      raise Error, "#{name} must be a Time, not #{t.class}" unless t.is_a?(Time)

      t.to_i
    end

    # The "exp" claim of expires_at: nil to leave it out, for :never.
    def expiry(t, name)
      return nil if t == :never
      raise Error, "#{name} is required: a Time, or :never for a token accepted forever" if t.nil?

      unix(t, name)
    end

    # The "expire_at" claim: left out (nil), 0 for never, or a time.
    def session_expiry(t, name)
      return nil if t.nil?
      return 0 if t == :never

      unix(t, name)
    end

    # The RFC 7519 claims Centrifugo reads, in the order the spec's vectors
    # use: sub, exp, iat, jti, aud, iss.
    def registered(user, exp, issued_at, id, audience, issuer)
      raise Error, "user must be a String" unless user.is_a?(String)

      w = { "sub" => user }
      w["exp"] = exp unless exp.nil?
      w["iat"] = issued_at.nil? ? Time.now.to_i : unix(issued_at, "issued_at")
      w["jti"] = id unless id.nil? || id.empty?
      w["aud"] = audience unless audience.nil? || audience.empty?
      w["iss"] = issuer unless issuer.nil? || issuer.empty?
      w
    end

    def claims(_w)
      yield
    rescue InvalidRequestError => e
      raise InvalidRequestError, "token: #{e.message}"
    end

    def sign(key, claims)
      raise Error, "key must be a Cent::Token::Key" unless key.is_a?(Key)

      header = { "alg" => key.alg, "typ" => "JWT" }
      header["kid"] = key.kid if key.kid
      # A payload which is not JSON fails here, not in Centrifugo.
      signed = "#{b64(JSON.generate(header))}.#{b64(Client.encode(claims))}"
      "#{signed}.#{b64(key.sign(signed))}"
    end

    private_class_method :unix, :expiry, :session_expiry, :registered, :claims, :sign

    # Issues the tokens a Client sends to Centrifugo PRO: its {#token} is the
    # client's bearer_token_func. It signs a token with {Token.api} and reuses
    # it for half its lifetime, so a token sent has at least half of it left.
    # Safe for concurrent use.
    #
    #   tokens = Cent::Token::ApiTokens.new(key: api_key,   # its own key, not the client tokens'
    #                                       audience: "centrifugo-api", scope: ["centrifugo:api"])
    #   client = Cent::Client.new(api_endpoint: "https://centrifugo.example.com/api",
    #                             bearer_token_func: tokens.method(:token))
    #
    # +current_key+, when set, returns the key to sign each new token with
    # instead of +key+ - the key active now, when keys rotate. A key must be
    # published in the JWKS before it signs: Centrifugo PRO refuses a token
    # whose key it can't find. The tokens are issued when needed and expire
    # +ttl+ seconds later (300 by default).
    class ApiTokens
      # @param key [Key, nil]
      # @param current_key [#call, nil]
      # @param ttl [Numeric] seconds
      # @param claims the claims of {Token.api} but expires_at and issued_at
      # @raise [Error]
      def initialize(key: nil, current_key: nil, ttl: 300, **claims)
        raise Error, "ApiTokens takes key or current_key, one of them" if key.nil? == current_key.nil?
        if claims.key?(:expires_at) || claims.key?(:issued_at)
          raise Error, "ApiTokens sets expires_at and issued_at itself: leave them unset, and set ttl"
        end
        raise Error, "ApiTokens ttl must be a positive number of seconds" unless ttl.is_a?(Numeric) && ttl.positive?

        unknown = claims.keys - %i[audience scope issuer subject id]
        raise Error, "ApiTokens: unknown claim #{unknown.first}" unless unknown.empty?

        @key = key
        @current_key = current_key
        @ttl = ttl.to_f
        @claims = claims
        @lock = Mutex.new
        @token = nil
        @refresh_at = 0.0
      end

      # A token valid for at least half of ttl, signing a new one when the
      # previous one has less left.
      #
      # @return [String]
      def token
        @lock.synchronize do
          now = Time.now.to_f
          return @token if @token && now < @refresh_at

          key = @current_key ? @current_key.call : @key
          @token = Token.api(key, **@claims, issued_at: Time.at(now.floor), expires_at: Time.at(now + @ttl))
          @refresh_at = now + (@ttl / 2)
          @token
        end
      end
    end
  end
end
