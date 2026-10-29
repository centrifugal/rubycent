# frozen_string_literal: true

module Cent
  # Lets a client send concurrent calls together, as one batch request, once
  # enough of them are in flight:
  #
  #   client = Cent::Client.new(api_endpoint:, api_key:, auto_batch: Cent::AutoBatch.new(max_in_flight: 8))
  #
  # Nothing waits for a batch to fill. While fewer than max_in_flight requests
  # are in flight, every call is sent at once, alone, exactly as without
  # AutoBatch. Only a call made when max_in_flight requests are already in
  # flight waits - for one of them to finish, not for a timer. Then all the
  # calls waiting at that moment go out together, at most max_batch_size of
  # them. The busier the client - Puma threads, Sidekiq workers, fibers sharing
  # it - the larger the batches, and the fewer requests Centrifugo handles for
  # the same work.
  #
  # Every call gets its own command's reply. Calls made one after another keep
  # their order: a call waits for its reply, so the next one joins a later
  # batch. Calls sharing a batch were made concurrently, with no order between
  # them, and Centrifugo runs them in parallel.
  #
  # Calls sharing a batch share its request, though: when it fails as a whole -
  # the network, the credentials, a body too large for a proxy in front of
  # Centrifugo (nginx refuses bodies over 1 MB by default) - every call in it
  # fails with that error. Each call keeps its own timeout: the batch lasts
  # until the latest of its calls'.
  #
  # It is for processes which publish a lot at once - a Sidekiq process at
  # concurrency 10 or more, an app on Falcon - and does nothing for a Puma web
  # process of a few threads. Set max_in_flight to about half the threads or
  # fibers which call the client at once: above that, it never batches; just
  # below, it batches calls one at a time, and only limits them.
  #
  # @!attribute [r] max_in_flight
  #   @return [Integer] how many requests may be in flight before calls start
  #     to wait and be batched
  # @!attribute [r] max_batch_size
  #   @return [Integer] the most calls one batch carries, 1000 by default
  class AutoBatch < Data.define(:max_in_flight, :max_batch_size)
    # @raise [InvalidConfigError]
    def initialize(max_in_flight:, max_batch_size: 1000)
      unless max_in_flight.is_a?(Integer) && max_in_flight >= 1
        raise InvalidConfigError, "AutoBatch max_in_flight must be 1 or more; leave auto_batch unset to disable it"
      end
      unless max_batch_size.is_a?(Integer) && max_batch_size >= 2
        raise InvalidConfigError, "AutoBatch max_batch_size must be 2 or more: a batch of 1 never batches"
      end

      super
    end

    # A call waiting to be sent in a batch. Until done, its fields belong to
    # the batcher; afterwards, to the caller.
    #
    # @api private
    class Queued
      attr_accessor :reply, :error, :taken, :gone, :index
      attr_reader :command, :deadline, :done, :storage

      def initialize(command, deadline)
        # Encoded before it queued: the batch never reads the caller's request.
        @command = command
        @deadline = deadline
        @done = Thread::Queue.new
        @reply = {}
        @error = nil
        # taken once in a batch; gone once its caller gave up before that.
        @taken = false
        @gone = false
        # Its place in the batch which carried it, for error messages.
        @index = 0
        # The caller's fiber storage, for batch_context.
        @storage = Fiber.current.storage
      end
    end

    # AutoBatch for a Client.
    #
    # @api private
    class Batcher
      # Seconds a thread sending batches waits for the next before it ends.
      WORKER_IDLE = 10.0

      class << self
        # WORKER_IDLE, unless the tests set another.
        #
        # @api private
        attr_writer :worker_idle

        # @api private
        def worker_idle = @worker_idle || WORKER_IDLE
      end

      def initialize(client, opts, batch_context)
        @client = client
        @batch_context = batch_context
        @max_in_flight = opts.max_in_flight
        @max_batch = opts.max_batch_size
        @lock = Mutex.new
        @in_flight = 0
        @queue = []
        # The threads sending batches, started as needed and kept while busy:
        # at most one per slot, since a batch holds one, each ending after
        # WORKER_IDLE seconds without a batch. Starting a thread per batch cost
        # more than a small batch saved.
        @jobs = Thread::Queue.new
        @workers = 0
        @idle = 0
      end

      # Stops the threads sending batches, once those in progress are sent.
      def close
        n = @lock.synchronize { @workers }
        n.times { @jobs << :stop }
      end

      # [true, what alone returned] when a slot was free and the call went
      # alone; [false, [its place in the batch, its command's reply]] when it
      # went in a batch.
      def call(method, wire, deadline, alone)
        command = nil
        q = nil
        @lock.lock
        begin
          loop do
            drop_gone
            if @in_flight < @max_in_flight && @queue.empty?
              @in_flight += 1
              break
            end
            if command
              q = Queued.new(command, deadline)
              @queue << q
              break
            end
            # The call will queue: encode its command first, outside the lock,
            # then look again - a slot may have freed meanwhile, and a call must
            # never queue while one is free.
            @lock.unlock
            begin
              command = "{\"#{method}\":#{Client.encode(wire)}}"
            ensure
              @lock.lock
            end
          end
        ensure
          @lock.unlock
        end
        if q.nil?
          begin
            return [true, alone.call]
          ensure
            release
          end
        end
        [false, wait(q, method, deadline)]
      end

      private

      def wait(q, method, deadline)
        if q.done.pop(timeout: [deadline - HTTP.now, 0].max).nil?
          taken = @lock.synchronize do
            q.gone = true unless q.taken
            q.taken
          end
          # The reply may have come as the deadline ended: it is the call's
          # outcome.
          if q.done.empty?
            raise TimeoutError, "#{method}: timed out" if taken

            raise TimeoutError, "#{method}: timed out before it was sent"
          end
        end
        # A copy for each caller: raised in each caller's thread, one shared
        # error would gather all their backtraces.
        raise q.error.dup if q.error

        [q.index, q.reply]
      end

      def drop_gone
        @queue.shift while @queue.first&.gone
      end

      # Hands the slot of a finished request to the calls waiting, if any, and
      # frees it otherwise.
      def release
        items = @lock.synchronize do
          drop_gone
          if @queue.empty?
            @in_flight -= 1
            next nil
          end
          take
        end
        return if items.nil?

        # Sent from a thread of the batcher's, so that no caller's thread does
        # work for others. Counted as a call: close waits for it.
        @client.calls.add
        dispatch(items)
      end

      def dispatch(items)
        start = @lock.synchronize do
          # Pushed under the lock which a sender ending idle takes: it sees
          # the batch, and stays for it.
          @jobs << items
          next false unless @idle.zero? && @workers < @max_in_flight

          @workers += 1
          @idle += 1
        end
        Thread.new { work } if start
      end

      def work
        loop do
          items = @jobs.pop(timeout: self.class.worker_idle)
          if items.nil?
            done = @lock.synchronize do
              next false unless @jobs.empty?

              @workers -= 1
              @idle -= 1
              true
            end
            break if done

            next
          end
          if items == :stop
            @lock.synchronize do
              @workers -= 1
              @idle -= 1
            end
            break
          end
          @lock.synchronize { @idle -= 1 }
          # With an empty fiber storage: a batch is no one caller's.
          Fiber.new(storage: {}) { flush(items) }.resume
          @lock.synchronize { @idle += 1 }
        end
      end

      # Takes up to max_batch calls off the head of the queue, skipping those
      # gone.
      def take
        items = []
        until items.size >= @max_batch || @queue.empty?
          q = @queue.shift
          next if q.gone

          q.taken = true
          q.index = items.size
          items << q
        end
        items
      end

      def flush(items)
        send_items(items) unless items.empty?
      ensure
        release
        @client.calls.leave
      end

      def send_items(items)
        # Parallel: the calls of an automatic batch were made concurrently, so
        # nothing orders them, and Centrifugo pipelines their broker commands.
        body = "{\"commands\":[#{items.map(&:command).join(",")}],\"parallel\":true}"
        # The latest deadline of the calls, never less than request_timeout
        # from now.
        timeout = [@client.request_timeout, *items.map { it.deadline - HTTP.now }].max
        replies =
          if @batch_context
            out = nil
            @batch_context.call(items.map(&:storage)) { out = @client.send_auto_batch(body, items.size, timeout) }
            out
          else
            @client.send_auto_batch(body, items.size, timeout)
          end
      rescue StandardError => e
        items.each do |q|
          q.error = e
          q.done << true
        end
      else
        items.zip(replies) do |q, r|
          q.reply = r
          q.done << true
        end
      end
    end
  end
end
