# frozen_string_literal: true

require "test_helper"

# What a request carries and what fails before sending (spec 2, 3.3, 3.5): the
# fields the proto marks required, presence wrappers, empty messages.
class RequestsTest < Minitest::Test
  def setup
    @fake = Fake.new
    @client = @fake.client
  end

  PUSH = { recipient: { fcm_tokens: ["t"] }, notification: { fcm: { message: { "k" => "v" } }, expire_at: 1 } }.freeze

  # Found in api.proto's comments, and pinned here: a changed comment shows as
  # a failed test rather than as a field changing how it is sent or checked.
  def test_presence_wrappers_and_unchecked_required_fields_from_the_comments
    wrappers = APIProto::SCHEMA.messages.select { Proto.presence_wrapper?(it) }.map(&:name)

    assert_equal %w[BoolValue Int32Value DeviceUserUpdate DeviceTimezoneUpdate DeviceLocaleUpdate DeviceMetaUpdate],
                 wrappers
    unchecked = APIProto::SCHEMA.messages.flat_map do |m|
      m.fields.select { Proto.required?(it) && Proto.empty_has_meaning?(it) }.map { "#{m.name}.#{it.name}" }
    end

    assert_equal %w[InvalidateUserTokensRequest.user DeviceUserUpdate.user DeviceTimezoneUpdate.timezone
                    DeviceLocaleUpdate.locale DeviceMetaUpdate.meta UserTopicUpdateRequest.user], unchecked
  end

  def test_required_conditions_are_not_required
    expire_at = APIProto::SCHEMA.by_name["PushNotification"].fields.find { it.name == "expire_at" }

    assert_includes expire_at.doc.join(" "), "Required when"
    refute Proto.required?(expire_at)
    data = APIProto::SCHEMA.by_name["PublishRequest"].fields.find { it.name == "data" }

    refute Proto.required?(data)
  end

  def test_a_required_field_missing_or_empty_fails_before_sending
    [
      [:presence, { channel: nil }, "invalid presence request: channel is required"],
      [:presence, { channel: "" }, "invalid presence request: channel is required"],
      [:shared_poll_publish, { channel: "c", key: "k", version: 0 }, "version is required"],
      [:get_user_status, { users: [] }, "invalid get_user_status request: users is required"],
      [:send_push_notification, { recipient: PUSH[:recipient], notification: nil }, "notification is required"],
      # A message with nothing set is not sent: a missing one.
      [:send_push_notification, { recipient: PUSH[:recipient], notification: {} }, "notification is required"],
      [:send_push_notification, { recipient: {}, notification: PUSH[:notification] }, "recipient is required"],
      [:send_push_notification, { **PUSH, notification: { apns: { headers: { "a" => "b" }, payload: nil } } },
       "invalid send_push_notification request: notification.apns.payload is required"],
      [:send_push_notification,
       { **PUSH,
         limit_strategy: { rate_limit: { policies: [{ rate: 1, interval_ms: 9 }, { rate: 0, interval_ms: 9 }] } } },
       "invalid send_push_notification request: limit_strategy.rate_limit.policies[1].rate is required"],
      [:send_push_notification, { **PUSH, limit_strategy: { time_limit: { send_after_time: "09:00" } } },
       "limit_strategy.time_limit.send_before_time is required"],
      [:device_update, { users: ["u"], topics_update: { op: "", topics: ["t"] } },
       "invalid device_update request: topics_update.op is required"],
      # A Hash without a field its type requires, as its constructor refuses.
      [:device_update, { users: ["u"], topics_update: { topics: ["t"] } },
       "invalid device_update request: topics_update.op is required"]
    ].each do |m, args, message|
      err = assert_raises(Cent::InvalidRequestError, "#{m} #{args}") { @client.public_send(m, **args) }
      assert_includes err.message, message
      refute Cent.retryable?(err)
      assert_raises(Cent::InvalidRequestError, "#{m} #{args}") { Cent::Command.public_send(m, **args) }
      batch = @client.new_batch
      batch.public_send(m, **args)
      assert_raises(Cent::InvalidRequestError, "#{m} #{args}") { batch.send }
    end
    assert_empty @fake.requests
    assert_raises(ArgumentError) { Cent::DeviceTopicsUpdate.new(topics: ["t"]) }
    assert_raises(ArgumentError) { Cent::RateLimitPolicy.new(rate: 1) }
  end

  def test_an_optional_message_left_unset_is_not_checked
    @client.send_push_notification(**PUSH)
    @client.device_update(users: ["u"])

    assert_equal 2, @fake.requests.size
    refute @fake.bodies("send_push_notification").first.key?("limit_strategy")
  end

  def test_a_field_whose_empty_value_has_a_meaning_is_sent_empty
    @client.invalidate_user_tokens(user: "")
    @client.user_topic_update(user: "", op: Cent::OP_ADD, topics: ["news"])

    assert_equal [{}, { "op" => "add", "topics" => ["news"] }], @fake.requests.map(&:json)
  end

  def test_a_presence_wrapper_set_empty_is_sent_as_an_empty_object
    @client.device_update(users: ["u"], user_update: { user: "" },
                          timezone_update: Cent::DeviceTimezoneUpdate.new(timezone: ""),
                          locale_update: { locale: "" }, meta_update: { meta: {} })
    @client.device_update(users: ["u"], timezone_update: { timezone: "Europe/Berlin" })
    @client.device_update(users: ["u"], user_update: nil)
    a, b, c = @fake.bodies("device_update")

    cleared = { "user_update" => {}, "timezone_update" => {}, "locale_update" => {}, "meta_update" => {} }

    assert_equal({ "users" => ["u"], **cleared }, a)
    assert_equal({ "users" => ["u"], "timezone_update" => { "timezone" => "Europe/Berlin" } }, b)
    assert_equal({ "users" => ["u"] }, c)
    cmd = Cent::Command.device_update(users: ["u"], meta_update: { meta: {} })

    assert_equal({ "users" => ["u"], "meta_update" => {} }, JSON.parse(cmd.payload))
  end

  def test_any_other_message_set_empty_is_not_sent
    @client.send_push_notification(**PUSH, limit_strategy: {})
    @client.send_push_notification(**PUSH, limit_strategy: Cent::PushLimitStrategy.new(rate_limit: {}))
    @client.history(channel: "c", since: Cent::StreamPosition.new)
    @client.device_update(users: ["u"], topics_update: nil)

    a, b = @fake.bodies("send_push_notification")

    refute a.key?("limit_strategy")
    refute b.key?("limit_strategy")
    assert_equal({ "channel" => "c" }, @fake.bodies("history").first)
    assert_equal({ "users" => ["u"] }, @fake.bodies("device_update").first)
  end
end
