# frozen_string_literal: true

require 'jwt'

module Cent
  # Cent::Notary
  #
  #   Handle token generation
  #
  class Notary
    # @param secret [String]
    #
    # @example Construct new client instance
    #   notary = Cent::Notary.new(secret: 'secret')
    #
    # @note At moment the only supported JWT algorithm is HS256 - i.e. HMAC SHA-256.
    #   This can be extended later.
    def initialize(secret:)
      raise Error, 'Secret can not be nil' if secret.nil?

      @secret = secret
      @algorithm = 'HS256'
    end

    # Generate connection JWT for the given user
    #
    # @param sub [String]
    #   Standard JWT claim which must contain an ID of current application user.
    #
    # @option channel [String]
    #   Channel that client tries to subscribe to (string).
    #
    # @param exp [Integer]
    #   (default: nil) UNIX timestamp seconds when token will expire.
    #
    # @param info [Hash]
    #   (default: {}) This claim is optional - this is additional information about
    #   client connection that can be provided for Centrifugo.
    #
    # @example Get user JWT with expiration and extra info
    #   notary.issue_connection_token(sub: '1', exp: 3600, info: { 'role' => 'admin' })
    #     #=> "eyJhbGciOiJIUzI1NiJ9.eyJzdWIi..."
    #
    # @see (https://centrifugal.github.io/centrifugo/server/authentication/)
    #
    # @return [String]
    #
    def issue_connection_token(sub:, info: {}, exp: nil)
      payload = {
        'sub' => sub,
        'info' => info,
        'exp' => exp
      }.compact

      JWT.encode(payload, secret, algorithm)
    end

    # Generate JWT for private channels
    #
    # @param client [String]
    #   Client ID which wants to subscribe on channel
    #
    # @option channel [String]
    #   Channel that client tries to subscribe to (string).
    #
    # @param exp [Integer]
    #   (default: nil) UNIX timestamp seconds when token will expire.
    #
    # @param info [Hash]
    #   (default: {}) This claim is optional - this is additional information about
    #   client connection that can be provided for Centrifugo.
    #
    # @example Get private channel JWT with expiration and extra info
    #   notary.issue_channel_token(client: 'client', channel: 'channel', exp: 3600, info: { 'message' => 'wat' })
    #     #=> eyJhbGciOiJIUzI1NiJ9.eyJjbGllbnQiOiJjbG..."
    #
    # @see (https://centrifugal.github.io/centrifugo/server/private_channels/)
    #
    # @return [String]
    #
    def issue_channel_token(client:, channel:, info: {}, exp: nil)
      payload = {
        'client' => client,
        'channel' => channel,
        'info' => info,
        'exp' => exp
      }.compact

      JWT.encode(payload, secret, algorithm)
    end

    private

    attr_reader :secret, :algorithm
  end
end
