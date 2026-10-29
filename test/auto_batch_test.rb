# frozen_string_literal: true

require "test_helper"

class AutoBatchTest < Minitest::Test
  # A fake whose requests wait for the test to let them go.
  class Gated < Fake
    attr_reader :gate

    def initialize
      super
      @gate = Queue.new
    end

    def call(...)
      out = super
      @gate.pop
      out
    end
  end

  def setup
    @fake = Gated.new
  end

  def wait_for(n)
    deadline = Cent::HTTP.now + 5
    sleep 0.005 until @fake.requests.size >= n || Cent::HTTP.now > deadline

    assert_operator @fake.requests.size, :>=, n
  end

  def test_config
    assert_raises(Cent::InvalidConfigError) { Cent::AutoBatch.new(max_in_flight: 0) }
    assert_raises(Cent::InvalidConfigError) { Cent::AutoBatch.new(max_in_flight: 1, max_batch_size: 1) }
    assert_equal 1000, Cent::AutoBatch.new(max_in_flight: 1).max_batch_size
    assert_raises(Cent::InvalidConfigError) { @fake.client(auto_batch: { max_in_flight: 1 }) }
  end

  def test_below_the_cap_calls_go_alone
    client = @fake.client(auto_batch: Cent::AutoBatch.new(max_in_flight: 2))
    calls = Array.new(2) { |i| Thread.new { client.publish(channel: "c#{i}", data: i) } }
    wait_for(2)
    2.times { @fake.gate << true }
    calls.each(&:join)

    assert_equal %w[publish publish], @fake.requests.map(&:method_name)
  end

  def test_at_the_cap_calls_batch
    infos = []
    client = @fake.client(auto_batch: Cent::AutoBatch.new(max_in_flight: 1, max_batch_size: 3),
                          on_request: ->(i) { infos << i })
    first = Thread.new { client.publish(channel: "first", data: 0) }
    wait_for(1)
    queued = Array.new(4) { |i| Thread.new { client.publish(channel: "q#{i}", data: i) } }
    sleep 0.05 # the calls queue
    @fake.gate << true
    first.join
    wait_for(2)
    @fake.gate << true # the batch of 3
    wait_for(3)
    @fake.gate << true # the batch of the last one
    queued.each { assert_equal 1, it.value.offset }
    batches = @fake.bodies("batch")

    assert_equal([3, 1], batches.map { it["commands"].size })
    assert(batches.all? { it["parallel"] })
    assert_equal %w[q0 q1 q2 q3].sort, batches.flat_map { |b| b["commands"].map { it["publish"]["channel"] } }.sort
    assert_equal [false, true, true], infos.map(&:auto_batch)
  end

  def test_each_call_gets_its_own_reply
    @fake.on("publish") { |_m, body| body["channel"] == "bad" ? Cent::ApiError.new(102, "unknown") : { "offset" => 9 } }
    client = @fake.client(auto_batch: Cent::AutoBatch.new(max_in_flight: 1))
    first = Thread.new { client.info }
    wait_for(1)
    good = Thread.new { client.publish(channel: "good", data: 1) }
    bad = Thread.new { client.publish(channel: "bad", data: 1) }
    sleep 0.05
    2.times { @fake.gate << true }
    first.join

    assert_equal 9, good.value.offset
    assert_raises(Cent::UnknownChannelError) { bad.value }
  end

  def test_batch_failing_as_a_whole_fails_its_calls_each_with_its_own_error
    @fake.on("batch", [503, {}, ""])
    client = @fake.client(auto_batch: Cent::AutoBatch.new(max_in_flight: 1))
    first = Thread.new { client.info }
    wait_for(1)
    queued = Array.new(3) { Thread.new { client.info } }
    sleep 0.05
    2.times { @fake.gate << true }
    first.join
    errors = queued.map do |t|
      t.join
    rescue Cent::HTTPError => e
      e
    end

    assert(errors.all? { it.is_a?(Cent::HTTPError) && it.status_code == 503 })
    assert_equal 3, errors.map(&:object_id).uniq.size
  end

  def test_queued_call_timing_out_is_not_sent
    client = @fake.client(auto_batch: Cent::AutoBatch.new(max_in_flight: 1))
    first = Thread.new { client.info }
    wait_for(1)
    err = assert_raises(Cent::TimeoutError) { client.publish(channel: "late", data: 1, timeout: 0.05) }
    assert_match(/timed out before it was sent/, err.message)
    @fake.gate << true
    first.join
    sleep 0.05

    assert_equal ["info"], @fake.requests.map(&:method_name)
  end

  def test_invalid_call_is_refused_before_it_queues
    client = @fake.client(auto_batch: Cent::AutoBatch.new(max_in_flight: 1))
    first = Thread.new { client.info }
    wait_for(1)
    assert_raises(Cent::InvalidRequestError) { client.publish(channel: "c", data: Float::NAN) }
    @fake.gate << true
    first.join
  end

  def test_close_waits_for_batches
    client = @fake.client(auto_batch: Cent::AutoBatch.new(max_in_flight: 1))
    first = Thread.new { client.info }
    wait_for(1)
    queued = Thread.new { client.info }
    sleep 0.05
    @fake.gate << true
    first.join
    wait_for(2) # the batch is in flight
    closing = Thread.new { client.close(timeout: 5) }
    sleep 0.05

    assert_predicate closing, :alive?
    @fake.gate << true
    closing.join
    queued.join
  end

  def test_batch_runs_with_an_empty_fiber_storage_and_batch_context_gets_the_callers
    seen = nil
    storages = nil
    @fake.on("batch") do |_m, body|
      seen = Fiber[:request_id]
      [200, {}, JSON.generate({ "replies" => body["commands"].map { { "info" => {} } } })]
    end
    ctx = lambda do |callers, &send|
      storages = callers
      send.call
    end
    client = @fake.client(auto_batch: Cent::AutoBatch.new(max_in_flight: 1), batch_context: ctx)
    Fiber[:request_id] = "first"
    first = Thread.new { client.info }
    wait_for(1)
    queued = Array.new(2) do |i|
      Thread.new do
        Fiber[:request_id] = "q#{i}"
        client.info
      end
    end
    sleep 0.05
    2.times { @fake.gate << true }
    [first, *queued].each(&:join)

    assert_nil seen
    assert_equal %w[q0 q1], storages.map { it[:request_id] }.sort
  end

  def test_batch_context_which_does_not_send_fails_the_batch_not_the_batcher
    ctx = ->(_callers) {} # never calls its block
    client = @fake.client(auto_batch: Cent::AutoBatch.new(max_in_flight: 1), batch_context: ctx)
    queue = client.instance_variable_get(:@batcher).instance_variable_get(:@queue)
    2.times do |round|
      first = Thread.new { client.info(timeout: 2) }
      wait_for(round + 1)
      queued = Array.new(2) { Thread.new { client.info(timeout: 2) } }
      deadline = Cent::HTTP.now + 5
      Thread.pass until queue.size == 2 || Cent::HTTP.now > deadline
      @fake.gate << true
      first.join
      queued.each do |t|
        e = assert_raises(Cent::InvalidConfigError) { t.value }
        assert_includes e.message, "batch_context must call its block"
      end
    end
  end

  def test_batches_are_sent_by_kept_threads_which_close_stops
    @fake = Fake.new
    @fake.on("info") do
      sleep 0.001
      {}
    end
    @fake.on("batch") do |_m, body|
      sleep 0.001
      [200, {}, JSON.generate({ "replies" => body["commands"].map { { "info" => {} } } })]
    end
    client = @fake.client(auto_batch: Cent::AutoBatch.new(max_in_flight: 2))
    before = Thread.list.size
    peak = before
    sampler = Thread.new do
      loop do
        peak = [peak, Thread.list.size].max
        sleep 0.001
      end
    end
    Array.new(12) { Thread.new { 30.times { client.info } } }.each(&:join)
    sampler.kill

    refute_empty @fake.bodies("batch")
    # The 12 callers and the sampler, and at most one sender per slot.
    assert_operator peak - before, :<=, 12 + 1 + 2
    client.close(timeout: 5)
    sleep 0.01 until Thread.list.size <= before
  end

  def test_idle_senders_end
    Cent::AutoBatch::Batcher.worker_idle = 0.05
    client = @fake.client(auto_batch: Cent::AutoBatch.new(max_in_flight: 1))
    before = Thread.list
    first = Thread.new { client.info }
    wait_for(1)
    queued = Thread.new { client.info }
    sleep 0.05
    2.times { @fake.gate << true }
    [first, queued].each(&:join)
    deadline = Cent::HTTP.now + 5
    sleep 0.01 until (Thread.list - before).empty? || Cent::HTTP.now > deadline

    assert_empty Thread.list - before # the sender ended idle, the client open
    assert_equal 1, @fake.bodies("batch").size
  ensure
    Cent::AutoBatch::Batcher.worker_idle = nil
  end

  def test_stress
    @fake = Fake.new
    @fake.on("publish") do |_m, body|
      sleep rand * 0.002
      { "offset" => body["data"] }
    end
    @fake.on("batch") do |_m, body|
      sleep rand * 0.002
      replies = body["commands"].map { |c| { "publish" => { "offset" => c["publish"]["data"] } } }
      [200, {}, JSON.generate({ "replies" => replies })]
    end
    client = @fake.client(auto_batch: Cent::AutoBatch.new(max_in_flight: 3, max_batch_size: 5))
    threads = Array.new(16) do |t|
      Thread.new do
        Array.new(50) do |i|
          n = (t * 1000) + i

          assert_equal n, client.publish(channel: "c", data: n).offset
        end
      end
    end
    threads.each(&:join)
    batches = @fake.bodies("batch")

    refute_empty batches
    assert(batches.all? { it["commands"].size <= 5 })
    sent = @fake.bodies("publish").size + batches.sum { it["commands"].size }

    assert_equal 800, sent
    client.close(timeout: 5)
  end
end
