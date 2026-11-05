# frozen_string_literal: true

module Cent
  # The wait, in seconds, before retrying after a failed attempt, attempt 1
  # being the first failure: +base+ after it, twice as long after each next one,
  # up to +limit+. Each wait is a random time between half of it and all of it,
  # so that clients which failed together do not all retry at the same moment. A
  # negative base counts as zero, a limit below base as base, and an attempt
  # below 1 as 1.
  #
  # In a retry loop of your own - a publication retried with the same
  # idempotency_key:
  #
  #   backoff = Cent.exponential_backoff(0.1, 2.0)
  #   attempt = 0
  #   begin
  #     attempt += 1
  #     client.publish(channel: "orders:42", data:, idempotency_key: "order-42-paid")
  #   rescue Cent::Error => e
  #     raise unless Cent.retryable?(e) && attempt < 3
  #
  #     sleep(backoff.(attempt))
  #     retry
  #   end
  #
  # Retry a broadcast with broadcast_with_retry instead: repeating it resends to
  # the channels which already got it.
  #
  # @param base [Numeric] seconds
  # @param limit [Numeric] seconds
  # @return [Proc] taking the attempt, returning seconds
  def self.exponential_backoff(base, limit)
    base = [base.to_f, 0.0].max
    limit = [limit.to_f, base].max
    lambda do |attempt|
      d = base
      (1...[attempt, 1].max).each do
        # A zero base never grows: no need to count the attempts out.
        break if d >= limit || d.zero?

        d *= 2
      end
      d = [d, limit].min
      (d / 2) + (rand * (d / 2))
    end
  end

  DEFAULT_BACKOFF = exponential_backoff(0.1, 5.0)
  private_constant :DEFAULT_BACKOFF

  # @api private
  def self.default_delay(attempt) = DEFAULT_BACKOFF.call(attempt)
end
