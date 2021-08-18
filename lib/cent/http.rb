# frozen_string_literal: true

require 'cent/error'

module Cent
  # Cent::ResponseError
  #
  #   Raised when response from Centrifugo contains any error as result of API command execution.
  #
  class ResponseError < Error
    attr_reader :code

    def initialize(code:, message:)
      @code = code
      super message
    end
  end

  # Cent::HTTP
  #
  #   Holds request call and response handling logic
  #
  class HTTP
    attr_reader :connection

    # @param connection [Faraday::Connection] HTTP Connection object
    #
    def initialize(connection:)
      @connection = connection
    end

    # Perform POST request to centrifugo API
    # @param body [Hash] Request body(non serialized)
    #
    # @raise [Cent::ResponseError]
    #
    # @return [Hash] Parsed response body
    #
    def post(body: nil)
      response = connection.post(nil, body)

      raise ResponseError, response.body['error'].transform_keys(&:to_sym) if response.body.key?('error')

      response.body
    end
  end
end
