# frozen_string_literal: true

module Cent
  # The outcome of a broadcast in one channel.
  #
  # @!attribute [r] channel
  #   @return [String] the channel, as the request named it
  # @!attribute [r] result
  #   @return [PublishResult, nil] the publication's position in the channel's
  #     history, when it succeeded
  # @!attribute [r] error
  #   @return [Error, nil] nil when the publication succeeded; the channel's
  #     ApiError, or the error of the whole broadcast when it failed as a whole
  # @!attribute [r] attempts
  #   @return [Integer] how many times the channel was sent: more than 1 when
  #     broadcast_with_retry retried it
  class ChannelResult < Data.define(:channel, :result, :error, :attempts)
    include Message

    def initialize(channel:, result: nil, error: nil, attempts: 0) = super
  end

  # The outcome of a broadcast: one entry per channel, in the order the request
  # listed them.
  #
  # @!attribute [r] channels
  #   @return [Array<ChannelResult>]
  # @!attribute [r] idempotency_key
  #   @return [String] the key the broadcast was sent with: the request's, or the
  #     one broadcast_with_retry made when the request had none. A later retry
  #     with it does not publish again into the channels which got the
  #     publication.
  # @!attribute [r] attempts
  #   @return [Integer] how many times the broadcast was tried: 1 from broadcast,
  #     up to max_attempts from broadcast_with_retry, 0 when it was refused
  #     before sending
  # @!attribute [r] replied
  #   @return [Boolean] true when Centrifugo carried the broadcast out and
  #     replied for every channel, the failed ones included; false when it
  #     failed as a whole
  class BroadcastResult < Data.define(:channels, :idempotency_key, :attempts, :replied)
    include Message

    def initialize(channels: [], idempotency_key: "", attempts: 0, replied: false) = super

    # The channels which did not get the publication, with their errors, in the
    # order of the request.
    #
    # @return [Array<ChannelResult>]
    def failed = channels.select(&:error)

    # @return [Boolean] alias of replied
    def replied? = replied

    # @api private
    def self.failed_as_whole(channels, err, attempts = 0)
      new(channels: channels.map { ChannelResult.new(channel: it, error: err, attempts:) }, attempts:)
    end

    # The result of a broadcast Centrifugo replied to. The reply holds one
    # response per channel, in the request's order.
    #
    # @api private
    def self.from_wire(v, channels, key)
      d = Wire.obj(v, "broadcast result")
      responses = d["responses"] || []
      raise DecodeError, "broadcast result.responses: expected an array" unless responses.is_a?(Array)
      if responses.size != channels.size
        raise DecodeError, "broadcast: got #{responses.size} replies for #{channels.size} channels"
      end

      results = responses.each_with_index.map do |item, i|
        where = "broadcast result.responses[#{i}]"
        r = Wire.obj(item, where)
        if r["error"].nil?
          ChannelResult.new(channel: channels[i], result: PublishResult.from_wire(r["result"] || {}, "#{where}.result"),
                            attempts: 1)
        else
          ChannelResult.new(channel: channels[i], error: Reply.api_error(r["error"], "#{where}.error"), attempts: 1)
        end
      end
      new(channels: results, idempotency_key: key, attempts: 1, replied: true)
    end

    # The result, or BroadcastFailedChannelsError carrying it when any channel
    # failed.
    #
    # @api private
    def check!
      f = failed
      raise BroadcastFailedChannelsError.new(f, channels.size, self) unless f.empty?

      self
    end
  end

  # A failed attempt of broadcast_with_retry, given to its block.
  #
  # @!attribute [r] attempt
  #   @return [Integer] the attempt which failed, from 1
  # @!attribute [r] error
  #   @return [Error] its error: BroadcastFailedChannelsError when Centrifugo
  #     replied and some channels failed, otherwise the error of the request as a
  #     whole
  # @!attribute [r] retry
  #   @return [Array<ChannelResult>] the channels the next attempt sends, with
  #     the errors this attempt failed them with. A broadcast to many channels
  #     which all failed lists every one: log a count or a few.
  # @!attribute [r] result
  #   @return [BroadcastResult] every channel's outcome so far, as the call
  #     would return it if it stopped now
  # @!attribute [r] idempotency_key
  #   @return [String] the key every attempt is sent with
  class BroadcastAttempt < Data.define(:attempt, :error, :retry, :result, :idempotency_key)
    include Message
  end
end
