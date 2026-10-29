# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module Cent
  # The default HTTP transport: Net::HTTP connections kept alive in a pool, each
  # request bounded by one deadline through Net::HTTP's public API: the time
  # left as its open, read and write timeouts, and again as the read timeout
  # before each chunk of the body. Only a reply's headers trickling in can
  # outlast it.
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
          left = time_left(deadline)
          conn.open_timeout = left
          conn.read_timeout = left
          conn.write_timeout = left
          conn.start unless conn.started?
          req = Net::HTTP::Post.new(uri.request_uri, headers)
          req.body = body
          out = nil
          catch(:drop) do
            conn.request(req) do |res|
              out = [res.code.to_i, res.to_hash.transform_values { it.join(", ") }, +""]
              read(conn, res, out[2], deadline)
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
          all = @idle.values.flatten(1).map(&:first)
          @idle.clear
          all
        end
        conns.each { discard(it) }
      end

      private

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
