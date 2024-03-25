# frozen_string_literal: true

require 'faraday'
require 'cent/http'

module Cent
  # Cent::Client
  #
  #   Main object that handles configuration and requests to centrifugo API
  #
  class Client
    # @param endpoint [String]
    #   (default: 'http://localhost:8000/api') Centrifugo HTTP API URL
    #
    # @param api_key [String]
    #   Centrifugo API key(used to perform requests)
    #
    # @yield [Faraday::Connection] yields connection object so that it can be configured
    #
    # @example Construct new client instance
    #   Cent::Client.new(
    #     endpoint: 'http://localhost:8000/api',
    #     api_key: 'api key'
    #   )
    #
    def initialize(api_key:, endpoint: 'http://localhost:8000/api')
      headers = {
        'Content-Type' => 'application/json',
        'Authorization' => "apikey #{api_key}"
      }

      @connection = Faraday.new(endpoint, headers: headers) do |conn|
        conn.request :json # encode req bodies as JSON

        conn.response :json # decode response bodies as JSON
        conn.response :raise_error

        yield conn if block_given?
      end
    end

    # Publish data into channel
    #
    # @param channel [String]
    #   Name of the channel to publish
    #
    # @param data [Hash]
    #   Data for publication in the channel
    #
    # @example Publish `content: 'hello'` into `chat` channel
    #   client.publish(channel: 'chat', data: 'hello') #=> {}
    #
    # @see (https://centrifugal.github.io/centrifugo/server/http_api/#publish)
    #
    # @raise [Cent::Error, Cent::ResponseError]
    #
    # @return [Hash] Return empty hash in case of successful publish
    #
    def publish(channel:, data:)
      execute('publish', channel: channel, data: data)
    end

    # Publish data into multiple channels
    #   (Similar to `#publish` but allows to send the same data into many channels)
    #
    # @param channels [Array<String>] Collection of channels names to publish
    # @param data [Hash] Data for publication in the channels
    #
    # @example Broadcast `content: 'hello'` into `channel_1`, 'channel_2' channels
    #   client.broadcast(channels: ['channel_1', 'channel_2'], data: 'hello') #=> {}
    #
    # @see (https://centrifugal.github.io/centrifugo/server/http_api/#broadcast)
    #
    # @raise [Cent::Error, Cent::ResponseError]
    #
    # @return [Hash] Return empty hash in case of successful broadcast
    #
    def broadcast(channels:, data:)
      execute('broadcast', channels: channels, data: data)
    end

    # Unsubscribe user from channel
    #
    # @param channel [String]
    #   Channel name to unsubscribe from
    #
    # @param user [String, Integer]
    #   User ID you want to unsubscribe
    #
    # @example Unsubscribe user with `id = 1` from `chat` channel
    #   client.unsubscribe(channel: 'chat', user: '1') #=> {}
    #
    # @see (https://centrifugal.github.io/centrifugo/server/http_api/#unsubscribe)
    #
    # @raise [Cent::Error, Cent::ResponseError]
    #
    # @return [Hash] Return empty hash in case of successful unsubscribe
    #
    def unsubscribe(channel:, user:)
      execute('unsubscribe', channel: channel, user: user)
    end

    # Disconnect user by it's ID
    #
    # @param user [String, Integer]
    #   User ID you want to disconnect
    #
    # @example Disconnect user with `id = 1`
    #   client.disconnect(user: '1') #=> {}
    #
    # @see (https://centrifugal.github.io/centrifugo/server/http_api/#disconnect)
    #
    # @raise [Cent::Error, Cent::ResponseError]
    #
    # @return [Hash] Return empty hash in case of successful disconnect
    #
    def disconnect(user:)
      execute('disconnect', user: user)
    end

    # Get channel presence information
    #   (all clients currently subscribed on this channel)
    #
    # @param channel [String] Name of the channel
    #
    # @example Get presence information for channel `chat`
    #   client.presence(channel: 'chat') #=> {
    #     "result" => {
    #       "presence" => {
    #         "c54313b2-0442-499a-a70c-051f8588020f" => {
    #           "client" => "c54313b2-0442-499a-a70c-051f8588020f",
    #           "user" => "42"
    #         },
    #         "adad13b1-0442-499a-a70c-051f858802da" => {
    #           "client" => "adad13b1-0442-499a-a70c-051f858802da",
    #           "user" => "42"
    #         }
    #       }
    #     }
    #   }
    #
    # @see (https://centrifugal.github.io/centrifugo/server/http_api/#presence)
    #
    # @raise [Cent::Error, Cent::ResponseError]
    #
    # @return [Hash]
    #   Return hash with information about all clients currently subscribed on this channel
    #
    def presence(channel:)
      execute('presence', channel: channel)
    end

    # Get short channel presence information
    #
    # @param channel [String] Name of the channel
    #
    # @example Get short presence information for channel `chat`
    #   client.presence_stats(channel: 'chat') #=> {
    #     "result" => {
    #       "num_clients" => 0,
    #       "num_users" => 0
    #     }
    #   }
    #
    # @see (https://centrifugal.github.io/centrifugo/server/http_api/#presence_stats)
    #
    # @raise [Cent::Error, Cent::ResponseError]
    #
    # @return [Hash]
    #   Return hash with short presence information about channel
    #
    def presence_stats(channel:)
      execute('presence_stats', channel: channel)
    end

    # Get channel history information
    #   (list of last messages published into channel)
    #
    # @param channel [String] Name of the channel
    #
    # @example Get history for channel `chat`
    #   client.history(channel: 'chat') #=> {
    #     "result" => {
    #       "publications" => [
    #         {
    #           "data" => {
    #             "text" => "hello"
    #           },
    #           "uid" => "BWcn14OTBrqUhTXyjNg0fg"
    #         },
    #         {
    #           "data" => {
    #             "text" => "hi!"
    #           },
    #           "uid" => "Ascn14OTBrq14OXyjNg0hg"
    #         }
    #       ]
    #     }
    #   }
    #
    # @see (https://centrifugal.github.io/centrifugo/server/http_api/#history)
    #
    # @raise [Cent::Error, Cent::ResponseError]
    #
    # @return [Hash]
    #   Return hash with a list of last messages published into channel
    #
    def history(channel:)
      execute('history', channel: channel)
    end

    # Get list of active(with one or more subscribers) channels.
    #
    # @example Get active channels list
    #   client.channels #=> {
    #     "result" => {
    #       "channels" => [
    #         "chat"
    #       ]
    #     }
    #   }
    #
    # @see (https://centrifugal.github.io/centrifugo/server/http_api/#channels)
    #
    # @raise [Cent::Error, Cent::ResponseError]
    #
    # @return [Hash]
    #   Return hash with a list of active channels
    #
    def channels
      execute('channels', {})
    end

    # Get information about running Centrifugo nodes
    #
    # @example Get running centrifugo nodes list
    #   client.info #=> {
    #     "result" => {
    #       "nodes" => [
    #         {
    #           "name" => "Alexanders-MacBook-Pro.local_8000",
    #           "num_channels" => 0,
    #           "num_clients" => 0,
    #           "num_users" => 0,
    #           "uid" => "f844a2ed-5edf-4815-b83c-271974003db9",
    #           "uptime" => 0,
    #           "version" => ""
    #         }
    #       ]
    #     }
    #   }
    #
    # @see (https://centrifugal.github.io/centrifugo/server/http_api/#info)
    #
    # @raise [Cent::Error, Cent::ResponseError]
    #
    # @return [Hash]
    #   Return hash with a list of last messages published into channel
    #
    def info
      execute('info', {})
    end

    private

    def execute(method, data)
      body = { method: method, params: data }

      Cent::HTTP.new(connection: @connection).post(body: body)
    end
  end
end
