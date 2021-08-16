# frozen_string_literal: true

RSpec.describe Cent do
  it 'has a version number' do
    expect(Cent::VERSION).not_to be nil
  end

  describe 'Cent::Client' do
    let(:client) do
      Cent::Client.new(api_key: 'api_key', endpoint: 'https://centrifu.go/api') do |c|
        c.options.open_timeout = 15
        c.options.timeout = 15
        c.headers['User-Agent'] = 'Centrifugo API V2 Ruby Client'
        c.adapter :test do |stub|
          info_body = { method: 'info', params: {} }.to_json
          info_headers = {
            'Content-Type' => 'application/json',
            'Authorization' => 'apikey api_key',
            'User-Agent' => 'Centrifugo API V2 Ruby Client'
          }

          stub.post('/api', info_body, info_headers) do |_env|
            [
              200,
              { 'Content-Type': 'application/json' },
              '{}'
            ]
          end
        end
      end
    end

    it 'supports connection configuration' do
      expect(client.info).to eq({})
    end
  end
end
