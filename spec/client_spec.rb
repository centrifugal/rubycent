require 'spec_helper'

describe Centrifuge::Client do
  let(:options) { { scheme: :https, host: 'reddifuge.herokuapp.com', port: 443, project_id: '060748d06d4c411997e1b5255b2d969e', secret: '334e0fd69fc447a1b268d704f021f59c' } }
  let(:client) { Centrifuge::Client.new(options) }
  let(:data) { { action: :test } }

  it 'generates url' do
    expect(client.url.to_s).to eq "https://reddifuge.herokuapp.com:443/api/#{client.project_id}"
  end

  it 'publishes data' do
    stub_request(:post, "https://reddifuge.herokuapp.com/api/060748d06d4c411997e1b5255b2d969e").
    with(body: {"data"=>"{\"method\":\"publish\",\"params\":{\"channel\":\"testchannel\",\"data\":{\"action\":\"test\"}}}", "sign"=>"9191468cf61debb04768ff1f667a8df8"}).
    to_return(status: 200, body: "[{\"body\":true,\"error\":null,\"method\":\"publish\",\"uid\":null}]", headers: {})
    expect(client.publish("testchannel", data)).to eq [{"body" => true, "error" => nil, "method" => "publish", "uid" => nil}]
  end

  it 'unsubscribes user' do
    stub_request(:post, "https://reddifuge.herokuapp.com/api/060748d06d4c411997e1b5255b2d969e").
    with(body: {"data"=>"{\"method\":\"unsubscribe\",\"params\":{\"channel\":\"testchannel\",\"user\":\"23\"}}", "sign"=>"613a46c24a54ad546b7bf084c249d8c2"}).
    to_return(status: 200, body: "[{\"method\":\"unsubscribe\",\"error\":null,\"uid\":null,\"body\":true}]", headers: {})
    expect(client.unsubscribe("testchannel", "23")).to eq [{"method"=>"unsubscribe", "error"=>nil, "uid"=>nil, "body"=>true}]
  end

  it 'disconnects user' do
    stub_request(:post, "https://reddifuge.herokuapp.com/api/060748d06d4c411997e1b5255b2d969e").
    with(body: {"data"=>"{\"method\":\"disconnect\",\"params\":{\"user\":\"23\"}}", "sign"=>"1331a7cc6da5cb747cab3d4cfabc5644"}).
    to_return(status: 200, body: "[{\"method\":\"disconnect\",\"error\":null,\"uid\":null,\"body\":true}]", headers: {})
    expect(client.disconnect("23")).to eq [{"method"=>"disconnect", "error"=>nil, "uid"=>nil, "body"=>true}]
  end

  it 'fetches presence info' do
    stub_request(:post, "https://reddifuge.herokuapp.com/api/060748d06d4c411997e1b5255b2d969e").
    with(body: {"data"=>"{\"method\":\"presence\",\"params\":{\"channel\":\"testchannel\"}}", "sign"=>"9e3db58b7cf9d9eccee4c85ee87e6532"}).
    to_return(status: 200, body: "[{\"method\":\"presence\",\"error\":null,\"uid\":null,\"body\":{}}]", headers: {})
    expect(client.presence("testchannel")).to eq [{"method"=>"presence", "error"=>nil, "uid"=>nil, "body"=>{}}]
  end

  it 'fetches history' do
    stub_request(:post, "https://reddifuge.herokuapp.com/api/060748d06d4c411997e1b5255b2d969e").
    with(body: {"data"=>"{\"method\":\"history\",\"params\":{\"channel\":\"testchannel\"}}", "sign"=>"14413322f1fd26b4256db34941d6cdb7"}).
    to_return(status: 200, body: "[{\"method\":\"history\",\"error\":null,\"uid\":null,\"body\":[]}]", headers: {})
    expect(client.history("testchannel")).to eq [{"method"=>"history", "error"=>nil, "uid"=>nil, "body"=>[]}]
  end
end
