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

  # The constants of a pinned name: the name, as the spec's table of 3.3 gives
  # it (FilterNodeOp), the values listed, and the messages and fields listing
  # them.
  ConstGroup = Struct.new(:name, :listed, :fields, keyword_init: true) do
    # The constant for one of the values, as Ruby spells it: OP_ADD for Op's
    # "add", FILTER_NODE_OP_AND for FilterNodeOp's "and".
    def const_name(value) = "#{Proto.snake(name)}_#{value}".upcase
  end

  def self.snake(camel) = camel.gsub(/([a-z\d])([A-Z])/, '\1_\2').gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').downcase

  # The pins of a constants list: "Message.field Name" or "*.field Name" a
  # line, # comments and blank lines skipped, as [selector, name] pairs.
  def self.parse_pins(text, where)
    text.each_line.with_index(1).filter_map do |line, n|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      m = line.match(/\A((?:\w+|\*)\.\w+)\s+([A-Z][A-Za-z0-9]*)\z/)
      raise Error, "#{where}:#{n}: not a pin, Message.field Name: #{line}" unless m

      [m[1], m[2]]
    end
  end

  # The fields of +messages+ with listed values, by the names +pins+ give
  # them, in the order of the proto. It fails on a field with a "One of:"
  # sentence no pin names, a pin no field uses, and one name over different
  # values: the names never change because an unrelated message appeared.
  def self.const_groups(messages, pins)
    used = Set.new
    groups = {}
    messages.each do |m|
      m.fields.each do |f|
        values = begin
          listed_values(f)
        rescue Error => e
          raise Error, "#{m.name}.#{f.name}: #{e.message}"
        end
        next if values.nil?

        pin = pins.find { |sel, _| sel == "#{m.name}.#{f.name}" } || pins.find { |sel, _| sel == "*.#{f.name}" }
        raise Error, "#{m.name}.#{f.name} lists its values, but no pin names its constants" if pin.nil?

        used << pin
        g = (groups[pin[1]] ||= ConstGroup.new(name: pin[1], listed: values, fields: []))
        if g.listed != values
          raise Error, "#{pin[1]} names #{g.listed.join(", ")} in #{g.fields.join(", ")} " \
                       "but #{values.join(", ")} in #{m.name}.#{f.name}"
        end
        g.fields << "#{m.name}.#{f.name}"
      end
    end
    unused = pins - used.to_a
    raise Error, "no field uses the pin #{unused.map { it.join(" ") }.join(", ")}" unless unused.empty?

    groups.values
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
