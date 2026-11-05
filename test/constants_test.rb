# frozen_string_literal: true

require "test_helper"

# The constants generated from the protos' "One of:" sentences (spec 3.3).
class ConstantsTest < Minitest::Test
  P = Cent::Proxy

  def parse(text) = Proto.parse(text, "test.proto")

  def field(doc) = Proto::Field.new(name: "f", type: "string", repeated: false, map_key: "", doc: [doc])

  def test_the_sentence_is_parsed
    assert_equal %w[add remove set],
                 Proto.listed_values(field("op is the operation. Required. One of: add, remove, set."))
    assert_equal %w[if_new if_exists], Proto.listed_values(field("Empty always writes. One of: if_new, if_exists."))
    assert_nil Proto.listed_values(field("op is the operation: add, remove or set."))
    [
      ["One of: add, remove", "must end with a period"],
      ["One of: add, Remove.", '"Remove" is not a value'],
      ["One of: add or remove.", '"add or remove" is not a value'],
      ["One of: add, , set.", '"" is not a value'],
      ["One of: add, add.", 'value "add" listed twice']
    ].each do |doc, message|
      assert_includes assert_raises(Proto::Error) { Proto.listed_values(field(doc)) }.message, message
    end
  end

  def pins(name) = Proto.parse_pins(File.read(File.expand_path("../gen/#{name}", __dir__)), name)

  def proxy_schema = Proto.parse(File.read(File.expand_path("../proto/proxy.proto", __dir__)), "proxy.proto")

  # The names are the spec's table of 3.3, the same field in both protos named
  # alike.
  def test_the_pinned_names
    assert_equal %w[FilterNodeOp Cmp Provider Platform Op Status KeyMode], pins("constants_api.txt").map(&:last).uniq
    assert_equal %w[FilterNodeOp Cmp Protocol Encoding Allow CapabilityMatch KeyMode ChannelEventType],
                 pins("constants_proxy.txt").map(&:last)
    names = ->(schema, file) { Proto.const_groups(schema.messages, pins(file)).map(&:name) }

    assert_equal %w[FilterNodeOp Cmp Provider Platform Op Status KeyMode],
                 names.call(APIProto::SCHEMA, "constants_api.txt")
    assert_equal %w[FilterNodeOp Cmp Protocol Encoding Allow CapabilityMatch KeyMode ChannelEventType],
                 names.call(proxy_schema, "constants_proxy.txt")
  end

  def test_a_field_the_pins_lack_a_pin_unused_and_a_name_over_different_values_fail
    s = parse(<<~PROTO)
      message A {
        // One of: add, remove.
        string op = 1;
      }
      message B {
        // One of: and, or.
        string op = 1;
      }
    PROTO
    groups = Proto.const_groups(s.messages, [["A.op", "Op"], ["B.op", "FilterNodeOp"]])

    assert_equal(%w[OP_ADD OP_REMOVE FILTER_NODE_OP_AND FILTER_NODE_OP_OR],
                 groups.flat_map { |g| g.listed.map { g.const_name(it) } })
    assert_equal [%w[A.op], %w[B.op]], groups.map(&:fields)
    [
      [[["A.op", "Op"]], "B.op lists its values, but no pin names its constants"],
      [[["*.op", "Op"]], "Op names add, remove in A.op but and, or in B.op"],
      [[["A.op", "Op"], ["B.op", "FilterNodeOp"], ["C.op", "Other"]], "no field uses the pin C.op Other"]
    ].each do |pins, message|
      assert_includes assert_raises(Proto::Error) { Proto.const_groups(s.messages, pins) }.message, message
    end
    assert_raises(Proto::Error) { Proto.parse_pins("A.op op\n", "x") }
    assert_equal [["*.op", "Op"]], Proto.parse_pins("# a comment\n\n*.op Op\n", "x")
  end

  def test_each_constant_is_its_value
    { Cent::PROVIDER_FCM => "fcm", Cent::PROVIDER_WEBPUSH => "webpush", Cent::PLATFORM_IOS => "ios",
      Cent::OP_ADD => "add", Cent::OP_SET => "set", Cent::STATUS_DELIVERED => "delivered",
      Cent::KEY_MODE_IF_NEW => "if_new", Cent::FILTER_NODE_OP_AND => "and", Cent::CMP_LTE => "lte",
      P::FILTER_NODE_OP_AND => "and", P::ENCODING_BINARY => "binary", P::PROTOCOL_PROTOBUF => "protobuf",
      P::ALLOW_PRS => "prs", P::CAPABILITY_MATCH_REGEX => "regex", P::KEY_MODE_IF_EXISTS => "if_exists",
      P::CHANNEL_EVENT_TYPE_VACATED => "vacated", P::CMP_EQ => "eq" }.each do |const, value|
      assert_equal value, const
    end
    # Every listed value has its constant, by the naming rule.
    [[APIProto::SCHEMA, Cent, "constants_api.txt"], [proxy_schema, Cent::Proxy, "constants_proxy.txt"]]
      .each do |schema, mod, file|
      Proto.const_groups(schema.messages, pins(file)).each do |g|
        g.listed.each { assert_equal it, mod.const_get(g.const_name(it), false) }
      end
    end
  end

  def test_a_value_without_a_constant_is_still_sent
    fake = Fake.new
    fake.client.device_register(provider: "future", platform: Cent::PLATFORM_WEB, token: "t")

    assert_equal({ "provider" => "future", "platform" => "web", "token" => "t" }, fake.bodies.first)
  end
end
