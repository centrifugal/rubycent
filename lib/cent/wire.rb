# frozen_string_literal: true

module Cent
  # Encoding requests and decoding replies, for the generated code: each field
  # is put or got by its kind - :str, :bool, :int, :float, :json (a payload),
  # :bool_value and :int32_value (protobuf wrappers), or a message's class - and
  # its shape - :one, :list or :map.
  #
  # @api private
  module Wire
    ZERO = { str: "", bool: false, int: 0, float: 0.0 }.freeze

    module_function

    # Sets +w[key]+ to the encoded field +v+, unless it is unset or at its zero
    # value: nil, "", false, 0, an empty list or map, a message with nothing set.
    # +where+ prefixes the field's name in error messages.
    def put(w, key, v, where, kind, shape = :one)
      return if v.nil?

      out =
        case shape
        when :list
          raise InvalidRequestError, "#{where}#{key} must be an Array, not #{kind_of(v)}" unless v.is_a?(Array)
          return if v.empty?

          v.each_with_index.map { |item, i| value(kind, item, "#{where}#{key}[#{i}]", true) }
        when :map
          raise InvalidRequestError, "#{where}#{key} must be a Hash, not #{kind_of(v)}" unless v.is_a?(Hash)
          return if v.empty?

          v.each_with_object({}) do |(k, item), h|
            name = map_key(k, "#{where}#{key}")
            h[name] = value(kind, item, "#{where}#{key}[#{name.inspect}]", true)
          end
        else value(kind, v, "#{where}#{key}", false)
        end
      w[key] = out unless out.nil?
    end

    # One value of a field, encoded; nil for a zero value, unless +keep+ (an
    # item of a list or map).
    def value(kind, v, path, keep)
      case kind
      when :str, :bool, :int, :float then scalar(kind, v, path, keep)
      when :json then Payload.check!(v, path)
      when :bool_value
        raise InvalidRequestError, "#{path} must be true or false, not #{kind_of(v)}" unless [true, false].include?(v)

        { "value" => v }
      when :int32_value
        raise InvalidRequestError, "#{path} must be an Integer, not #{kind_of(v)}" unless v.is_a?(Integer)

        { "value" => v }
      else
        w = message(kind, v, path).to_wire("#{path}.")
        w.empty? && !keep ? nil : w
      end
    end

    def scalar(kind, v, path, keep)
      case kind
      when :str
        s = case v
            when String then v
            when Symbol then v.name
            else raise InvalidRequestError, "#{path} must be a String, not #{kind_of(v)}"
            end
        Payload.string!(s, path)
        s.empty? && !keep ? nil : s
      when :bool
        raise InvalidRequestError, "#{path} must be true or false, not #{kind_of(v)}" unless [true, false].include?(v)

        v || keep ? v : nil
      when :int
        raise InvalidRequestError, "#{path} must be an Integer, not #{kind_of(v)}" unless v.is_a?(Integer)

        v.zero? && !keep ? nil : v
      when :float
        unless (v.is_a?(Float) && v.finite?) || v.is_a?(Integer)
          raise InvalidRequestError, "#{path} must be a finite number, not #{kind_of(v)}"
        end

        v.zero? && !keep ? nil : v
      end
    end

    # A message given as its class's instance, or as a Hash of its fields.
    def message(klass, v, path)
      return v if v.is_a?(klass)
      unless v.is_a?(Hash)
        raise InvalidRequestError, "#{path} must be a #{short(klass)} or a Hash of its fields, not #{kind_of(v)}"
      end

      v.each_key do |k|
        next if k.is_a?(Symbol) && klass.members.include?(k)

        name = k.to_s
        if k.is_a?(String) && klass.members.include?(name.to_sym)
          raise InvalidRequestError, "#{path}: field names are Symbols - #{name}:, not #{name.inspect}"
        end

        like = DidYouMean::SpellChecker.new(dictionary: klass.members.map(&:name)).correct(name).first
        raise InvalidRequestError,
              "#{path}.#{name} is not a field of #{short(klass)}#{": did you mean #{like}?" if like}"
      end
      klass.new(**v)
    end

    def map_key(k, path)
      case k
      when String
        Payload.string!(k, "#{path} key #{k.inspect}")
        k
      when Symbol then k.name
      else raise InvalidRequestError, "#{path} has a #{k.class} key, #{k.inspect}: keys are strings"
      end
    end

    # The field +key+ of the decoded object +d+, at its zero value when the reply
    # left it out; fields the client does not know are ignored.
    def get(d, key, where, kind, shape = :one)
      v = d[key]
      case shape
      when :list
        return [] if v.nil?
        raise DecodeError, "#{where}.#{key}: expected an array, got #{kind_of(v)}" unless v.is_a?(Array)

        v.each_with_index.map { |item, i| decode(kind, item, "#{where}.#{key}[#{i}]") }
      when :map
        return {} if v.nil?

        obj(v, "#{where}.#{key}").to_h { |k, item| [k, decode(kind, item, "#{where}.#{key}[#{k.inspect}]")] }
      else
        return ZERO.fetch(kind, nil) if v.nil? && kind != :json

        decode(kind, v, "#{where}.#{key}")
      end
    end

    def decode(kind, v, path)
      case kind
      when :str
        raise DecodeError, "#{path}: expected a string, got #{kind_of(v)}" unless v.is_a?(String)
      when :bool
        raise DecodeError, "#{path}: expected a boolean, got #{kind_of(v)}" unless [true, false].include?(v)
      when :int
        raise DecodeError, "#{path}: expected an integer, got #{kind_of(v)}" unless v.is_a?(Integer)
      when :float
        raise DecodeError, "#{path}: expected a number, got #{kind_of(v)}" unless v.is_a?(Numeric)

        return v.to_f
      when :json then nil
      when :bool_value, :int32_value
        inner = obj(v, path)["value"]
        # The value's zero, which a protobuf encoder leaves out.
        return kind == :bool_value ? false : 0 if inner.nil?

        return decode(kind == :bool_value ? :bool : :int, inner, "#{path}.value")
      else return kind.from_wire(v, path)
      end
      v
    end

    def obj(v, where)
      raise DecodeError, "#{where}: expected an object, got #{kind_of(v)}" unless v.is_a?(Hash)

      v
    end

    def kind_of(v)
      case v
      when nil then "nil"
      when true, false then v.to_s
      when String then "a String"
      when Integer then "an Integer, #{v}"
      when Float then "a Float, #{v}"
      when Array then "an Array"
      when Hash then "a Hash"
      else "a #{v.class}"
      end
    end

    def short(klass) = klass.name.delete_prefix("Cent::")
  end
end
