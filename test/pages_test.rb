# frozen_string_literal: true

require "test_helper"

# The <method>_all iterators and stream positions (spec 3.8).
class PagesTest < Minitest::Test
  def setup
    @fake = Fake.new
    @client = @fake.client
  end

  # A fake channel history of n publications, offsets 1..n, read forward from
  # since a page of limit at a time.
  def serve_history(n, epoch: "e")
    @fake.on("history") do |_m, body|
      from = body.dig("since", "offset") || 0
      pubs = ((from + 1)..n).first(body["limit"]).map { { "data" => it, "offset" => it } }
      { "publications" => pubs, "offset" => n, "epoch" => epoch }
    end
  end

  # A fake paged by a cursor: items 1..n, a page of size at a time, the
  # cursor the index of the next item. +fail_at+ fails the page starting at it.
  def serve_cursor(method, n, size, items: "items", cursor: "next_cursor", fail_at: nil, extra: {})
    @fake.on(method) do |_m, body|
      from = (body["cursor"] || "0").to_i
      next Cent::ApiError.for_code(100, "internal error", temporary: true) if from == fail_at

      page = ((from + 1)..n).first(size)
      following = from + size < n ? (from + size).to_s : ""
      { items => page.map { yield it }, cursor => following, **extra }
    end
  end

  def test_history_all_over_any_number_of_pages
    [[0, 3, 1], [1, 3, 1], [3, 3, 2], [7, 3, 3], [9, 3, 4]].each do |n, limit, requests|
      @fake = Fake.new
      @client = @fake.client
      serve_history(n)
      got = @client.history_all(channel: "c", limit:).map(&:data)

      assert_equal (1..n).to_a, got, "n=#{n}"
      bodies = @fake.bodies("history")

      assert_equal requests, bodies.size, "n=#{n}: a full last page costs one more request"
      assert_equal({ "channel" => "c", "limit" => limit }, bodies.first)
      bodies.drop(1).each_with_index do |b, i|
        assert_equal({ "offset" => (i + 1) * limit, "epoch" => "e" }, b["since"])
      end
    end
  end

  def test_history_all_from_since_and_with_a_block
    serve_history(5)
    got = []

    assert_nil(@client.history_all(channel: "c", limit: 2, since: { offset: 1, epoch: "e" }) { got << it.offset })
    assert_equal [2, 3, 4, 5], got
    assert_equal([1, 3, 5].map { { "offset" => it, "epoch" => "e" } }, @fake.bodies("history").map { it["since"] })
  end

  def test_history_all_refuses_before_sending
    serve_history(5)
    [{ limit: nil }, { limit: 0 }, { limit: -1 }, { limit: 2, reverse: true }].each do |args|
      err = assert_raises(Cent::InvalidRequestError) { @client.history_all(channel: "c", **args) }
      assert_match(/\Ainvalid history request: history_all/, err.message)
      assert_raises(Cent::InvalidRequestError) { @client.history_all(channel: "c", **args) { flunk } }
    end
    assert_raises(Cent::InvalidRequestError) { @client.history_all(channel: "", limit: 1) }
    assert_raises(ArgumentError) { @client.history_all(limit: 1) }
    assert_empty @fake.requests
  end

  def test_a_page_is_read_when_reached
    serve_history(10)
    enum = @client.history_all(channel: "c", limit: 2)

    assert_empty @fake.requests
    assert_equal [1, 2, 3], enum.first(3).map(&:offset)
    assert_equal 2, @fake.requests.size
    @fake.requests.clear
    @client.history_all(channel: "c", limit: 2) { break if it.offset == 2 }

    assert_equal 1, @fake.requests.size
    assert_equal [1, 2, 3, 4, 5], @client.history_all(channel: "c", limit: 2).lazy.map(&:offset).first(5)
  end

  def test_cursor_methods_over_any_number_of_pages
    [
      [:device_list_all, "device_list", ->(i) { { "id" => i.to_s } }, :id],
      [:device_topic_list_all, "device_topic_list", ->(i) { { "id" => i.to_s } }, :id],
      [:user_topic_list_all, "user_topic_list", ->(i) { { "id" => i.to_s } }, :id]
    ].each do |iter, method, item, read|
      [[0, 3, 1], [1, 3, 1], [3, 3, 1], [7, 3, 3]].each do |n, size, requests|
        @fake = Fake.new
        @client = @fake.client
        serve_cursor(method, n, size, &item)
        got = @client.public_send(iter, limit: size, **(method == "device_list" ? { include_meta: true } : {}))
                     .map { it.public_send(read) }

        assert_equal (1..n).map(&:to_s), got, "#{iter} n=#{n}"
        bodies = @fake.bodies(method)

        assert_equal requests, bodies.size, "#{iter} n=#{n}"
        assert_nil bodies.first["cursor"]
        bodies.drop(1).each_with_index { |b, i| assert_equal(((i + 1) * size).to_s, b["cursor"]) }
        assert(bodies.all? { it["limit"] == size })
      end
    end
  end

  def test_an_error_ends_the_iteration_after_the_items_before_it
    serve_cursor("device_list", 9, 3, fail_at: 6) { { "id" => it.to_s } }
    got = []
    err = assert_raises(Cent::InternalError) { @client.device_list_all { got << it.id } }

    assert_predicate err, :temporary?
    assert_equal %w[1 2 3 4 5 6], got
    enum = @client.device_list_all

    assert_equal(%w[1 2 3 4 5 6], 6.times.map { enum.next.id })
    assert_raises(Cent::InternalError) { enum.next }
  end

  def test_map_read_state_all_reads_later_pages_at_the_first_ones_revision
    serve_cursor("map_read_state", 5, 2, items: "entries", cursor: "cursor",
                                         extra: { "offset" => 42, "epoch" => "e1" }) { { "key" => "k#{it}" } }
    got = @client.map_read_state_all(channel: "m", limit: 2).map(&:key)

    assert_equal %w[k1 k2 k3 k4 k5], got
    first, *later = @fake.bodies("map_read_state")

    assert_equal({ "channel" => "m", "limit" => 2 }, first)
    assert_equal 2, later.size
    later.each do |b|
      assert_equal 42, b["revision_offset"]
      assert_equal "e1", b["revision_epoch"]
    end
    @fake.requests.clear
    @client.map_read_state_all(channel: "m", limit: 2, revision_offset: 7, revision_epoch: "e0").to_a

    assert(@fake.bodies("map_read_state").all? { it["revision_offset"] == 7 && it["revision_epoch"] == "e0" })
  end

  def test_positions
    @fake.on("history", { "publications" => [], "offset" => 9, "epoch" => "h" })
    @fake.on("map_read_state", { "offset" => 3, "epoch" => "s" })
    @fake.on("map_read_stream", { "offset" => 4, "epoch" => "r" })
    pos = @client.publish(channel: "c", data: 1).position

    assert_equal Cent::StreamPosition.new(offset: 1, epoch: "e1"), pos
    assert_equal Cent::StreamPosition.new(offset: 9, epoch: "h"), @client.history(channel: "c").position
    assert_equal Cent::StreamPosition.new(offset: 3, epoch: "s"), @client.map_read_state(channel: "m").position
    assert_equal Cent::StreamPosition.new(offset: 4, epoch: "r"), @client.map_read_stream(channel: "m").position
    # What a publish returned is what the next history call reads from.
    @client.history(channel: "c", since: pos, limit: 10)

    assert_equal({ "offset" => 1, "epoch" => "e1" }, @fake.bodies("history").last["since"])
  end
end
