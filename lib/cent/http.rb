# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module Cent
  # The default HTTP transport: Net::HTTP connections kept alive in a pool, each
  # request bounded by one deadline.
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

    # A socket whose every read and write is bounded by the time left until the
    # request's deadline: Net::HTTP bounds each read on its own, so a reply
    # arriving in pieces - its headers too - could outlast any timeout given
    # per read.
    class DeadlineIO < Net::BufferedIO
      attr_accessor :deadline

      private

      def rbuf_fill
        @read_timeout = left(Net::ReadTimeout)
        super
      end

      def write0(*strs)
        @write_timeout = left(Net::WriteTimeout)
        super
      end

      def left(error)
        return nil if deadline.nil?

        t = deadline - HTTP.now
        raise error, @io if t <= 0

        t
      end
    end

    # What makes a Net::HTTP connection send one request at a time, by the
    # deadline it is given. A connection is made with Net::HTTP.new when it is
    # needed, and extended with it - not a subclass of Net::HTTP made when cent
    # loads: whatever Net::HTTP is then - WebMock's in an application's tests,
    # say - sends the request.
    module Connection
      attr_reader :deadline, :idle_since

      def start_request(deadline)
        @deadline = deadline
        t = [deadline - HTTP.now, 0.001].max
        # Connecting, the TLS handshake included, by the time left; reads and
        # writes by DeadlineIO.
        self.open_timeout = t
        @socket.deadline = deadline if @socket.is_a?(DeadlineIO)
      end

      def idle! = (@idle_since = HTTP.now)

      private

      def on_connect
        sock = DeadlineIO.new(@socket.io, read_timeout: @read_timeout, write_timeout: @write_timeout,
                                          continue_timeout: @continue_timeout, debug_output: @debug_output)
        sock.deadline = @deadline
        @socket = sock
      end
    end

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

      # Sends a POST, and returns [status, headers, body]: the body of a
      # status other than 200 read up to MAX_API_ERROR_BYTES.
      def post(url, headers, body, deadline)
        uri = URI.parse(url)
        key = [uri.scheme, uri.host, uri.port]
        conn = checkout(key, uri)
        reusable = false
        begin
          conn.start_request(deadline)
          conn.start unless conn.started?
          req = Net::HTTP::Post.new(uri.request_uri, headers)
          req.body = body
          out = nil
          catch(:drop) do
            conn.request(req) do |res|
              out = [res.code.to_i, res.to_hash.transform_values { it.join(", ") }, +""]
              read(res, out[2])
            end
            reusable = conn.started?
          end
          out
        ensure
          reusable ? checkin(key, conn) : discard(conn)
        end
      end

      def close
        conns = @lock.synchronize do
          @closed = true
          all = @idle.values.flatten
          @idle.clear
          all
        end
        conns.each { discard(it) }
      end

      private

      # Reads the body into +body+: whole for a 200, up to MAX_API_ERROR_BYTES
      # otherwise, the rest drained so that the connection is reused - or
      # dropped, by a throw, when there is too much.
      def read(res, body)
        if res.code == "200"
          res.read_body { body << it }
          return
        end
        total = 0
        res.read_body do |chunk|
          body << chunk.byteslice(0, MAX_API_ERROR_BYTES - body.bytesize) if body.bytesize < MAX_API_ERROR_BYTES
          total += chunk.bytesize
          throw :drop if total > MAX_DRAIN_BYTES
        end
      end

      def checkout(key, uri)
        stale = []
        conn = @lock.synchronize do
          list = @idle[key]
          while (c = list.pop)
            break c if HTTP.now - c.idle_since < IDLE_TIMEOUT

            stale << c
          end
        end
        stale.each { discard(it) }
        return conn if conn

        conn = Net::HTTP.new(uri.host, uri.port)
        conn.extend(Connection)
        conn.use_ssl = uri.scheme == "https"
        conn.keep_alive_timeout = IDLE_TIMEOUT
        conn.max_retries = 0
        @options.each { |k, v| conn.public_send(:"#{k}=", v) }
        conn
      end

      def checkin(key, conn)
        conn.idle!
        keep = @lock.synchronize do
          next false if @closed || @idle[key].size >= MAX_IDLE

          @idle[key] << conn
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
