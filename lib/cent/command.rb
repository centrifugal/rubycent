# frozen_string_literal: true

module Cent
  # An API call left for Centrifugo's async consumers to make: written to a
  # PostgreSQL outbox table, a Kafka topic, a Redis stream. See
  # https://centrifugal.dev/docs/server/consumers.
  #
  # There is a class method per API method, taking the fields of its request as
  # keyword arguments, as Client's methods do. The call is checked as a Client
  # checks it before sending - an invalid one raises InvalidRequestError here,
  # rather than in Centrifugo, whose consumers drop a command they cannot run -
  # and encoded:
  #
  #   cmd = Cent::Command.publish(channel: "news", data: { text: "hi" })
  #   db.exec_params("INSERT INTO centrifugo_outbox (method, payload, partition) VALUES ($1, $2, 0)",
  #                  [cmd.method, cmd.payload])
  #
  # Consumers take it as its method and payload apart - the outbox table's
  # method and payload columns, a message attribute - or as the JSON message
  # +{"method": ..., "payload": ...}+ of {#to_json} (Kafka, NATS JetStream).
  # {#as_json} gives that message with payload as a Hash, so a command inside
  # another value - rendered by Rails, say - carries an object, not a string.
  #
  # The outbox table's payload column is jsonb: raw SQL passes {#payload}, JSON
  # text, as it is; ActiveRecord's json types take the object,
  # +JSON.parse(cmd.payload)+ - given the text, they would store a JSON string.
  #
  # Within a partition a consumer keeps commands in order: a channel's commands
  # keep their order only when every writer derives their partition from the
  # channel the same way - the channel as a Kafka message key, say.
  #
  # @!attribute [r] method
  #   @return [String] the API method, such as "publish"
  # @!attribute [r] payload
  #   @return [String] the request, as JSON text
  class Command < Data.define(:method, :payload)
    extend CommandMethods

    # The command as one JSON message: +{"method": ..., "payload": ...}+, the
    # payload's text kept exactly.
    #
    # @return [String]
    def to_json(*) = "{\"method\":#{JSON.generate(method)},\"payload\":#{payload}}"

    # The message of {#to_json} as Ruby values, payload a Hash.
    #
    # @return [Hash{String => Object}]
    def as_json(*) = { "method" => method, "payload" => JSON.parse(payload) }

    def self.build(method)
      w = Reply.validate(method, yield)
      new(method:, payload: Client.encode(w))
    rescue InvalidRequestError => e
      raise InvalidRequestError, "invalid #{method} request: #{e.message}"
    end
    private_class_method :build
  end
end
