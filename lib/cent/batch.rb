# frozen_string_literal: true

module Cent
  # The outcome of a sent batch as a whole. Each command's own outcome is in the
  # Pending its method returned.
  #
  # @!attribute [r] replied
  #   @return [Boolean] true when Centrifugo replied to every command, the failed
  #     ones included; false when the batch failed as a whole. True for an empty
  #     batch.
  # @!attribute [r] failed
  #   @return [Array<FailedCommand>] the commands which failed, with their
  #     errors, in the order they were added
  class BatchResult < Data.define(:replied, :failed)
    include Message

    # @return [Boolean] alias of replied
    def replied? = replied
  end

  # The outcome of one command of a batch, available once the batch is sent.
  class Pending
    # @api private
    def initialize(batch, index)
      @batch = batch
      @index = index
    end

    # The command's result, or its error raised: an ApiError for this command,
    # the error which failed the whole batch, or BatchNotSentError. A broadcast
    # raises BroadcastFailedChannelsError, carrying every channel's outcome,
    # when any channel failed.
    #
    # @return [Object] the result of the command's method
    # @raise [Error]
    def value = @batch.outcome(@index)

    # A Pending of no batch, whose {#value} returns +value+ or raises +error+:
    # for test doubles of code which reads a batch's outcomes.
    #
    #   Cent::Pending.resolved(Cent::PublishResult.new(offset: 1))
    #   Cent::Pending.resolved(error: Cent::ApiError.for_code(102, "unknown channel"))
    #
    # @param value [Object]
    # @param error [Exception, nil]
    # @return [Pending]
    def self.resolved(value = nil, error: nil) = new(Resolved.new(value, error), 0)

    # The outcome of a resolved Pending.
    Resolved = Struct.new(:value, :error) do
      def outcome(_) = error ? raise(error) : value
    end
    private_constant :Resolved
  end

  # Commands sent to Centrifugo in one request. Create one with
  # {Client#new_batch}, add commands with its methods - one per API method, each
  # taking the method's fields and returning a {Pending} - then send it:
  #
  #   batch = client.new_batch
  #   pub = batch.publish(channel: "news", data: { text: "hi" })
  #   stats = batch.presence_stats(channel: "news")
  #   batch.send            # raises unless every command succeeded
  #   pub.value.offset
  #
  # A batch is sent once, and is not safe for concurrent use.
  class Batch
    include BatchMethods

    # @api private
    def initialize(client, parallel)
      @client = client
      @parallel = parallel
      @commands = []
      @methods = []
      # Per command: an error which fails the whole batch before sending - a
      # request the client can tell is invalid.
      @invalid = []
      # Per command, filled when sent: its outcome, a result or an error.
      @outcomes = []
      @replies = nil
      @error = nil
      @sent = false
    end

    # @return [Integer] how many commands the batch has
    def size = @commands.size
    alias length size

    # @return [Boolean]
    def empty? = @commands.empty?

    # Sends the batch and waits for Centrifugo's reply to every command.
    #
    # It returns when every command succeeded. BatchFailedCommandsError means
    # one or more commands failed, up to all: every command got its own reply,
    # each Pending holds its outcome. Any other error means the batch failed as
    # a whole: no command got a reply, and every Pending raises that error. A
    # command the client can tell is invalid fails the whole batch before
    # anything is sent. An empty batch sends nothing.
    #
    # Called with a method name, it is Object#send.
    #
    # @param timeout [Numeric, nil] seconds bounding the call: request_timeout
    #   when nil
    # @return [BatchResult]
    # @raise [Error]
    def send(*args, timeout: nil, **, &)
      return __send__(*args, **, &) unless args.empty?

      raise BatchSentError, "batch already sent" if @sent

      @sent = true
      begin
        if @commands.empty?
          @client.send_batch(nil, 0, timeout)
          @replies = []
          return BatchResult.new(replied: true, failed: [])
        end
        @invalid.each_with_index do |err, i|
          raise InvalidRequestError, "batch command ##{i}: #{err.message}" if err
        end
        parallel = @parallel ? ',"parallel":true' : ""
        body = "{\"commands\":[#{@commands.join(",")}]#{parallel}}"
        @replies = @client.send_batch(body, @commands.size, timeout)
      rescue StandardError => e
        @error = e
        raise
      end
      failed = []
      @methods.each_with_index do |method, i|
        out = resolve(i)
        failed << FailedCommand.new(index: i, method:, error: out) if out.is_a?(Exception)
      end
      res = BatchResult.new(replied: true, failed:)
      raise BatchFailedCommandsError.new(failed, @commands.size, res) unless failed.empty?

      res
    end

    # @api private
    def outcome(index)
      raise BatchNotSentError, "batch not sent yet" unless @sent
      raise @error if @error

      out = resolve(index)
      raise out if out.is_a?(Exception)

      out
    end

    private

    def add(method, result_class, &)
      append(method, ->(r, i) { result_class.from_wire(r[method] || {}, "replies[#{i}].#{method}") }, &)
    end

    def add_broadcast
      channels = []
      key = ""
      decode = lambda do |r, i|
        BroadcastResult.from_wire(r["broadcast"] || {}, channels, key).check!
      rescue DecodeError => e
        raise DecodeError, "replies[#{i}]: #{e.message}"
      end
      append("broadcast", decode) do
        w = yield
        channels = w["channels"] || []
        key = w["idempotency_key"] || ""
        w
      end
    end

    def append(method, decode)
      raise FrozenError.new("cent: command added to a batch that was already sent", receiver: self) if @sent

      text = ""
      invalid = nil
      begin
        w = Reply.validate(method, yield)
        text = "{\"#{method}\":#{Client.encode(w)}}"
      rescue InvalidRequestError => e
        invalid = InvalidRequestError.new("invalid #{method} request: #{e.message}")
      end
      @commands << text
      @methods << method
      @invalid << invalid
      @outcomes << decode
      Pending.new(self, @commands.size - 1)
    end

    # Decodes command i's outcome once, so that send's BatchFailedCommandsError
    # holds the very error its Pending raises.
    def resolve(i)
      out = @outcomes[i]
      return out unless out.is_a?(Proc)

      reply = @replies[i]
      err = Reply.command_error(reply, i, @methods[i])
      @outcomes[i] =
        (err || begin
          out.call(reply, i)
        rescue Error => e
          e
        end)
    end
  end
end
