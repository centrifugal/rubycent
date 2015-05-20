require 'digest/md5'

module Centrifuge
  class Request
    attr_accessor :client, :verb, :uri, :body, :head, :params

    def initialize(client, verb, uri, params, body = nil, head = {})
      @client, @verb, @uri, @params, @body = client, verb, uri, params, body
      @head = head
    end

    def send
      response = request_or_rescue
      body = response.body ? response.body.chomp : nil
      handle_response(response.code.to_i, body)
    end

    private

    def request_or_rescue
      begin
        response = client.request(verb, uri, params, body, head)
      rescue HTTPClient::BadResponseError, HTTPClient::TimeoutError, SocketError, Errno::ECONNREFUSED => original_error
        error = Centrifuge::HTTPError.new("#{original_error.message} (#{original_error.class})")
        error.original_error = original_error
        raise error
      end
    end

    def handle_response(status_code, body)
      case status_code
      when 200
        return MultiJson.load(body)
      when 202
        return true
      when 400
        raise Error, "Bad request: #{body}"
      when 401
        raise AuthenticationError, body
      when 404
        raise Error, "404 Not found (#{@uri.path} #{@uri.to_json})"
      when 407
        raise Error, "Proxy Authentication Required"
      else
        raise Error, "Unknown error (status code #{status_code}): #{body}"
      end
    end
  end
end
