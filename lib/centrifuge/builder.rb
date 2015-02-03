require 'centrifuge/request'

module Centrifuge
  class Builder
    attr_accessor :method, :data, :client

    def initialize(method, data, client)
      @method, @data, @client = method, data, client
    end

    def process
      body = { data: json(method, data) }
      body.merge!(sign: sign(body[:data]))
      Centrifuge::Request.new(client.client, 'POST', client.url, nil, body).send
    end

    private

    def json(method, params)
      MultiJson.dump({ method: method, params: params })
    end

    def sign(body)
      dig = OpenSSL::Digest.new('md5')
      OpenSSL::HMAC.hexdigest(dig, secret, "#{project_id}#{body}")
    end

    def project_id
      client.project_id
    end

    def secret
      client.secret
    end
  end
end
