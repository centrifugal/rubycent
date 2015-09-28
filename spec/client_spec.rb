require 'spec_helper'

describe Centrifuge::Client do
  let(:options) { { scheme: :https, host: 'centrifugo-dev.herokuapp.com', port: 443, secret: 'secret' } }
  let(:client) { Centrifuge::Client.new(options) }
  let(:data) { { action: :test } }

  it 'generates url' do
    expect(client.url.to_s).to eq "https://centrifugo-dev.herokuapp.com:443/api/"
  end

  it 'publishes data' do
    channel = SecureRandom.hex
    expect(client.publish(channel, data)).to eq [{"body" => nil, "error" => nil, "method" => "publish"}]
  end

  it 'unsubscribes user' do
    channel = SecureRandom.hex
    expect(client.unsubscribe(channel, "23")).to eq [{"body"=>nil, "error"=>nil, "method"=>"unsubscribe"}]
  end

  it 'disconnects user' do
    expect(client.disconnect("23")).to eq [{"body" => nil, "error" => nil, "method" => "disconnect"}]
  end

  it 'fetches presence info' do
    channel = SecureRandom.hex
    expect(client.presence(channel)).to eq [{"body" => {"channel" => channel, "data" => {}}, "error" => nil, "method" => "presence"}]
  end

  it 'fetches history' do
    channel = SecureRandom.hex
    expect(client.history(channel)).to eq [{"body" => {"channel" => channel, "data" => []}, "error" => nil, "method"=>"history"}]
  end
end
