# frozen_string_literal: true

module Cent
  # Reading Centrifugo's replies, and the rules checked before sending.
  #
  # @api private
  module Reply
    # Statuses Centrifugo's transport error mode maps errors to.
    TRANSPORT_MODE_STATUSES = [400, 404, 409, 416, 429, 500].freeze
    MIN_ERROR_CODE = 100
    # nil is "no data", as for every keyword: how to publish JSON null.
    NULL_HINT = " (to publish JSON null, pass data: JSON::Fragment.new(\"null\"))"

    module_function

    def parse(body, method)
      JSON.parse(body, allow_nan: false, max_nesting: false)
    rescue JSON::ParserError, EncodingError => e
      raise DecodeError, "#{method}: the reply is not JSON: #{e.message}"
    end

    # The decoded reply of a method: [its result, its error].
    def envelope(body, method)
      d = parse(body, method)
      raise DecodeError, "#{method}: the reply is not a JSON object" unless d.is_a?(Hash)
      return [{}, api_error(d["error"], "error")] unless d["error"].nil?

      result = d["result"]
      return [{}, nil] if result.nil?
      raise DecodeError, "#{method}: result: expected an object" unless result.is_a?(Hash)

      [result, nil]
    end

    # The replies of a batch of n commands.
    def batch(body, n)
      d = parse(body, "batch")
      raise DecodeError, "batch: the reply is not a JSON object" unless d.is_a?(Hash)
      raise api_error(d["error"], "error") unless d["error"].nil?

      replies = d["replies"] || []
      unless replies.is_a?(Array) && replies.all?(Hash)
        raise DecodeError, "batch: replies: expected an array of objects"
      end
      raise DecodeError, "batch: got #{replies.size} replies for #{n} commands" if replies.size != n

      replies
    end

    # The ApiError of an error object in a reply.
    def api_error(v, where)
      d = Wire.obj(v, where)
      ApiError.for_code(Wire.get(d, "code", where, :int), Wire.get(d, "message", where, :str),
                        temporary: Wire.get(d, "temporary", where, :bool))
    end

    # The error of a batch command's reply, if it has one. A PRO method's code
    # 104 hints that the server may be Centrifugo OSS.
    def command_error(reply, i, method)
      return nil if reply["error"].nil?

      err = api_error(reply["error"], "replies[#{i}].error")
      err.pro_method!(method) if err.code == NotFoundError::CODE && API_METHODS[method]
      err
    end

    # The error of a reply with a status other than 200: a Centrifugo error in
    # the transport error mode, an HTTPError otherwise.
    def http_error(method, status, body, headers)
      if TRANSPORT_MODE_STATUSES.include?(status)
        d = begin
          JSON.parse(body)
        rescue JSON::ParserError, EncodingError
          nil
        end
        # A body whose code is an HTTP error status - {"code": 429} from a rate
        # limiting gateway - is a gateway's, not Centrifugo's.
        code = d["code"] if d.is_a?(Hash)
        if code.is_a?(Integer) && code >= MIN_ERROR_CODE && !(400..599).cover?(code)
          begin
            return api_error(d, "error")
          rescue DecodeError
            nil
          end
        end
      end
      start = body.byteslice(0, HTTP::MAX_ERROR_BODY_BYTES).strip
      err = (status == 401 ? UnauthorizedError : HTTPError).new(status, start, headers)
      err.pro_method!(method) if API_METHODS[method]
      err
    end

    # The rules every Centrifugo holds a request to, checked before sending.
    # Everything else Centrifugo checks itself.
    def validate(method, w)
      case method
      when "publish"
        raise InvalidRequestError, "channel is required" unless w["channel"]
        raise InvalidRequestError, "data or b64data is required#{NULL_HINT}" unless w.key?("data") || w["b64data"]
      when "broadcast"
        channels = w["channels"]
        raise InvalidRequestError, "channels is required" unless channels
        raise InvalidRequestError, "data or b64data is required#{NULL_HINT}" unless w.key?("data") || w["b64data"]

        channels.each_with_index { |ch, i| raise InvalidRequestError, "channels[#{i}] is empty" if ch.empty? }
      end
      w
    end
  end
end
