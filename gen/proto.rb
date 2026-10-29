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
