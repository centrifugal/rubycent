# frozen_string_literal: true

require 'jwt'
require 'cent/error'

module Cent
  # Cent::Notary
  #
  # Issues JWT tokens for Centrifugo client connections and channel subscriptions.
  # Supports HMAC, RSA and ECDSA families of algorithms (HS256/384/512,
  # RS256/384/512, ES256/384/512).
  #
  # @see https://centrifugal.dev/docs/server/authentication
  # @see https://centrifugal.dev/docs/server/channel_token_auth
  class Notary
    # @param secret    [String, OpenSSL::PKey::RSA, OpenSSL::PKey::EC] Secret key
    #   for the chosen algorithm. For HMAC pass the raw secret as a String. For
    #   RSA/ECDSA pass a PEM-loaded {OpenSSL::PKey::RSA} / {OpenSSL::PKey::EC}.
    # @param algorithm [String] JWT algorithm, defaults to `HS256`.
    def initialize(secret:, algorithm: 'HS256')
      raise Error, 'Secret can not be nil' if secret.nil?

      @secret    = secret
      @algorithm = algorithm
    end

    # Issue a connection JWT used by clients when establishing a real-time
    # connection to Centrifugo.
    #
    # @param sub       [String] Standard JWT claim with the application user ID.
    #   Use an empty string for anonymous connections.
    # @param exp       [Integer] UNIX timestamp (seconds) when the token expires.
    # @param iat       [Integer] UNIX timestamp (seconds) when the token was issued.
    # @param jti       [String]  Unique token identifier.
    # @param aud       [String]  Token audience (matches `client.token.audience`).
    # @param iss       [String]  Token issuer  (matches `client.token.issuer`).
    # @param info      [Hash]    Arbitrary public info attached to the connection.
    # @param b64info   [String]  Base64-encoded `info` (for binary payloads).
    # @param channels  [Array<String>] Server-side subscription channel list.
    # @param subs      [Hash]    Server-side subscriptions with per-channel options.
    # @param meta      [Hash]    Server-only metadata attached to the connection.
    # @param expire_at [Integer] Override connection expiration timestamp.
    #
    # @return [String] Encoded JWT.
    def issue_connection_token(sub:, exp: nil, iat: nil, jti: nil, aud: nil, iss: nil,
                               info: nil, b64info: nil, channels: nil, subs: nil,
                               meta: nil, expire_at: nil)
      payload = {
        'sub' => sub,
        'exp' => exp,
        'iat' => iat,
        'jti' => jti,
        'aud' => aud,
        'iss' => iss,
        'info' => info,
        'b64info' => b64info,
        'channels' => channels,
        'subs' => subs,
        'meta' => meta,
        'expire_at' => expire_at
      }.compact

      JWT.encode(payload, secret, algorithm)
    end

    # Issue a subscription JWT used by clients to authorize subscription to a
    # channel that requires token authorization.
    #
    # @param sub       [String]  Application user ID (same meaning as in connection token).
    # @param channel   [String]  Channel this subscription token is valid for.
    # @param exp       [Integer] UNIX timestamp (seconds) when the token expires.
    # @param iat       [Integer] UNIX timestamp (seconds) when the token was issued.
    # @param jti       [String]  Unique token identifier.
    # @param aud       [String]  Token audience.
    # @param iss       [String]  Token issuer.
    # @param info      [Hash]    Arbitrary channel info.
    # @param b64info   [String]  Base64-encoded `info`.
    # @param override  [Hash]    Per-subscription channel option overrides.
    # @param expire_at [Integer] Override subscription expiration timestamp.
    #
    # @return [String] Encoded JWT.
    def issue_channel_token(sub:, channel:, exp: nil, iat: nil, jti: nil, aud: nil, iss: nil,
                            info: nil, b64info: nil, override: nil, expire_at: nil)
      payload = {
        'sub' => sub,
        'channel' => channel,
        'exp' => exp,
        'iat' => iat,
        'jti' => jti,
        'aud' => aud,
        'iss' => iss,
        'info' => info,
        'b64info' => b64info,
        'override' => override,
        'expire_at' => expire_at
      }.compact

      JWT.encode(payload, secret, algorithm)
    end

    private

    attr_reader :secret, :algorithm
  end
end
