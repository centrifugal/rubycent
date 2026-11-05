# frozen_string_literal: true

require "uri"

module Cent
  # A request to a handler, as the application's block receives it.
  #
  # @!attribute [r] method
  #   @return [String] the HTTP method, upper case
  # @!attribute [r] headers
  #   @return [Hash{String => String}] the headers, lowercase names: those
  #     Centrifugo passes on from the client's connection to a proxy, the client
  #     SDK's to an endpoint
  # @!attribute [r] query
  #   @return [Hash{String => String}] the query parameters, the first value of
  #     each
  # @!attribute [r] path
  #   @return [String] the path, as the server saw it
  # @!attribute [r] raw
  #   @return [Object] the server's own form of the request: the Rack env, or
  #     what was given to {Handler#handle} - for what the core does not carry,
  #     such as the client's address or the session
  class HTTPRequest < Data.define(:method, :headers, :query, :path, :raw); end

  # A handler's answer: +[status, headers, body]+ with {#to_a}.
  #
  # @!attribute [r] status
  #   @return [Integer]
  # @!attribute [r] headers
  #   @return [Hash{String => String}] lowercase names, as Rack 3 wants them
  # @!attribute [r] body
  #   @return [String]
  class HTTPResponse < Data.define(:status, :headers, :body)
    # @return [Array] +[status, headers, body]+
    def to_a = [status, headers, body]

    # @api private
    def self.text(status, message, extra = {})
      new(status:, headers: { "content-type" => "text/plain; charset=utf-8", **extra }, body: message)
    end

    # @api private
    REASONS = { 400 => "Bad Request", 403 => "Forbidden", 405 => "Method Not Allowed",
                500 => "Internal Server Error" }.freeze

    # @api private
    def self.status_text(status) = text(status, REASONS.fetch(status, status.to_s))

    # @api private
    def self.allow(methods) = text(405, "only #{methods} allowed", { "allow" => methods })

    # @api private
    def self.json(body, cache = "no-store")
      new(status: 200, headers: { "content-type" => "application/json", "cache-control" => cache }, body:)
    end
  end

  # The base of every handler - an endpoint for client SDKs, the JWKS endpoint,
  # a proxy handler. Its framework-free core, {#handle}, turns a request into a
  # response; {#call} serves it as a Rack app, which Rails, Sinatra, Hanami and
  # every Rack server mount:
  #
  #   mount handler, at: "/centrifugo/connect"   # config/routes.rb
  #
  # Any other server calls {#handle}.
  class Handler
    # @return [Integer] the largest request body read, in bytes
    attr_reader :max_body

    # @api private
    def initialize(max_body, on_error, &func)
      raise ArgumentError, "#{self.class} takes a block" if func.nil? && !answers_itself?
      raise ArgumentError, "on_error must respond to call" unless on_error.nil? || on_error.respond_to?(:call)
      unless max_body.is_a?(Integer) && max_body.positive?
        raise ArgumentError,
              "max_body must be a positive number of bytes"
      end

      @max_body = max_body
      @on_error = on_error
      @func = func
    end

    # Answers a request.
    #
    # @param method [String]
    # @param headers [Hash{String => String}, Array<Array(String, String)>]
    # @param body [String]
    # @param query [Hash{String => String}]
    # @param path [String]
    # @param raw [Object] passed on as {HTTPRequest#raw}: the server's own
    #   request object
    # @return [HTTPResponse]
    def handle(method, headers = {}, body = "", query: {}, path: "", raw: nil)
      h = {}
      headers.each do |k, v|
        k = k.to_s.downcase
        h[k] = h.key?(k) ? "#{h[k]}, #{v}" : v.to_s
      end
      req = HTTPRequest.new(method: method.to_s.upcase, headers: h.freeze, query: query.to_h.freeze, path:, raw:)
      return failure(req, 400, ArgumentError.new("request body over #{max_body} bytes")) if body.bytesize > max_body

      begun = start(req, body)
      return begun if begun.is_a?(HTTPResponse)

      begin
        out = @func.call(*begun, req)
      rescue StandardError => e
        return finish(req, begun, nil, e)
      end
      finish(req, begun, out, nil)
    end

    # The handler as a Rack app.
    #
    # @param env [Hash] the Rack env
    # @return [Array] +[status, headers, [body]]+
    def call(env)
      body = read_body(env)
      headers = env.filter_map { |k, v| [k.delete_prefix("HTTP_").tr("_", "-"), v] if k.start_with?("HTTP_") }
      headers << ["content-type", env["CONTENT_TYPE"]] if env["CONTENT_TYPE"]
      headers << ["content-length", env["CONTENT_LENGTH"]] if env["CONTENT_LENGTH"]
      query = {}
      URI.decode_www_form(env["QUERY_STRING"].to_s).each { |k, v| query[k] ||= v }
      resp = handle(env["REQUEST_METHOD"], headers, body, query:, path: env["PATH_INFO"].to_s, raw: env)
      [resp.status, resp.headers.dup, [resp.body]]
    rescue ArgumentError => e
      # A malformed query string.
      resp = failure(HTTPRequest.new(method: env["REQUEST_METHOD"].to_s, headers: {}, query: {}, path: "", raw: env),
                     400, e)
      [resp.status, resp.headers.dup, [resp.body]]
    end

    private

    def answers_itself? = false

    # The block's arguments before the request, or the response when the
    # request is answered without calling it.
    def start(req, body) = raise NotImplementedError

    # The response to what the block returned or raised.
    def finish(req, args, out, error) = raise NotImplementedError

    # +status+, after telling on_error of +err+.
    def failure(req, status, err)
      @on_error&.call(req, err)
      HTTPResponse.status_text(status)
    end

    def read_body(env)
      input = env["rack.input"]
      return "" if input.nil?

      # A framework may have read it already: Rails does.
      input.rewind if input.respond_to?(:rewind)
      (input.read(max_body + 1) || "").b
    end

    # err, or its cause, when it is a klass.
    def find(err, klass)
      while err
        return err if err.is_a?(klass)

        err = err.cause
      end
      nil
    end

    def parse_json(req, body)
      d = JSON.parse(body, allow_nan: false)
      return failure(req, 400, ArgumentError.new("malformed request: not a JSON object")) unless d.is_a?(Hash)

      d
    rescue JSON::ParserError, EncodingError => e
      failure(req, 400, ArgumentError.new("malformed request: #{e.message}"))
    end
  end
end
