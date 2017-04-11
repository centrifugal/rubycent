require "centrifuge/version"
require "centrifuge/client"
require 'forwardable'

module Centrifuge
  if defined?(Rails)
    class Engine < Rails::Engine
    end
  end

  class Error < RuntimeError; end
  class AuthenticationError < Error; end
  class ConfigurationError < Error; end
  class HTTPError < Error; attr_accessor :original_error; end

  class << self
    extend Forwardable

    def_delegators :default_client, :scheme, :host, :port, :secret
    def_delegators :default_client, :scheme=, :host=, :port=, :secret=
    def_delegators :default_client, :connect_timeout=, :send_timeout=, :receive_timeout=, :keep_alive_timeout=
    def_delegators :default_client, :broadcast, :publish, :unsubscribe, :disconnect, :presence, :history, :channels, :stats
    def_delegators :default_client, :token_for, :generate_channel_sign

    attr_writer :logger

    def logger
      @logger ||= begin
        log = Logger.new($stdout)
        log.level = Logger::INFO
        log
      end
    end

    def default_client
      @default_client ||= Centrifuge::Client.new
    end
  end

  if ENV['CENTRIFUGE_URL']
    self.url = ENV['CENTRIFUGE_URL']
  end
end
