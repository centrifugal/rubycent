require 'spec_helper'

describe Centrifuge::Client do
  let(:options) { { scheme: :https, host: 'centrifugo.herokuapp.com', port: 443, secret: 'secret' } }
  let(:client) { Centrifuge::Client.new(options) }
  let(:data) { { action: :test } }
  let(:channel) { 'test_channel' }

  context 'API calls', :vcr do
    it 'generates url' do
      expect(client.url.to_s).to eq "https://centrifugo.herokuapp.com:443/api/"
    end

    it 'publishes data' do
      expect(client.publish(channel, data)).to eq [{"body" => nil, "error" => nil, "method" => "publish"}]
    end

    it 'broadcasts data' do
      channel1 = "#{channel}_1"
      expect(client.broadcast([channel, channel1], data)).to eq [{"body" => nil, "error" => nil, "method" => "broadcast"}]
    end

    it 'unsubscribes user' do
      expect(client.unsubscribe(channel, "23")).to eq [{"body"=>nil, "error"=>nil, "method"=>"unsubscribe"}]
    end

    it 'disconnects user' do
      expect(client.disconnect("23")).to eq [{"body" => nil, "error" => nil, "method" => "disconnect"}]
    end

    it 'fetches presence info' do
      expect(client.presence(channel)).to eq [{"body" => {"channel" => channel, "data" => {}}, "error" => nil, "method" => "presence"}]
    end

    it 'fetches history' do
      #we do so bcz history request store data on server and test can fall depend on it
      WebMock.allow_net_connect!
      VCR.eject_cassette
      VCR.turned_off do
        channel_history = "#{channel}_#{SecureRandom.hex}"
        expect(client.history(channel_history)).to eq [{"body" => {"channel" => channel_history, "data" => []}, "error" => nil, "method"=>"history"}]
      end
    end
  end

  context 'calculate hash' do
    let(:user) { "test@test.com" }
    let(:timestamp) { "1461702408" }
    let(:result) { client.token_for user, timestamp }
    it { expect(result).to eq 'be26ac57ef264c23662ba373e4b68670c1a006431c763af6d33ad10ab6aa97d9' }
  end
end

describe Centrifuge do
  context 'delegation' do
    it 'class should delegate methods to default client' do
      client_double = double('default_client')
      methods_to_delegate = [:scheme, :host, :port, :secret,
        :scheme=, :host=, :port=, :secret=,
        :connect_timeout=, :send_timeout=, :receive_timeout=, :keep_alive_timeout=,
        :broadcast, :publish, :unsubscribe, :disconnect, :presence, :history,
        :channels, :stats, :token_for, :generate_channel_sign]

      methods_to_delegate.each do |method|
        expect(client_double).to receive(method)
      end

      Centrifuge.stub(:default_client).and_return(client_double)

      methods_to_delegate.each do |method|
        Centrifuge.send(method)
      end
    end
  end
end
