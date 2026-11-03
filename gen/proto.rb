# frozen_string_literal: true

# A parser for the part of proto3 Centrifugo's api.proto and proxy.proto use.
#
# Top-level messages with scalar, message, repeated and map fields, and one
# service whose methods may stream. Anything else - a oneof, an enum, a nested
# message - fails the generation, rather than being dropped from the SDK
# without a word.
module Proto
  SCALARS = %w[string bool int32 int64 uint32 uint64 double float bytes].freeze

  Field = Struct.new(:name, :type, :repeated, :map_key, :doc, keyword_init: true) do
    def map? = !map_key.empty?
    def list? = repeated
    def scalar? = SCALARS.include?(type)
  end
  Message = Struct.new(:name, :doc, :fields, keyword_init: true)
  Method = Struct.new(:name, :request, :response, :streaming, keyword_init: true)
  Schema = Struct.new(:messages, :by_name, :methods, keyword_init: true)

  class Error < StandardError; end

  # What the generator reads in the comments.

  # A field the proto marks "Required." without a condition: "Required unless
  # ..." and "Required when ..." are conditional, and so are not.
  def self.required?(field) = field.doc.join(" ").match?(/\bRequired\./)

  # A required field whose comment gives its empty value a meaning after
  # "Required." - `"" detaches the devices`, `An empty map clears it.` - which
  # is not checked before sending: empty is one of its values.
  def self.empty_has_meaning?(field)
    _, sep, after = field.doc.join(" ").partition(/\bRequired\./)
    !sep.empty? && (after.include?('""') || after.match?(/\bempty\b/i))
  end

  # The values a field's comment lists in the sentence "One of: add, remove,
  # set.", the protos' convention for a string field with a fixed set of
  # values; nil without one. A malformed one fails the generation rather than
  # being skipped.
  def self.listed_values(field)
    _, sep, after = field.doc.join(" ").partition("One of:")
    return nil if sep.empty?

    list, dot, = after.partition(".")
    raise Error, 'the values after "One of:" must end with a period' if dot.empty?

    list.split(",").map(&:strip).each_with_object([]) do |v, values|
      unless v.match?(/\A[a-z][a-z0-9_]*\z/)
        raise Error, "#{v.inspect} is not a value: lowercase letters, digits and underscores"
      end
      raise Error, "value #{v.inspect} listed twice" if values.include?(v)

      values << v
    end
  end

  # The constants of a string field with listed values: the values listed, the
  # messages whose field of that name lists exactly them, and the message
  # naming them when the field's name alone would be ambiguous.
  ConstGroup = Struct.new(:field, :listed, :messages, :prefix, keyword_init: true) do
    # The constant for one of the values, as Ruby spells it: OP_ADD for op's
    # "add", FILTER_NODE_OP_AND with the prefix FilterNode.
    def const_name(value)
      [prefix && Proto.snake(prefix), field, value].compact.join("_").upcase
    end
  end

  def self.snake(camel) = camel.gsub(/([a-z\d])([A-Z])/, '\1_\2').gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').downcase

  # The fields of +messages+ with listed values, grouped, in the order of the
  # proto. Where fields of one name list different values in different
  # messages, the set listed in the most messages keeps the short name and the
  # others are named by their message too - OP_ADD for the topic updates,
  # FILTER_NODE_OP_AND for FilterNode - and a tie names all of them so.
  def self.const_groups(messages)
    by_field = {}
    messages.each do |m|
      m.fields.each do |f|
        values = begin
          listed_values(f)
        rescue Error => e
          raise Error, "#{m.name}.#{f.name}: #{e.message}"
        end
        next if values.nil?

        groups = (by_field[f.name] ||= [])
        g = groups.find { it.listed == values }
        groups << (g = ConstGroup.new(field: f.name, listed: values, messages: [])) if g.nil?
        g.messages << m.name
      end
    end
    by_field.flat_map do |name, groups|
      if groups.size > 1
        most = groups.max_by { it.messages.size }
        tie = groups.any? { it != most && it.messages.size == most.messages.size }
        groups.each do |g|
          next if g == most && !tie
          if g.messages.size > 1
            raise Error, "field #{name} lists #{g.listed.join(", ")} in #{g.messages.join(", ")} " \
                         "and other values elsewhere: cannot name its constants"
          end

          g.prefix = g.messages.first
        end
      end
      groups
    end
  end

  # A presence wrapper: a message with one field which Centrifugo reads by
  # whether it is there - BoolValue and Int32Value, whose field is value, and
  # one whose only field's empty value has a meaning, as the update messages
  # of device_update. It is sent whenever it is set, even empty.
  def self.presence_wrapper?(message)
    return false unless message&.fields&.size == 1

    f = message.fields.first
    (message.name.end_with?("Value") && f.name == "value") || empty_has_meaning?(f)
  end

  MESSAGE_OPEN = /\Amessage\s+(\w+)\s*\{\s*(\})?\z/
  FIELD = /\A(repeated\s+)?(\w+)\s+(\w+)\s*=\s*\d+\s*;\z/
  MAP_FIELD = /\Amap\s*<\s*(\w+)\s*,\s*(\w+)\s*>\s+(\w+)\s*=\s*\d+\s*;\z/
  RESERVED = /\Areserved\s+[\d\s,to]+;\z/
  SERVICE_OPEN = /\Aservice\s+\w+\s*\{\z/
  RPC = /\Arpc\s+(\w+)\s*\(\s*(stream\s+)?(\w+)\s*\)\s*returns\s*\(\s*(stream\s+)?(\w+)\s*\)\s*(?:\{\s*\}|;)\z/
  TOP_LEVEL_SKIP = /\A(syntax|package|option)\b.*;\z/

  module_function

  def parse(text, name)
    schema = Schema.new(messages: [], by_name: {}, methods: [])
    comment = []
    current = nil
    in_service = false
    text.each_line.with_index(1) do |raw, lineno|
      fail_at = ->(msg) { raise Error, "#{name}:#{lineno}: #{msg}" }
      line = raw.strip
      if line.empty?
        # A blank line ends a comment block: only a comment directly above a
        # declaration documents it.
        comment = []
        next
      end
      if line.start_with?("//")
        comment << line[2..].strip
        next
      end
      if (pos = line.index("//"))
        # A trailing comment documents its line when nothing above does.
        comment = [line[(pos + 2)..].strip] if comment.empty?
        line = line[0...pos].strip
      end

      if current.nil? && !in_service
        if line.match?(TOP_LEVEL_SKIP)
          # Nothing to generate.
        elsif (m = MESSAGE_OPEN.match(line))
          fail_at.call("message #{m[1]} declared twice") if schema.by_name.key?(m[1])
          msg = Message.new(name: m[1], doc: comment, fields: [])
          schema.messages << msg
          schema.by_name[m[1]] = msg
          current = msg unless m[2]
        elsif line.match?(SERVICE_OPEN)
          in_service = true
        else
          fail_at.call("unsupported top-level declaration: #{line}")
        end
      elsif in_service
        if line == "}"
          in_service = false
        elsif (m = RPC.match(line))
          schema.methods << Method.new(name: m[1], request: m[3], response: m[5], streaming: !(m[2] || m[4]).nil?)
        else
          fail_at.call("unsupported service declaration: #{line}")
        end
      elsif line == "}"
        current = nil
      elsif line.match?(RESERVED)
        # Nothing to generate.
      elsif (m = MAP_FIELD.match(line))
        current.fields << Field.new(name: m[3], type: m[2], repeated: false, map_key: m[1], doc: comment)
      elsif (m = FIELD.match(line))
        current.fields << Field.new(name: m[3], type: m[2], repeated: !m[1].nil?, map_key: "", doc: comment)
      else
        fail_at.call("unsupported declaration in message #{current.name}: #{line}")
      end
      comment = []
    end
    raise Error, "#{name}: unexpected end of file" if current || in_service

    check(schema, name)
    schema
  end

  # Every type a field or method refers to is declared.
  def check(schema, name)
    schema.messages.each do |m|
      m.fields.each do |f|
        unless SCALARS.include?(f.type) || schema.by_name.key?(f.type)
          raise Error, "#{name}: #{m.name}.#{f.name} has unknown type #{f.type}"
        end
        if f.map? && f.map_key != "string"
          raise Error,
                "#{name}: #{m.name}.#{f.name}: only string map keys are supported"
        end
      end
    end
    schema.methods.each do |rpc|
      unless schema.by_name.key?(rpc.request) && schema.by_name.key?(rpc.response)
        raise Error, "#{name}: rpc #{rpc.name} refers to an undeclared message"
      end
    end
  end
end
