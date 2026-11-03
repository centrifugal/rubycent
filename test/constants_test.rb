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

  def test_names_and_the_collision_rule
    s = parse(<<~PROTO)
      message A {
        // One of: add, remove.
        string op = 1;
        // One of: if_new, if_exists.
        string key_mode = 2;
      }
      message B {
        // One of: add, remove.
        string op = 1;
      }
      message FilterNode {
        // One of: and, or.
        string op = 1;
      }
    PROTO
    names = Proto.const_groups(s.messages).flat_map { |g| g.listed.map { g.const_name(it) } }

    assert_equal %w[OP_ADD OP_REMOVE FILTER_NODE_OP_AND FILTER_NODE_OP_OR KEY_MODE_IF_NEW KEY_MODE_IF_EXISTS], names
  end

  def test_a_tie_names_every_set_by_its_message
    s = parse(<<~PROTO)
      message DeviceUpdate {
        // One of: add, remove.
        string op = 1;
      }
      message FilterNode {
        // One of: and, or.
        string op = 1;
      }
    PROTO
    names = Proto.const_groups(s.messages).flat_map { |g| g.listed.map { g.const_name(it) } }

    assert_equal %w[DEVICE_UPDATE_OP_ADD DEVICE_UPDATE_OP_REMOVE FILTER_NODE_OP_AND FILTER_NODE_OP_OR], names
  end

  def test_a_set_shared_by_messages_cannot_lose_a_tie
    s = parse(<<~PROTO)
      message A {
        // One of: add.
        string op = 1;
      }
      message B {
        // One of: add.
        string op = 1;
      }
      message C {
        // One of: and.
        string op = 1;
      }
      message D {
        // One of: and.
        string op = 1;
      }
    PROTO
    assert_raises(Proto::Error) { Proto.const_groups(s.messages) }
  end

  def test_each_constant_is_its_value
    { Cent::PROVIDER_FCM => "fcm", Cent::PROVIDER_WEBPUSH => "webpush", Cent::PLATFORM_IOS => "ios",
      Cent::OP_ADD => "add", Cent::OP_SET => "set", Cent::STATUS_DELIVERED => "delivered",
      Cent::KEY_MODE_IF_NEW => "if_new", Cent::FILTER_NODE_OP_AND => "and", Cent::CMP_LTE => "lte",
      P::OP_AND => "and", P::ENCODING_BINARY => "binary", P::PROTOCOL_PROTOBUF => "protobuf", P::ALLOW_PRS => "prs",
      P::MATCH_REGEX => "regex", P::KEY_MODE_IF_EXISTS => "if_exists", P::TYPE_VACATED => "vacated",
      P::CMP_EQ => "eq" }.each do |const, value|
      assert_equal value, const
    end
    # Every listed value has its constant, by the naming rule.
    proxy = Proto.parse(File.read(File.expand_path("../proto/proxy.proto", __dir__)), "proxy.proto")
    [[APIProto::SCHEMA, Cent], [proxy, Cent::Proxy]].each do |schema, mod|
      Proto.const_groups(schema.messages).each do |g|
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
