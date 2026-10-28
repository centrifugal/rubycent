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
      walk(value, where, 0)
      value
    end

    def walk(value, where, depth)
      raise InvalidRequestError, "#{where} is nested too deeply, or contains itself" if depth > MAX_DEPTH

      case value
      when Hash
        value.each do |k, v|
          case k
          when String then string!(k, "#{where} key #{k.inspect}")
          when Symbol then nil
          else raise InvalidRequestError, "#{where} has a #{k.class} key, #{k.inspect}: JSON object keys are strings"
          end
          walk(v, "#{where}.#{k}", depth + 1)
        end
      when Array
        value.each_with_index { |v, i| walk(v, "#{where}[#{i}]", depth + 1) }
      when String then string!(value, where)
      when Float
        raise InvalidRequestError, "#{where} is #{value}, which is not a JSON number" unless value.finite?
      when Integer, true, false, nil, Symbol then nil
      when JSON::Fragment then fragment!(value, where)
      else
        raise InvalidRequestError,
              "#{where} is a #{value.class}, which is not a JSON value: convert it - " \
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
