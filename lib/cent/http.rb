# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module Cent
  # The default HTTP transport: Net::HTTP connections kept alive in a pool, each
  # request bounded by one deadline through Net::HTTP's public API: the time
  # left as its open, read and write timeouts, and again as the read timeout
  # before each chunk of the body. Those bound each read, so a reply's headers
  # trickling in would outlast them: the Watchdog finishes a connection whose
  # deadline passed.
  #
  # @api private
  module HTTP
    # Up to 256 idle connections to a host are kept, so that a burst does not
    # open connections only to close them; idle ones are closed after 50
    # seconds, before load balancers commonly close theirs.
    MAX_IDLE = 256
    IDLE_TIMEOUT = 50.0

    # The body of an unexpected status is read up to MAX_API_ERROR_BYTES for a
    # Centrifugo error in it, MAX_ERROR_BODY_BYTES of it kept for the HTTPError,
    # and the rest drained up to MAX_DRAIN_BYTES, so that the connection is
    # reused.
    MAX_ERROR_BODY_BYTES = 512
    MAX_API_ERROR_BYTES = 4 << 10
    MAX_DRAIN_BYTES = 64 << 10

    def self.now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

    # Finishes the connections whose request's deadline passed, which wakes a
    # read blocked on them with an IOError. One thread for every pool, started
    # when first needed, and again in a forked process.
    class Watchdog
      Entry = Struct.new(:conn, :deadline, :fired)

      def initialize
        @fork_lock = Mutex.new
        reset
      end

      # Returns the block's value, with +conn+ finished if +deadline+ passes
      # first. An error raised once it was finished - an IOError from the read
      # it woke, or whatever Net::HTTP raises on a connection finished under
      # it - is the deadline's.
      def watch(conn, deadline)
        reset_after_fork
        entry = Entry.new(conn, deadline, false)
        @lock.synchronize do
          @thread = Thread.new { run } unless @thread&.alive?
          @entries << entry
          @wake.signal
        end
        begin
          yield
        rescue StandardError
          raise Net::ReadTimeout, "the call's deadline passed" if fired?(entry)

          raise
        ensure
          # Under the lock: once removed, the connection is never finished
          # again, so that it goes back to the pool safely.
          @lock.synchronize { @entries.delete(entry) }
        end
      end

      private

      # A forked process starts with fresh state: the parent's thread did not
      # survive the fork, its entries are the parent's connections, and its
      # lock may have been held by a thread which no longer exists - taking it
      # would block forever.
      def reset_after_fork
        return if @pid == ::Process.pid

        @fork_lock.synchronize do
          reset unless @pid == ::Process.pid
        end
      end

      def reset
        @lock = Mutex.new
        @wake = ConditionVariable.new
        @entries = []
        @thread = nil
        @pid = ::Process.pid
      end

      def fired?(entry) = @lock.synchronize { entry.fired }

      def run
        Thread.current.name = "rubycent-watchdog"
        @lock.synchronize do
          loop do
            now = HTTP.now
            next_deadline = nil
            @entries.each do |e|
              next if e.fired

              if e.deadline <= now
                e.fired = true
                finish(e.conn)
              elsif next_deadline.nil? || e.deadline < next_deadline
                next_deadline = e.deadline
              end
            end
            @wake.wait(@lock, next_deadline && (next_deadline - now))
          end
        end
      end

      def finish(conn)
        conn.finish
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      end
    end

    WATCHDOG = Watchdog.new

    # Connections kept alive per scheme, host and port. Safe for concurrent use.
    class Pool
      # @param options [Hash] Net::HTTP settings for every connection: ca_file,
      #   cert, key, verify_mode, local_host and the like
      def initialize(options = {})
        @options = options
        @idle = Hash.new { |h, k| h[k] = [] }
        @lock = Mutex.new
        @closed = false
      end

      # @return [Hash] the Net::HTTP settings of its connections
      attr_reader :options

      # Sends a POST, and returns [status, headers, body]: the body of a
      # status other than 200 read up to MAX_API_ERROR_BYTES.
      def post(url, headers, body, deadline)
        uri = URI.parse(url)
        key = [uri.scheme, uri.host, uri.port]
        conn = checkout(key, uri)
        reusable = false
        begin
          out, reusable = WATCHDOG.watch(conn, deadline) { exchange(conn, uri, headers, body, deadline) }
          reusable &&= conn.started?
          out
        ensure
          reusable ? checkin(key, conn) : discard(conn)
        end
      end

      def close
        conns = @lock.synchronize do
          @closed = true
          all = @idle.values.flatten(1).map(&:first)
          @idle.clear
          all
        end
        conns.each { discard(it) }
      end

      private

      # Sends the request on +conn+, and returns [[status, headers, body],
      # whether the connection may be reused].
      def exchange(conn, uri, headers, body, deadline)
        left = time_left(deadline)
        conn.open_timeout = left
        conn.read_timeout = left
        conn.write_timeout = left
        conn.start unless conn.started?
        req = Net::HTTP::Post.new(uri.request_uri, headers)
        req.body = body
        out = nil
        reusable = false
        catch(:drop) do
          conn.request(req) do |res|
            out = [res.code.to_i, res.to_hash.transform_values { it.join(", ") }, +""]
            read(conn, res, out[2], deadline)
          end
          reusable = true
        end
        [out, reusable]
      end

      # Reads the body into +body+: whole for a 200, up to MAX_API_ERROR_BYTES
      # otherwise, the rest drained so that the connection is reused - or
      # dropped, by a throw, when there is too much. Each next chunk is read by
      # the time left: a body arriving in pieces stops at the deadline.
      def read(conn, res, body, deadline)
        total = 0
        res.read_body do |chunk|
          if res.code == "200"
            body << chunk
          else
            body << chunk.byteslice(0, MAX_API_ERROR_BYTES - body.bytesize) if body.bytesize < MAX_API_ERROR_BYTES
            total += chunk.bytesize
            throw :drop if total > MAX_DRAIN_BYTES
          end
          conn.read_timeout = time_left(deadline)
        end
      end

      def time_left(deadline)
        t = deadline - HTTP.now
        raise Net::ReadTimeout, "the call's deadline passed" if t <= 0

        t
      end

      def checkout(key, uri)
        stale = []
        conn = @lock.synchronize do
          list = @idle[key]
          while (entry = list.pop)
            c, since = entry
            break c if HTTP.now - since < IDLE_TIMEOUT

            stale << c
          end
        end
        stale.each { discard(it) }
        return conn if conn

        conn = Net::HTTP.new(uri.host, uri.port)
        conn.use_ssl = uri.scheme == "https"
        conn.keep_alive_timeout = IDLE_TIMEOUT
        conn.max_retries = 0
        @options.each { |k, v| conn.public_send(:"#{k}=", v) }
        conn
      end

      def checkin(key, conn)
        keep = @lock.synchronize do
          next false if @closed || @idle[key].size >= MAX_IDLE

          @idle[key] << [conn, HTTP.now]
          true
        end
        discard(conn) unless keep
      end

      def discard(conn)
        conn.finish if conn.started?
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      end
    end
  end
end
