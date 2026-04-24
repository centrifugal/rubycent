# frozen_string_literal: true

module Cent
  # Base class for all errors raised by this library.
  class Error < StandardError; end

  # Raised when Centrifugo is unreachable (DNS failure, connection refused, ...).
  class NetworkError < Error; end

  # Raised when the HTTP request times out.
  class TimeoutError < Error; end

  # Raised when Centrifugo returns a non-2xx HTTP status.
  class TransportError < Error
    attr_reader :status

    def initialize(status:, message: nil)
      @status = status
      super(message || "HTTP #{status}")
    end
  end

  # Raised when Centrifugo returns HTTP 401 (invalid API key).
  class UnauthorizedError < TransportError; end

  # Raised when response from Centrifugo cannot be decoded (not valid JSON).
  class DecodeError < Error; end

  # Raised when Centrifugo returns a top-level `error` in the response body
  # (API-level failure, e.g., unknown channel, namespace not found). Exposes
  # Centrifugo's numeric `code` and human-readable `message`. See
  # https://centrifugal.dev/docs/server/server_api#error for the full list
  # of codes.
  #
  # Note: for `batch` and `broadcast`, individual sub-reply errors are NOT
  # raised — those responses contain an array of independent replies, and
  # each entry should be inspected by the caller for its own `error` key.
  class ResponseError < Error
    attr_reader :code

    def initialize(code:, message:)
      @code = code
      super(message)
    end
  end
end
