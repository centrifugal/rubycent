# frozen_string_literal: true

module Cent
  # How many failures an aggregate error names in its message; all of them stay
  # available in the error itself.
  MAX_ERROR_ITEMS = 3
  private_constant :MAX_ERROR_ITEMS

  # The base of every error cent raises.
  class Error < StandardError
    # @return [String, nil] set on the error broadcast_with_retry raises when no
    #   attempt got a reply - a timeout, say - to the key its attempts carried,
    #   made for the call when the request had none: Centrifugo may have
    #   published, and a retry with this key does not publish twice. Nil on
    #   other errors.
    attr_accessor :idempotency_key
  end

  # An error of Centrifugo itself: it understood the request and refused it, or
  # failed to carry it out.
  #
  # Centrifugo identifies an error by its {#code}; {#server_message} is for
  # people and may change. Errors with a known code are raised as the subclass
  # for it - +rescue Cent::UnknownChannelError+ - and any other code as ApiError
  # itself: Centrifugo adds codes from time to time, so rescue the ones you
  # handle and treat the rest by their class.
  class ApiError < Error
    # @return [Integer] the error code: stable, compare it
    attr_reader :code
    # @return [String] Centrifugo's message, for people: never compare it
    attr_reader :server_message

    # Whether Centrifugo marked the error temporary: the same request may
    # succeed if retried later - a broker being unavailable, a rate limit - not
    # because of the request. It does not mean nothing was done: a publication
    # may have happened, so retry it with the same idempotency_key. Centrifugo
    # versions before the field existed never set it; {Cent.retryable?} takes
    # that into account.
    #
    # @return [Boolean]
    def temporary? = @temporary

    # @param code [Integer]
    # @param server_message [String]
    # @param temporary [Boolean]
    def initialize(code, server_message = "", temporary: false)
      @code = code
      @server_message = server_message
      @temporary = temporary
      @pro_method = nil
      super(nil)
    end

    # @return [String]
    def to_s
      s = "#{server_message.empty? ? "server error" : server_message} (code #{code})"
      s += " (#{@pro_method} is a Centrifugo PRO method: is the server Centrifugo OSS?)" if @pro_method
      s
    end

    # The error for a code: the subclass of a known code, ApiError otherwise.
    #
    # @return [ApiError]
    def self.for_code(code, server_message = "", temporary: false)
      (BY_CODE[code] || ApiError).new(code, server_message, temporary:)
    end

    # @api private
    def pro_method!(method) = (@pro_method = method)
  end

  # Code 100: an internal error of Centrifugo, temporary.
  class InternalError < ApiError
    # The error code.
    CODE = 100
  end

  # Code 102: the channel is not in a namespace Centrifugo is configured with.
  class UnknownChannelError < ApiError
    # The error code.
    CODE = 102
  end

  # Code 104: what the request refers to was not found.
  #
  # A method only Centrifugo PRO has, sent in a batch to Centrifugo OSS, fails
  # with it too, instead of the 404 it gets when sent alone.
  class NotFoundError < ApiError
    # The error code.
    CODE = 104
  end

  # Code 107: Centrifugo refused the request as invalid.
  class BadRequestError < ApiError
    # The error code.
    CODE = 107
  end

  # Code 108: the feature is not available - history or presence off in the
  # channel's namespace, say.
  class NotAvailableError < ApiError
    # The error code.
    CODE = 108
  end

  # Code 111: a rate limit was reached, temporary.
  class TooManyRequestsError < ApiError
    # The error code.
    CODE = 111
  end

  # Code 112: the stream position asked for is not in the history any more.
  class UnrecoverablePositionError < ApiError
    # The error code.
    CODE = 112
  end

  # Code 113: the request conflicts with the current state - a map publish
  # whose version check failed, say.
  class ConflictError < ApiError
    # The error code.
    CODE = 113
  end

  class ApiError
    # @api private
    BY_CODE = [
      InternalError, UnknownChannelError, NotFoundError, BadRequestError,
      NotAvailableError, TooManyRequestsError, UnrecoverablePositionError, ConflictError
    ].to_h { [it::CODE, it] }.freeze
  end

  # A reply with an HTTP status other than 200: the request did not reach the
  # API method. A 401 is an {UnauthorizedError}.
  class HTTPError < Error
    # @return [Integer]
    attr_reader :status_code
    # @return [String] the start of the reply's body, for diagnostics
    attr_reader :body
    # @return [Hash{String => String}] the reply's headers, lowercase names: a
    #   request ID a proxy set, a +retry-after+
    attr_reader :headers

    # @param status_code [Integer]
    # @param body [String]
    # @param headers [Hash{String => String}]
    def initialize(status_code, body = "", headers = {})
      @status_code = status_code
      @body = body
      @headers = headers
      @pro_method = nil
      super(nil)
    end

    # @return [String]
    def to_s
      s = "unexpected HTTP status #{status_code}"
      if (300..399).cover?(status_code)
        # Centrifugo's API never redirects: something in front of it does,
        # which cent does not follow.
        s += " (a redirect, which cent does not follow: check api_endpoint, http or https say)"
      elsif status_code == 404 && @pro_method
        s += " (#{@pro_method} is a Centrifugo PRO method: if other methods work, the server is Centrifugo OSS)"
      elsif status_code == 404
        # The usual cause: api_endpoint lacks the API prefix.
        s += " (is api_endpoint the API base URL, such as http://localhost:8000/api?)"
      elsif status_code == 401
        s += " (check the credentials: api_key or bearer_token_func)"
      end
      s += ": #{body.dup.force_encoding(Encoding::UTF_8).scrub}" unless body.empty?
      s
    end

    # @api private
    def pro_method!(method) = (@pro_method = method)
  end

  # A 401: Centrifugo did not accept the credentials - the API key or the bearer
  # token.
  class UnauthorizedError < HTTPError; end

  # The reply is not a Centrifugo API reply. The usual cause is an api_endpoint
  # which does not point at Centrifugo's API, so that something else - a proxy,
  # a web page - answers instead.
  class DecodeError < Error; end

  # A request the client can tell is wrong without sending it: one which cannot
  # be encoded - a payload which is not JSON, in any request - or a publication
  # without a channel or data. It is never sent.
  #
  # Only rules which hold for every Centrifugo are checked; everything else
  # Centrifugo checks itself, and reports as a {BadRequestError}.
  class InvalidRequestError < Error; end

  # A client configuration with a mistake: the message names the option and the
  # fix.
  class InvalidConfigError < Error; end

  # A call made after the client was closed.
  class ClosedError < Error; end

  # The request failed on its way: a refused or reset connection, a failed TLS
  # handshake. The cause is the error of the network.
  class NetworkError < Error; end

  # The request timed out: its timeout, or request_timeout. A request which
  # timed out may still have been carried out.
  class TimeoutError < Error; end

  # A pending command's result read before its batch was sent.
  class BatchNotSentError < Error; end

  # A batch sent again: a batch is sent once.
  class BatchSentError < Error; end

  # A broadcast Centrifugo carried out which failed in one or more of its
  # channels, up to all of them. {#result} holds every channel's outcome.
  #
  # It is not an ApiError of its parts: +rescue Cent::UnknownChannelError+ does
  # not catch a broadcast in which one channel of many was unknown, nor one into
  # a single channel - the broadcast as a whole is not unknown. Look at each
  # channel's error in {#failed}.
  class BroadcastFailedChannelsError < Error
    # @return [Array<ChannelResult>] the channels which failed, with their
    #   errors, in the order of the request
    attr_reader :failed
    # @return [Integer] how many channels the broadcast had
    attr_reader :total
    # @return [BroadcastResult] every channel's outcome
    attr_reader :result

    # For test doubles, say:
    #
    #   raise Cent::BroadcastFailedChannelsError.new(result.failed, result.channels.size, result)
    #
    # @param failed [Array<ChannelResult>]
    # @param total [Integer]
    # @param result [BroadcastResult]
    def initialize(failed, total, result)
      @failed = failed
      @total = total
      @result = result
      super(nil)
    end

    # The channels whose failure is retryable, in the order of the request: the
    # channels a retry should go to, with the same idempotency_key. Channels
    # which failed for good, such as an unknown channel, are left out.
    #
    # @return [Array<String>]
    def retryable_channels = failed.filter_map { it.channel if Cent.retryable?(it.error) }

    # @return [String]
    def to_s
      items = failed.map { |ch| [ch.channel, ch.error] }
      msg = Cent.failures_message("broadcast", "channels", "got the publication", total, items)
      msg += " (retry only retryable_channels, with the same idempotency_key)" unless retryable_channels.empty?
      msg
    end
  end

  # The failure of one command of a batch.
  #
  # @!attribute [r] index
  #   @return [Integer] the command's position in the batch, from zero
  # @!attribute [r] method
  #   @return [String] its API method, such as "publish"
  # @!attribute [r] error
  #   @return [Error] the error its pending raises: an ApiError, or a
  #     BroadcastFailedChannelsError for a broadcast which failed in one or more
  #     channels
  class FailedCommand < Data.define(:index, :method, :error)
    include Message
  end

  # A batch in which one or more commands failed, up to all of them. Every
  # command got its own reply: each pending holds its outcome. {#result} is the
  # batch's.
  #
  # It is not an ApiError of its parts: look at each command's error in
  # {#failed}, or at its pending.
  class BatchFailedCommandsError < Error
    # @return [Array<FailedCommand>]
    attr_reader :failed
    # @return [Integer] how many commands the batch had
    attr_reader :total
    # @return [BatchResult]
    attr_reader :result

    # For test doubles, say.
    #
    # @param failed [Array<FailedCommand>]
    # @param total [Integer]
    # @param result [BatchResult]
    def initialize(failed, total, result)
      @failed = failed
      @total = total
      @result = result
      super(nil)
    end

    # @return [String]
    def to_s
      items = failed.map { |f| ["##{f.index} #{f.method}", f.error] }
      Cent.failures_message("batch", "commands", "succeeded", total, items)
    end
  end

  # "broadcast: 2 of 4 channels failed, 2 got the publication: a: ...; b: ..."
  #
  # @api private
  def self.failures_message(op, parts, rest, total, items)
    s = "#{op}: #{items.size} of #{total} #{parts} failed"
    s += ", #{total - items.size} #{rest}" if items.size < total
    named = items.first(MAX_ERROR_ITEMS).map { |label, err| "#{label}: #{err.message}" }
    named << "and #{items.size - MAX_ERROR_ITEMS} more" if items.size > MAX_ERROR_ITEMS
    s += ": #{named.join("; ")}" unless named.empty?
    s
  end

  # Whether a new attempt, with time left, may succeed after +err+: the error
  # came from a temporary condition, not from the request.
  #
  # Retryable are an ApiError Centrifugo marked temporary, and code 100 from
  # Centrifugo versions which did not mark errors yet; a network failure; a
  # timeout, also a caller's own; an HTTPError 429 or 5xx; a broadcast or batch
  # partial error with at least one retryable part.
  #
  # Not retryable are the request's own errors - an unknown channel, a bad
  # request, InvalidRequestError - and InvalidConfigError, ClosedError, a
  # DecodeError, rejected credentials and an invalid TLS certificate.
  #
  # A retryable error does not mean nothing was done: retry a publication only
  # with the same idempotency_key. Retry a broadcast with broadcast_with_retry,
  # or only its retryable_channels: repeating the call resends to the channels
  # which already got it.
  #
  # @param err [Exception, nil]
  # @return [Boolean]
  def self.retryable?(err)
    case err
    when BroadcastFailedChannelsError, BatchFailedCommandsError then err.failed.any? { retryable?(it.error) }
    when ApiError then err.temporary? || err.code == InternalError::CODE
    when HTTPError then err.status_code == 429 || err.status_code >= 500
    when TimeoutError then true
    when NetworkError then !certificate_error?(err)
    else false
    end
  end

  def self.certificate_error?(err)
    cause = err.cause
    while cause
      return true if cause.is_a?(OpenSSL::SSL::SSLError) && cause.message.include?("certificate verify failed")

      cause = cause.cause
    end
    false
  end
  private_class_method :certificate_error?
end
