# frozen_string_literal: true

module Cent
  # What every result and message type has besides its fields: Hash and JSON
  # forms, nested ones included, for rendering or logging a result -
  # +render json: client.history(channel:)+ in Rails, say.
  #
  #   res = client.history(channel: "news", limit: 1)
  #   res.to_h      # => {publications: [{data: {"text" => "hi"}, info: nil, offset: 1, tags: {}}], offset: 1, ...}
  #   res.to_json   # => '{"publications":[{"data":{"text":"hi"},...}],...}'
  #
  # Payloads stay as they are. An error in a result - a channel's, in a
  # broadcast - is its message in JSON.
  module Message
    # The fields as a Hash with Symbol keys, nested messages as Hashes too.
    #
    # @return [Hash{Symbol => Object}]
    def to_h(&)
      return super if block_given?

      super.transform_values { Message.deep(it) }
    end

    # The Hash a JSON encoder writes: {#to_h}, errors as their messages.
    #
    # @return [Hash{String => Object}]
    def as_json(*) = Message.json(to_h)

    # @return [String] the JSON of {#as_json}
    def to_json(*) = as_json.to_json(*)

    # @api private
    def self.deep(v)
      case v
      when Message then v.to_h
      when Array then v.map { deep(it) }
      when Hash then v.transform_values { deep(it) }
      else v
      end
    end

    # @api private
    def self.json(v)
      case v
      when Hash then v.to_h { |k, x| [k.to_s, json(x)] }
      when Array then v.map { json(it) }
      when Exception then v.message
      else v
      end
    end
  end
end
