# frozen_string_literal: true

require "openssl"

module Cent
  # Signatures for shared poll subscriptions. See
  # https://centrifugal.dev/docs/server/shared_poll. Shared poll subscriptions
  # are experimental in Centrifugo, and this module follows their changes.
  module SharedPoll
    module_function

    # The signature authorizing +user+ to track +keys+ in +channel+ until
    # +expires_at+, as Centrifugo verifies it: "iat:exp:hmac", iat now and exp
    # expires_at in Unix seconds - 0 when expires_at is nil, for a signature
    # which does not expire. +secret+ is Centrifugo's
    # shared_poll.hmac_secret_key; +user+ is the ID of the connection's user,
    # empty for an anonymous one.
    #
    # The signature covers exactly +keys+, in their order: a client tracking
    # other keys, or the same in another order, is refused.
    #
    #   Cent::SharedPoll.sign(secret, user: "42", channel: "poll:prices", keys: ["AAPL"], expires_at: Time.now + 3600)
    #
    # @param secret [String]
    # @param user [String]
    # @param channel [String]
    # @param keys [Array<String>]
    # @param expires_at [Time, nil]
    # @return [String]
    def sign(secret, user:, channel:, keys:, expires_at: nil)
      sign_at(Time.now, secret, user:, channel:, keys:, expires_at:)
    end

    # sign, at the time +now+: for the spec's test vectors.
    def sign_at(now, secret, user:, channel:, keys:, expires_at: nil)
      raise Error, "shared poll: the secret must be a non-empty String" unless secret.is_a?(String) && !secret.empty?

      iat = now.to_i.to_s
      exp = expires_at.nil? ? "0" : expires_at.to_i.to_s
      keys_hash = OpenSSL::Digest::SHA256.hexdigest(keys.join("\0"))
      # NUL-separated, so that a colon in a user or channel cannot move between
      # fields: ("alice", "news:tech") and ("alice:news", "tech") sign
      # differently.
      msg = [iat, exp, user, channel, keys_hash].join("\0")
      "#{iat}:#{exp}:#{OpenSSL::HMAC.hexdigest("SHA256", secret, msg)}"
    end

    private_class_method :sign_at
  end
end
