# frozen_string_literal: true

require "securerandom"

module Cent
  # One HTTP request to Centrifugo's API, for on_request.
  #
  # @!attribute [r] method
  #   @return [String] the API method: "publish", say, or "batch" for a batch
  # @!attribute [r] commands
  #   @return [Integer] how many commands the request carried: 1, or a batch's
  #     size
  # @!attribute [r] failed
  #   @return [Integer] how many of them Centrifugo answered with an error. A
  #     broadcast which failed in some channels is not counted: its command was
  #     answered.
  # @!attribute [r] auto_batch
  #   @return [Boolean] true for a batch made of concurrent calls by automatic
  #     batching
  # @!attribute [r] duration
  #   @return [Float] seconds from before getting the endpoint and credentials
  #     to the reply read
  # @!attribute [r] status_code
  #   @return [Integer] the HTTP status of the reply, 0 without one
  # @!attribute [r] error
  #   @return [Error, nil] the request's own error: the network, a timeout, an
  #     HTTP status, a reply which is not Centrifugo's, a request refused before
  #     sending - or, in the transport error mode, the error of its one command.
  #     nil when Centrifugo's reply was read.
  class RequestInfo < Data.define(:method, :commands, :failed, :auto_batch, :duration, :status_code, :error)
    include Message
  end

  # Calls Centrifugo's HTTP server API. Safe for concurrent use from threads and
  # fibers, and meant to be created once and shared:
  #
  #   client = Cent::Client.new(api_endpoint: "http://localhost:8000/api", api_key: ENV.fetch("CENTRIFUGO_API_KEY"))
  #   client.publish(channel: "news", data: { text: "hello" })
  #
  # There is a method per API method, taking the fields of its request as
  # keyword arguments. Each returns its result, raising unless Centrifugo did
  # everything asked, and takes +timeout:+, in seconds; without one,
  # request_timeout bounds the call. Under a fiber scheduler - Async, Falcon -
  # calls wait without blocking other fibers.
  class Client
    include ClientMethods

    # The User-Agent of every request, unless headers set one.
    USER_AGENT = "rubycent/#{VERSION.split(".").first}".freeze
    # The seconds bounding a call without a timeout of its own, by default.
    DEFAULT_REQUEST_TIMEOUT = 10.0

    # @param api_endpoint [String] the base URL of the API,
    #   "http://localhost:8000/api". Each method is sent to it plus its name,
    #   "/publish".
    # @param api_endpoint_func [#call, nil] instead of api_endpoint, returns it
    #   for each request, for addresses discovered rather than fixed
    # @param api_key [String] sent as X-API-Key. Leave it and bearer_token_func
    #   unset when requests are authenticated another way - mutual TLS, a proxy
    #   - or not at all.
    # @param bearer_token_func [#call, nil] returns the token sent as
    #   "Authorization: Bearer" with each request, for Centrifugo PRO's JWKS
    #   authentication of the API - an {Token::ApiTokens}'s +method(:token)+,
    #   say. Not together with api_key.
    # @param http_options [Hash] Net::HTTP settings for the connections:
    #   +ca_file+, +cert+, +key+, +verify_mode+, +local_host+ and the like.
    # @param http_client [#call, nil] sends requests instead of Net::HTTP - a
    #   fake in tests, another HTTP library: called with the URL, the headers,
    #   the body and the seconds left, it returns +[status, headers, body]+, and
    #   raises Cent::TimeoutError when the time is up. Without one, the client
    #   keeps up to 256 connections to a host alive, never follows redirects,
    #   and closes idle connections after 50 seconds.
    # @param request_timeout [Numeric] seconds bounding a call without a timeout
    #   of its own, 10 by default
    # @param headers [Hash{String => String}] extra headers for every request,
    #   for a proxy in front of Centrifugo. Not X-API-Key, Authorization or
    #   Content-Type. A User-Agent replaces cent's.
    # @param on_request [#call, nil] called after every HTTP request with a
    #   {RequestInfo}, for metrics; the call waits for it
    # @param auto_batch [AutoBatch, nil] sends calls made concurrently in
    #   batches: see {AutoBatch}
    # @param batch_context [#call, nil] with auto_batch, called with the fiber
    #   storages of a batch's callers and a block sending the batch - for a
    #   tracing span linking every caller's. Without it, a batch runs with an
    #   empty fiber storage, carrying no caller's values.
    # @raise [InvalidConfigError] naming the option and the fix
    def initialize(api_endpoint: nil, api_endpoint_func: nil, api_key: "", bearer_token_func: nil,
                   http_options: {}, http_client: nil, request_timeout: DEFAULT_REQUEST_TIMEOUT,
                   headers: {}, on_request: nil, auto_batch: nil, batch_context: nil)
      if api_endpoint.nil? && api_endpoint_func.nil?
        raise InvalidConfigError, "api_endpoint is required, for example http://localhost:8000/api"
      end
      raise InvalidConfigError, "set api_endpoint or api_endpoint_func, not both" if api_endpoint && api_endpoint_func

      @endpoint = api_endpoint && Client.check_endpoint(api_endpoint, "api_endpoint")
      @endpoint_func = callable(api_endpoint_func, "api_endpoint_func")

      raise InvalidConfigError, "api_key must be a String, not #{api_key.class}" unless api_key.is_a?(String)
      unless api_key.empty? || bearer_token_func.nil?
        raise InvalidConfigError,
              "set api_key or bearer_token_func, not both: a request with a bearer token is judged by the token alone"
      end
      unless Client.header_value?(api_key)
        raise InvalidConfigError, "api_key must be printable ASCII: no line breaks, control or non-ASCII characters"
      end

      @token_func = callable(bearer_token_func, "bearer_token_func")
      @headers = check_headers(headers, api_key)

      unless request_timeout.is_a?(Numeric) && request_timeout.positive? && request_timeout.finite?
        raise InvalidConfigError, "request_timeout must be a positive number of seconds"
      end

      @request_timeout = request_timeout.to_f
      @on_request = callable(on_request, "on_request")
      setup_transport(http_client, http_options)
      @calls = Calls.new
      @batcher = batcher(auto_batch, batch_context)
    end

    # @return [Float] the seconds bounding a call without a timeout of its own
    attr_reader :request_timeout

    # An empty {Batch} sent by this client. Without +parallel+ the commands run
    # one by one, in the order added - but Centrifugo PRO sends a sequential
    # batch's publications to its broker together: each channel's take effect
    # in order, publications into different channels may not, unless the
    # namespace sets publication_grouping_disabled. With +parallel+, Centrifugo
    # runs them concurrently, with no order.
    #
    # @param parallel [Boolean]
    # @return [Batch]
    def new_batch(parallel: false) = Batch.new(self, parallel)

    # Stops the client: calls made from now on raise ClosedError, and close
    # waits for the calls in progress to end. A broadcast being retried stops at
    # its next attempt. It raises Cent::TimeoutError when +timeout+, in seconds,
    # passes first; the calls left go on then, and close may be called again.
    # It then closes its idle connections.
    #
    # Call it when the application shuts down - +at_exit+, Puma's
    # +on_worker_shutdown+, Sidekiq's +on(:shutdown)+ - so that what was
    # accepted is sent before the process exits.
    #
    # @param timeout [Numeric, nil]
    # @return [void]
    # @raise [TimeoutError]
    def close(timeout: nil)
      raise TimeoutError, "close: calls still in progress" unless @calls.close(timeout)

      @pool&.close
    end

    # A request's JSON.
    #
    # @api private
    def self.encode(w)
      JSON.generate(w, strict: true, max_nesting: false)
    rescue JSON::GeneratorError, EncodingError => e
      raise InvalidRequestError, "cannot be encoded: #{e.message}"
    end

    # The endpoint without a trailing slash, or InvalidConfigError naming what
    # is wrong.
    #
    # @api private
    def self.check_endpoint(addr, option)
      raise InvalidConfigError, "#{option} must be a String, not #{addr.class}" unless addr.is_a?(String)

      u = begin
        URI.parse(addr)
      rescue URI::Error => e
        raise InvalidConfigError, "#{option}: #{addr.inspect} is not a valid URL: #{e.message}"
      end
      unless u.is_a?(URI::HTTP) && %w[http https].include?(u.scheme&.downcase)
        raise InvalidConfigError, "#{option}: #{addr.inspect} must be an absolute http:// or https:// URL"
      end
      raise InvalidConfigError, "#{option}: #{addr.inspect} has no host" if u.host.nil? || u.host.empty?
      if u.query || u.fragment || u.userinfo
        raise InvalidConfigError,
              "#{option}: #{addr.inspect} must not have a query, fragment or credentials; use api_key"
      end

      path = u.path.sub(%r{/+\z}, "")
      last = path.split("/").last
      if API_METHODS.key?(last)
        raise InvalidConfigError,
              "#{option}: #{addr.inspect} ends with the method #{last.inspect}; " \
              "it is the API base URL, such as http://localhost:8000/api"
      end
      port = u.port == u.default_port ? "" : ":#{u.port}"
      "#{u.scheme.downcase}://#{u.host}#{port}#{path}"
    end

    # @api private
    def self.header_name?(name)
      name.is_a?(String) && !name.empty? &&
        name.each_char.all? { |c| c.ord > 0x20 && c.ord < 0x7F && !'"(),/:;<=>?@[\]{}'.include?(c) }
    end

    # Printable ASCII and tab: what HTTP header values carry without an encoding.
    #
    # @api private
    def self.header_value?(value)
      value.is_a?(String) && value.each_char.all? { |c| (c.ord >= 0x20 && c.ord < 0x7F) || c == "\t" }
    end

    # Sends a batch's body; an empty batch, whose body is nil, sends nothing.
    #
    # @api private
    def send_batch(body, n, timeout)
      @calls.enter
      begin
        return [] if body.nil?

        call("batch", -> { body }, n, deadline(timeout)) do |raw|
          replies = Reply.batch(raw, n)
          [replies, replies.count { !it["error"].nil? }]
        end
      ensure
        @calls.leave
      end
    end

    # An automatic batch: counted as a call by its batcher, closed or not.
    #
    # @api private
    def send_auto_batch(body, n, timeout)
      call("batch", -> { body }, n, HTTP.now + timeout, auto: true) do |raw|
        replies = Reply.batch(raw, n)
        [replies, replies.count { !it["error"].nil? }]
      end
    end

    # @api private
    attr_reader :calls

    private

    def setup_transport(http_client, http_options)
      raise InvalidConfigError, "http_options must be a Hash" unless http_options.is_a?(Hash)

      if http_client
        unless http_options.empty?
          raise InvalidConfigError, "http_options are for the default transport: configure http_client instead"
        end

        @http = callable(http_client, "http_client")
        @pool = nil
      else
        check_http_options(http_options)
        @pool = HTTP::Pool.new(http_options)
      end
    end

    def batcher(auto_batch, batch_context)
      unless auto_batch.nil? || auto_batch.is_a?(AutoBatch)
        raise InvalidConfigError, "auto_batch must be a Cent::AutoBatch"
      end
      raise InvalidConfigError, "batch_context is for auto_batch: set both, or neither" if batch_context && !auto_batch

      auto_batch && AutoBatch::Batcher.new(self, auto_batch, callable(batch_context, "batch_context"))
    end

    def callable(f, name)
      raise InvalidConfigError, "#{name} must respond to call" unless f.nil? || f.respond_to?(:call)

      f
    end

    def check_headers(headers, api_key)
      raise InvalidConfigError, "headers must be a Hash" unless headers.is_a?(Hash)

      h = {}
      headers.each do |k, v|
        k = k.to_s
        case k.downcase
        when "x-api-key" then raise InvalidConfigError, "headers may not set X-API-Key; use api_key"
        when "authorization" then raise InvalidConfigError, "headers may not set Authorization; use bearer_token_func"
        when "content-type" then raise InvalidConfigError, "headers may not set Content-Type"
        end
        raise InvalidConfigError, "headers: #{k.inspect} is not a valid HTTP header name" unless Client.header_name?(k)
        unless Client.header_value?(v)
          raise InvalidConfigError,
                "headers: #{k} must be a String of printable ASCII: no line breaks, control or non-ASCII characters"
        end
        raise InvalidConfigError, "headers: Host must not be empty" if k.casecmp?("host") && v.empty?

        h[k] = v
      end
      h["Content-Type"] = "application/json"
      h["User-Agent"] = USER_AGENT unless h.keys.any? { it.casecmp?("user-agent") }
      h["X-API-Key"] = api_key unless api_key.empty?
      h.freeze
    end

    # Timeouts are cent's: one deadline per call.
    OWN_HTTP_OPTIONS = %i[open_timeout read_timeout write_timeout ssl_timeout keep_alive_timeout max_retries].freeze
    private_constant :OWN_HTTP_OPTIONS

    def check_http_options(options)
      probe = Net::HTTP.new("localhost")
      options.each_key do |k|
        if OWN_HTTP_OPTIONS.include?(k.to_sym)
          raise InvalidConfigError, "http_options: #{k} is cent's to set: a call is bounded by its timeout"
        end
        raise InvalidConfigError, "http_options: #{k} is not a Net::HTTP setting" unless probe.respond_to?(:"#{k}=")
      end
    end

    def deadline(timeout)
      return HTTP.now + @request_timeout if timeout.nil?
      unless timeout.is_a?(Numeric) && !timeout.negative?
        raise InvalidRequestError, "timeout must be a non-negative number of seconds"
      end

      HTTP.now + timeout
    end

    def encode_request(method)
      Reply.validate(method, yield)
    rescue InvalidRequestError => e
      raise InvalidRequestError, "invalid #{method} request: #{e.message}"
    end

    # The result of an API call, as the Hash of its reply.
    def call_result(method, timeout, &)
      wire = encode_request(method, &)
      deadline = deadline(timeout)
      @calls.enter
      begin
        alone = lambda do
          call(method, -> { Client.encode(wire) }, 1, deadline) do |raw|
            out = Reply.envelope(raw, method)
            [out, out[1] ? 1 : 0]
          end
        end
        if @batcher
          went_alone, out = @batcher.call(method, wire, deadline, alone)
          if went_alone
            result, err = out
          else
            index, reply = out
            err = Reply.command_error(reply, index, method)
            result = Wire.obj(reply[method] || {}, "replies[#{index}].#{method}")
          end
        else
          result, err = alone.call
        end
      ensure
        @calls.leave
      end
      raise err if err

      result
    end

    def invoke(method, result_class, timeout, &)
      result_class.from_wire(call_result(method, timeout, &), "#{method} result")
    end

    def call(method, make_body, commands, deadline, auto: false)
      start = HTTP.now
      status = [0]
      begin
        out, failed = yield roundtrip(method, make_body, deadline, status)
      rescue StandardError => e
        report(method, commands, 0, auto, start, status[0], e)
        raise
      end
      report(method, commands, failed, auto, start, status[0], nil)
      out
    end

    def roundtrip(method, make_body, deadline, status)
      base = @endpoint || Client.check_endpoint(@endpoint_func.call, "api_endpoint_func")
      headers = @headers
      if @token_func
        token = @token_func.call
        unless token.is_a?(String) && !token.empty? && Client.header_value?(token)
          raise InvalidConfigError,
                "bearer_token_func returned an empty token, not a String, or one which is not printable ASCII"
        end

        headers = headers.merge("Authorization" => "Bearer #{token}")
      end
      body = begin
        make_body.call
      rescue InvalidRequestError => e
        raise InvalidRequestError, "invalid #{method} request: #{e.message}"
      end
      left = deadline - HTTP.now
      raise TimeoutError, "#{method}: timed out" if left <= 0

      code, resp_headers, data = send_http("#{base}/#{method}", headers, body, deadline, left)
      status[0] = code
      raise Reply.http_error(method, code, data, resp_headers) if code != 200

      data
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, IO::TimeoutError => e
      raise TimeoutError, "#{method}: timed out: #{e.message}"
    rescue Net::HTTPBadResponse, Zlib::Error => e
      raise DecodeError, "#{method}: the reply cannot be decoded: #{e.message}"
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::ProtocolError => e
      raise NetworkError, "#{method}: #{e.class}: #{e.message}"
    end

    def send_http(url, headers, body, deadline, left)
      return @pool.post(url, headers, body, deadline) if @pool

      code, resp_headers, data = @http.call(url, headers, body, left)
      [code, resp_headers.to_h.transform_keys { it.to_s.downcase }, data.to_s]
    end

    def report(method, commands, failed, auto, start, status, error)
      return unless @on_request

      @on_request.call(RequestInfo.new(method:, commands:, failed:, auto_batch: auto, duration: HTTP.now - start,
                                       status_code: status, error:))
    end

    # Broadcast.

    def send_broadcast(timeout, &build)
      wire = nil
      raw = call_result("broadcast", timeout) { wire = build.call }
      BroadcastResult.from_wire(raw, wire["channels"], wire["idempotency_key"] || "").check!
    end

    def retry_broadcast(max_attempts, attempt_timeout, timeout, on_attempt_error, &)
      check_retry_options(max_attempts, attempt_timeout)
      wire = encode_request("broadcast", &)
      # Without a timeout the call has no bound of its own: each attempt has
      # attempt_timeout, or request_timeout as a call alone would, so that an
      # attempt which hangs leaves time to retry.
      deadline = timeout.nil? ? Float::INFINITY : deadline(timeout)
      per_attempt = attempt_timeout || @request_timeout
      state = RetryState.new(wire)
      last = nil
      (1..max_attempts).each do |attempt|
        left = deadline - HTTP.now
        if left <= 0
          last ||= TimeoutError.new("broadcast: timed out")
          break
        end
        res, err = broadcast_attempt(state.attempt_wire, [left, per_attempt].min)
        state.record(res, err)
        last = err
        # An ended deadline leaves no time for another attempt.
        break if err.nil? || !Cent.retryable?(err) || attempt == max_attempts || HTTP.now >= deadline

        retry_channels = state.next_channels(res)
        wait = on_attempt_error && attempt_error(on_attempt_error, err) do
          BroadcastAttempt.new(attempt:, error: err, retry: retry_channels, result: state.result,
                               idempotency_key: state.key)
        end
        sleep((wait.nil? ? Cent.default_delay(attempt) : wait.to_f).clamp(0, [deadline - HTTP.now, 0].max))
        raise ClosedError, "client closed" if @calls.closed?
      end
      state.outcome(last)
    end

    def check_retry_options(max_attempts, attempt_timeout)
      unless max_attempts.is_a?(Integer) && max_attempts >= 1
        raise InvalidRequestError, "invalid broadcast request: max_attempts must be 1 or more"
      end
      return if attempt_timeout.nil? || (attempt_timeout.is_a?(Numeric) && attempt_timeout.positive?)

      raise InvalidRequestError, "invalid broadcast request: attempt_timeout must be positive"
    end

    # [result, error] of an attempt of broadcast_with_retry.
    def broadcast_attempt(wire, timeout)
      [send_broadcast(timeout) { wire }, nil]
    rescue InvalidRequestError
      raise
    rescue BroadcastFailedChannelsError => e
      [e.result, e]
    rescue Error => e
      [BroadcastResult.failed_as_whole(wire["channels"], e, 1), e]
    end

    # What broadcast_with_retry's block returns. To stop, it raises: its
    # exception propagates, its cause the attempt's error.
    def attempt_error(on_attempt_error, err)
      on_attempt_error.call(yield)
    rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised, with its cause
      raise e, cause: err if e.cause.nil? && !e.equal?(err)

      raise
    end

    # The outcome of broadcast_with_retry's attempts so far.
    #
    # @api private
    class RetryState
      attr_reader :key

      def initialize(wire)
        @wire = wire
        @channels = wire["channels"]
        @key = wire["idempotency_key"] || "rubycent-#{SecureRandom.urlsafe_base64(18)}"
        @final = @channels.map { ChannelResult.new(channel: it) }
        @attempts = 0
        # Positions in channels of what the next attempt sends: positions, not
        # names, so that a channel listed twice keeps both entries.
        @pending = (0...@channels.size).to_a
        @replied = false
      end

      def attempt_wire = @wire.merge("channels" => @pending.map { @channels[it] }, "idempotency_key" => @key)

      def record(res, err)
        @attempts += 1
        @pending.each_with_index do |pos, i|
          @final[pos] = res.channels[i].with(attempts: @final[pos].attempts + 1)
        end
        @replied = true if err.nil? || err.is_a?(BroadcastFailedChannelsError)
      end

      # Keeps in pending the channels which may still succeed, and returns them.
      def next_channels(res)
        @pending = @pending.each_with_index.filter_map { |pos, i| pos if Cent.retryable?(res.channels[i].error) }
        @pending.map { @final[it] }
      end

      def result
        BroadcastResult.new(channels: @final.dup, idempotency_key: @key, attempts: @attempts, replied: @replied)
      end

      # The final result, or the error to raise: BroadcastFailedChannelsError
      # when some attempt got a reply, the last attempt's error otherwise.
      def outcome(last)
        raise last unless @replied

        result.check!
      end
    end
    private_constant :RetryState

    # The calls in progress, so that close can wait for them.
    #
    # @api private
    class Calls
      def initialize
        @lock = Mutex.new
        @idle = ConditionVariable.new
        @active = 0
        @closed = false
      end

      def closed? = @closed

      def enter
        @lock.synchronize do
          raise ClosedError, "client closed" if @closed

          @active += 1
        end
      end

      # Counts in work going on for calls already counted - an automatic batch
      # which outlives its callers - closed or not.
      def add = @lock.synchronize { @active += 1 }

      def leave
        @lock.synchronize do
          @active -= 1
          @idle.broadcast if @active.zero?
        end
      end

      def close(timeout)
        deadline = timeout && (HTTP.now + timeout)
        @lock.synchronize do
          @closed = true
          until @active.zero?
            left = deadline && (deadline - HTTP.now)
            return false if left && left <= 0

            @idle.wait(@lock, left)
          end
          true
        end
      end
    end
    private_constant :Calls
  end
end
