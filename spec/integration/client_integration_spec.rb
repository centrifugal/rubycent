# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'

# These tests exercise a real Centrifugo server. They are skipped unless
# CENTRIFUGO_API_URL (and optionally CENTRIFUGO_API_KEY) are set — typically
# by `docker compose up -d` or in CI.
RSpec.describe Cent::Client, :integration do
  before do
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  let(:client) do
    described_class.new(
      api_key: ENV.fetch('CENTRIFUGO_API_KEY', 'api_key'),
      endpoint: ENV.fetch('CENTRIFUGO_API_URL')
    )
  end

  # Each test uses its own random channel so parallel runs don't collide.
  let(:channel) { "cent-rb-test-#{SecureRandom.hex(6)}" }

  describe '#info' do
    it 'returns at least one node' do
      response = client.info
      expect(response).to have_key('result')
      expect(response.dig('result', 'nodes')).to be_an(Array).and(be_any)
    end
  end

  describe '#publish + #history' do
    it 'round-trips a publication through channel history' do
      publish_resp = client.publish(channel: channel, data: { 'text' => 'hello' })
      expect(publish_resp).to have_key('result')
      expect(publish_resp.dig('result', 'offset')).to be > 0

      history_resp = client.history(channel: channel, limit: 10)
      pubs = history_resp.dig('result', 'publications')
      expect(pubs).to be_an(Array).and have_attributes(size: 1)
      expect(pubs.first['data']).to eq('text' => 'hello')
    end
  end

  describe '#broadcast' do
    it 'publishes the same data into multiple channels' do
      channels = [channel, "#{channel}-2"]
      response = client.broadcast(channels: channels, data: { 'ping' => true })
      responses = response.dig('result', 'responses')
      expect(responses).to be_an(Array).and have_attributes(size: 2)
      responses.each do |r|
        expect(r.dig('result', 'offset')).to be > 0
      end
    end
  end

  describe '#history_remove' do
    it 'empties publication list for a channel' do
      client.publish(channel: channel, data: { 'x' => 1 })
      client.history_remove(channel: channel)
      history_resp = client.history(channel: channel, limit: 10)
      expect(history_resp.dig('result', 'publications') || []).to be_empty
    end
  end

  describe '#presence and #presence_stats' do
    it 'returns empty presence for a channel with no subscribers' do
      # Ensure channel is active by publishing once (publication alone does
      # not create a subscriber, but exercises the channel options).
      client.publish(channel: channel, data: {})
      presence = client.presence(channel: channel)
      expect(presence.dig('result', 'presence')).to eq({})

      stats = client.presence_stats(channel: channel)
      expect(stats.dig('result', 'num_clients')).to eq(0)
      expect(stats.dig('result', 'num_users')).to eq(0)
    end
  end

  describe '#channels' do
    it 'returns a channels map' do
      response = client.channels
      expect(response.dig('result', 'channels')).to be_a(Hash)
    end
  end

  describe '#batch' do
    it 'executes multiple commands and returns replies in order' do
      response = client.batch(commands: [
                                { 'publish'   => { 'channel' => channel, 'data' => { 'n' => 1 } } },
                                { 'publish'   => { 'channel' => channel, 'data' => { 'n' => 2 } } },
                                { 'presence_stats' => { 'channel' => channel } }
                              ])
      # Batch response is shaped `{ "replies": [...] }` with no top-level
      # `result` wrapper, unlike every other API method.
      replies = response['replies']
      expect(replies).to be_an(Array).and have_attributes(size: 3)
      expect(replies[0]).to have_key('publish')
      expect(replies[1]).to have_key('publish')
      expect(replies[2]).to have_key('presence_stats')
    end
  end

  describe 'Centrifugo API error' do
    it 'raises Cent::ResponseError on a top-level error response' do
      expect { client.publish(channel: 'unknown_ns:chat', data: {}) }
        .to raise_error(Cent::ResponseError) do |err|
          expect(err.code).to be_a(Integer)
          expect(err.message).to be_a(String)
        end
    end

    it 'does not raise when a batch sub-reply carries an error' do
      response = client.batch(commands: [
                                { 'publish' => { 'channel' => channel, 'data' => { 'ok' => true } } },
                                { 'publish' => { 'channel' => 'unknown_ns:x', 'data' => {} } }
                              ])
      replies = response['replies']
      expect(replies).to be_an(Array).and have_attributes(size: 2)
      expect(replies[0]).to have_key('publish')
      expect(replies[1]).to have_key('error')
    end
  end

  describe 'invalid API key' do
    it 'raises Cent::UnauthorizedError' do
      bad = described_class.new(api_key: 'definitely-wrong', endpoint: ENV.fetch('CENTRIFUGO_API_URL'))
      expect { bad.info }.to raise_error(Cent::UnauthorizedError)
    end
  end
end
