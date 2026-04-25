# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cent::Client do
  subject(:client) { described_class.new(api_key: 'api_key') }

  let(:api_endpoint) { 'http://localhost:8000/api' }
  let(:expected_headers) do
    { 'Content-Type' => 'application/json', 'X-API-Key' => 'api_key' }
  end

  def stub_method(method, request_body:, response_body: '{"result":{}}', status: 200)
    stub_request(:post, "#{api_endpoint}/#{method}")
      .with(body: request_body, headers: expected_headers)
      .to_return(status: status, body: response_body, headers: { 'Content-Type' => 'application/json' })
  end

  describe '#publish' do
    it 'posts to /publish with channel and data' do
      stub = stub_method('publish', request_body: { 'channel' => 'chat', 'data' => { 'content' => 'hi' } })
      expect(client.publish(channel: 'chat', data: { content: 'hi' })).to eq('result' => {})
      expect(stub).to have_been_requested
    end

    it 'omits nil kwargs and passes the rest through' do
      stub_method('publish',
                  request_body: {
                    'channel' => 'chat',
                    'data' => { 'x' => 1 },
                    'skip_history' => true,
                    'tags' => { 'k' => 'v' },
                    'idempotency_key' => 'k1',
                    'delta' => true
                  })
      client.publish(channel: 'chat', data: { x: 1 }, skip_history: true,
                     tags: { k: 'v' }, idempotency_key: 'k1', delta: true)
    end
  end

  describe '#broadcast' do
    it 'posts to /broadcast with channels array' do
      stub_method('broadcast',
                  request_body: { 'channels' => %w[a b], 'data' => { 'x' => 1 } })
      client.broadcast(channels: %w[a b], data: { x: 1 })
    end
  end

  describe '#subscribe' do
    it 'posts to /subscribe with user and channel' do
      stub_method('subscribe', request_body: { 'user' => '42', 'channel' => 'chat' })
      client.subscribe(user: '42', channel: 'chat')
    end
  end

  describe '#unsubscribe' do
    it 'posts to /unsubscribe' do
      stub_method('unsubscribe', request_body: { 'user' => '42', 'channel' => 'chat' })
      client.unsubscribe(user: '42', channel: 'chat')
    end
  end

  describe '#disconnect' do
    it 'posts to /disconnect' do
      stub_method('disconnect', request_body: { 'user' => '42' })
      client.disconnect(user: '42')
    end

    it 'supports client, session, whitelist and disconnect object' do
      stub_method('disconnect',
                  request_body: {
                    'user' => '42',
                    'client' => 'c1',
                    'session' => 's1',
                    'whitelist' => %w[c9],
                    'disconnect' => { 'code' => 4000, 'reason' => 'bye' }
                  })
      client.disconnect(user: '42', client: 'c1', session: 's1', whitelist: %w[c9],
                        disconnect: { 'code' => 4000, 'reason' => 'bye' })
    end
  end

  describe '#refresh' do
    it 'posts to /refresh' do
      stub_method('refresh', request_body: { 'user' => '42', 'expired' => true })
      client.refresh(user: '42', expired: true)
    end
  end

  describe '#presence' do
    it 'posts to /presence' do
      stub_method('presence',
                  request_body: { 'channel' => 'chat' },
                  response_body: '{"result":{"presence":{}}}')
      expect(client.presence(channel: 'chat')).to eq('result' => { 'presence' => {} })
    end
  end

  describe '#presence_stats' do
    it 'posts to /presence_stats' do
      stub_method('presence_stats',
                  request_body: { 'channel' => 'chat' },
                  response_body: '{"result":{"num_clients":0,"num_users":0}}')
      expect(client.presence_stats(channel: 'chat')).to eq(
        'result' => { 'num_clients' => 0, 'num_users' => 0 }
      )
    end
  end

  describe '#history' do
    it 'posts to /history with optional limit/since/reverse' do
      stub_method('history',
                  request_body: { 'channel' => 'chat', 'limit' => 10, 'reverse' => true })
      client.history(channel: 'chat', limit: 10, reverse: true)
    end
  end

  describe '#history_remove' do
    it 'posts to /history_remove' do
      stub_method('history_remove', request_body: { 'channel' => 'chat' })
      client.history_remove(channel: 'chat')
    end
  end

  describe '#channels' do
    it 'posts to /channels with optional pattern' do
      stub_method('channels',
                  request_body: { 'pattern' => 'chat:*' },
                  response_body: '{"result":{"channels":{}}}')
      client.channels(pattern: 'chat:*')
    end

    it 'defaults to empty body when no pattern' do
      stub_method('channels', request_body: {}, response_body: '{"result":{"channels":{}}}')
      client.channels
    end
  end

  describe '#info' do
    it 'posts to /info with empty body' do
      stub_method('info', request_body: {}, response_body: '{"result":{"nodes":[]}}')
      expect(client.info).to eq('result' => { 'nodes' => [] })
    end
  end

  describe '#batch' do
    it 'posts to /batch with commands and parallel flag' do
      commands = [
        { 'publish' => { 'channel' => 'a', 'data' => {} } },
        { 'publish' => { 'channel' => 'b', 'data' => {} } }
      ]
      stub_method('batch',
                  request_body: { 'commands' => commands, 'parallel' => true },
                  response_body: '{"replies":[{"publish":{}},{"publish":{}}]}')
      expect(client.batch(commands: commands, parallel: true)).to eq(
        'replies' => [{ 'publish' => {} }, { 'publish' => {} }]
      )
    end
  end

  describe 'API error responses' do
    it 'raises Cent::ResponseError on a top-level error body' do
      stub_method('publish',
                  request_body: { 'channel' => 'x:y', 'data' => {} },
                  response_body: '{"error":{"code":102,"message":"unknown channel"}}')
      expect { client.publish(channel: 'x:y', data: {}) }
        .to raise_error(Cent::ResponseError) do |err|
          expect(err.code).to eq(102)
          expect(err.message).to eq('unknown channel')
        end
    end

    it 'does not raise on per-reply errors inside a batch response' do
      body = '{"replies":[{"publish":{}},{"error":{"code":102,"message":"unknown channel"}}]}'
      stub_method('batch',
                  request_body: { 'commands' => [{ 'publish' => { 'channel' => 'a' } }] },
                  response_body: body)
      expect(client.batch(commands: [{ 'publish' => { 'channel' => 'a' } }])).to eq(
        'replies' => [
          { 'publish' => {} },
          { 'error' => { 'code' => 102, 'message' => 'unknown channel' } }
        ]
      )
    end

    it 'does not raise on per-channel errors inside a broadcast result' do
      body = '{"result":{"responses":[{"result":{"offset":1}},{"error":{"code":102,"message":"unknown channel"}}]}}'
      stub_method('broadcast',
                  request_body: { 'channels' => %w[a b], 'data' => {} },
                  response_body: body)
      response = client.broadcast(channels: %w[a b], data: {})
      expect(response.dig('result', 'responses', 1, 'error', 'code')).to eq(102)
    end
  end

  describe 'transport errors' do
    it 'raises Cent::UnauthorizedError on 401' do
      stub_method('info', request_body: {}, status: 401, response_body: '')
      expect { client.info }.to raise_error(Cent::UnauthorizedError) do |err|
        expect(err.status).to eq(401)
        expect(err).to be_a(Cent::TransportError)
      end
    end

    it 'raises Cent::TransportError on 5xx' do
      stub_method('info', request_body: {}, status: 500, response_body: '')
      expect { client.info }.to raise_error(Cent::TransportError) do |err|
        expect(err.status).to eq(500)
      end
    end

    it 'raises Cent::TimeoutError when the adapter raises Faraday::TimeoutError' do
      stub_request(:post, "#{api_endpoint}/info").to_raise(Faraday::TimeoutError.new('timed out'))
      expect { client.info }.to raise_error(Cent::TimeoutError)
    end

    it 'raises Cent::NetworkError on connection failure' do
      stub_request(:post, "#{api_endpoint}/info").to_raise(Faraday::ConnectionFailed.new('nope'))
      expect { client.info }.to raise_error(Cent::NetworkError)
    end
  end

  describe 'endpoint without trailing slash' do
    it 'still produces /api/<method> URLs' do
      c = described_class.new(api_key: 'api_key', endpoint: 'http://centrifugo.local/api')
      stub_request(:post, 'http://centrifugo.local/api/info')
        .to_return(status: 200, body: '{"result":{"nodes":[]}}',
                   headers: { 'Content-Type' => 'application/json' })
      expect(c.info).to eq('result' => { 'nodes' => [] })
    end
  end
end
