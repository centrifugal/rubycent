# frozen_string_literal: true

module Cent
  # Payloads - data, info, meta and the like - are JSON values: a Hash, Array,
  # String, Integer, Float, true, false or nil, Symbols allowed as strings and
  # Hash keys. Raw JSON - text you already have, or encoded with rules of your
  # own - goes in a +JSON::Fragment+, sent as it is:
  #
  #   client.publish(channel: "news", data: { text: "hi" })
  #   client.publish(channel: "news", data: JSON::Fragment.new(row["payload_json"]))
  #
  # A String is a JSON string, never raw JSON. Replies give payloads as
  # +JSON.parse+ gives them - Hashes with String keys - which go back unchanged
  # as the same JSON value.
  #
  # @api private
  module Payload
    # Deeper than this, a payload is refused: Centrifugo's decoder stops at
    # 10000 levels, and a value which contains itself never ends.
    MAX_DEPTH = 1000

    module_function

    # Checks that a payload is a JSON value, raising InvalidRequestError naming
    # where it is not. The checked value is sent as it is.
    #
    # @return [Object] value
    def check!(value, where)
      # Iterative, not recursive: a deep value must not overflow the stack,
      # which is small on some platforms - a thread's on Windows.
      stack = [[value, where, 0]]
      until stack.empty?
        v, path, depth = stack.pop
        raise InvalidRequestError, "#{path} is nested too deeply, or contains itself" if depth > MAX_DEPTH

        case v
        when Hash
          v.each do |k, item|
            key!(k, path)
            stack << [item, "#{path}.#{k}", depth + 1]
          end
        when Array then v.each_with_index { |item, i| stack << [item, "#{path}[#{i}]", depth + 1] }
        else scalar!(v, path)
        end
      end
      value
    end

    def key!(k, path)
      case k
      when String then string!(k, "#{path} key #{k.inspect}")
      when Symbol then nil
      else raise InvalidRequestError, "#{path} has a #{k.class} key, #{k.inspect}: JSON object keys are strings"
      end
    end

    def scalar!(v, path)
      case v
      when String then string!(v, path)
      when Float
        raise InvalidRequestError, "#{path} is #{v}, which is not a JSON number" unless v.finite?
      when Integer, true, false, nil, Symbol then nil
      when JSON::Fragment then fragment!(v, path)
      else
        raise InvalidRequestError,
              "#{path} is a #{v.class}, which is not a JSON value: convert it - " \
              "or encode the payload yourself and pass the JSON as JSON::Fragment.new(json)"
      end
    end

    def string!(s, where)
      if s.encoding == Encoding::BINARY
        raise InvalidRequestError,
              "#{where} is a binary (ASCII-8BIT) string: force_encoding(\"UTF-8\") text read as bytes, " \
              "or send binary data base64-encoded in a b64 field, such as b64data"
      end
      raise InvalidRequestError, "#{where} is not valid #{s.encoding}" unless s.valid_encoding?
    end

    # Raw JSON is checked to be valid JSON, NaN and infinities refused.
    def fragment!(f, where)
      json = f.json
      unless json.is_a?(String)
        raise InvalidRequestError, "#{where} is a JSON::Fragment of a #{json.class}: it holds JSON text"
      end

      string!(json, where)
      JSON.parse(json, allow_nan: false, max_nesting: false)
    rescue JSON::ParserError => e
      raise InvalidRequestError, "#{where} is a JSON::Fragment which is not valid JSON: #{e.message}"
    end
  end
end
