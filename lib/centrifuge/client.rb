require 'multi_json'
require 'httpclient'
require 'centrifuge/builder'

module Centrifuge
  class Client
    DEFAULT_OPTIONS = {
      scheme: 'http',
      host: 'localhost',
      port: 8000,
    }
    attr_accessor :scheme, :host, :port, :project_key, :secret
    attr_writer :connect_timeout, :send_timeout, :receive_timeout,
    :keep_alive_timeout

    ## CONFIGURATION ##

    def initialize(options = {})
      options = DEFAULT_OPTIONS.merge(options)
      @scheme, @host, @port, @project_key, @secret = options.values_at(
       :scheme, :host, :port, :project_key, :secret
      )
      set_default_timeouts
    end

    def set_default_timeouts
      @connect_timeout = 5
      @send_timeout = 5
      @receive_timeout = 5
      @keep_alive_timeout = 30
    end

    def url(path = nil)
      URI::Generic.build({
        scheme: scheme.to_s,
        host: host,
        port: port,
        path: "/api/#{project_key}#{path}"
      })
    end

    def publish(channel, data)
      Centrifuge::Builder.new('publish', { channel: channel, data: data }, self).process
    end

    def unsubscribe(channel, user)
      Centrifuge::Builder.new('unsubscribe', { channel: channel, user: user }, self).process
    end

    def disconnect(user)
      Centrifuge::Builder.new('disconnect', { user: user }, self).process
    end

    def presence(channel)
      Centrifuge::Builder.new('presence', { channel: channel }, self).process
    end

    def history(channel)
      Centrifuge::Builder.new('history', { channel: channel }, self).process
    end

    def channels()
      Centrifuge::Builder.new('channels', {}, self).process
    end

    def token_for(user, timestamp, user_info = "")
      sign("#{user}#{timestamp}#{user_info}")
    end

    def generate_channel_sign(client, channel, user_info="")
      data = "#{client}#{channel}#{user_info}"
      OpenSSL::HMAC.hexdigest(new_sha256, secret, data)
    end

    def generate_api_sign(encoded_data)
      sign("#{encoded_data}")
    end

    def sign(body)
      data = "#{project_key}#{body}"
      OpenSSL::HMAC.hexdigest(new_sha256, secret, data)
    end

    def client
      @client ||= begin
        HTTPClient.new.tap do |http|
          http.connect_timeout = @connect_timeout
          http.send_timeout = @send_timeout
          http.receive_timeout = @receive_timeout
          http.keep_alive_timeout = @keep_alive_timeout
        end
      end
    end

    private

    def new_sha256
      OpenSSL::Digest::SHA256.new
    end

  end
end
