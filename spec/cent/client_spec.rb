# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cent::Client do
  let(:channel) { 'chat' }
  let(:expected_body) { '{}' }
  let(:client) { described_class.new(api_key: 'api_key') }

  before do
    request_headers = {
      'Content-Type' => 'application/json',
      'Authorization' => 'apikey api_key'
    }
    response_headers = { 'Content-Type' => 'application/json' }
    stub_request(:post, 'http://localhost:8000/api')
      .with(body: params, headers: request_headers)
      .to_return(status: 200, body: expected_body, headers: response_headers)
  end

  describe 'error handling' do
    subject(:response) { client.history(channel: channel) }

    let(:expected_body) { '{"error": { "code": 108, "message": "not available"}}' }
    let(:data) { { content: 'wat' } }
    let(:params) do
      {
        method: 'history',
        params: { channel: channel }
      }
    end

    it do
      expect { response }
        .to raise_exception(
          an_instance_of(Cent::ResponseError).and(have_attributes(code: 108, message: 'not available'))
        )
    end
  end

  describe '#publish' do
    subject(:response) { client.publish(channel: channel, data: data) }

    let(:data) { { content: 'wat' } }

    let(:params) do
      {
        method: 'publish',
        params: { channel: channel, data: data }
      }
    end

    it { is_expected.to eq({}) }
  end

  describe '#broadcast' do
    subject(:response) { client.broadcast(channels: [channel], data: data) }

    let(:data) { { content: 'wat' } }

    let(:params) do
      {
        method: 'broadcast',
        params: { channels: [channel], data: data }
      }
    end

    it { is_expected.to eq({}) }
  end

  describe '#unsubscribe' do
    subject(:response) { client.unsubscribe(channel: channel, user: 1) }

    let(:params) do
      {
        method: 'unsubscribe',
        params: { channel: channel, user: 1 }
      }
    end

    it { is_expected.to eq({}) }
  end

  describe '#disconnect' do
    subject(:response) { client.disconnect(user: 1) }

    let(:params) do
      {
        method: 'disconnect',
        params: { user: 1 }
      }
    end

    it { is_expected.to eq({}) }
  end

  describe 'presence' do
    let(:expected_body) do
      '{
    "result": {
      "presence": {
        "c54313b2-0442-499a-a70c-051f8588020f": {
          "client": "c54313b2-0442-499a-a70c-051f8588020f",
          "user": "42"
        }
      }
    }
  }'
    end

    describe '#presence' do
      subject(:response) { client.presence(channel: channel) }

      let(:params) do
        {
          method: 'presence',
          params: { channel: channel }
        }
      end

      it 'returns hash with channel presence information' do
        expected_hash = {
          'result' => {
            'presence' => {
              'c54313b2-0442-499a-a70c-051f8588020f' => {
                'client' => 'c54313b2-0442-499a-a70c-051f8588020f',
                'user' => '42'
              }
            }
          }
        }

        expect(response).to eq(expected_hash)
      end
    end
  end

  describe 'presence_stats' do
    let(:expected_body) do
      '{
    "result": {
      "num_clients": 0,
      "num_users": 0
    }
  }'
    end

    describe '#presence_stats' do
      subject(:response) { client.presence_stats(channel: channel) }

      let(:params) do
        {
          method: 'presence_stats',
          params: { channel: channel }
        }
      end

      it 'returns hash with channel presence_stats information' do
        expected_hash = {
          'result' => {
            'num_clients' => 0,
            'num_users' => 0
          }
        }

        expect(response).to eq(expected_hash)
      end
    end
  end

  describe 'history' do
    let(:expected_body) do
      '{
    "result": {
      "publications": [
        {
          "data": {
            "text": "hello"
          },
          "uid": "BWcn14OTBrqUhTXyjNg0fg"
        }
      ]
    }
  }'
    end

    describe '#history' do
      subject(:response) { client.history(channel: channel) }

      let(:params) do
        {
          method: 'history',
          params: { channel: channel }
        }
      end

      it 'returns channel history information' do
        expected_hash = {
          'result' => {
            'publications' => [
              {
                'data' => {
                  'text' => 'hello'
                },
                'uid' => 'BWcn14OTBrqUhTXyjNg0fg'
              }
            ]
          }
        }

        expect(response).to eq(expected_hash)
      end
    end
  end

  describe 'channels' do
    let(:expected_body) do
      '{
      "result": {
        "channels": [
          "chat"
        ]
      }
   }'
    end

    describe '#channels' do
      subject(:response) { client.channels }

      let(:params) do
        {
          method: 'channels',
          params: {}
        }
      end

      it 'returns channel history information' do
        expected_hash = {
          'result' => {
            'channels' => [
              'chat'
            ]
          }
        }

        expect(response).to eq(expected_hash)
      end
    end
  end

  describe 'info' do
    let(:expected_body) do
      '{
    "result": {
      "nodes": [
        {
          "name": "Alexanders-MacBook-Pro.local_8000",
          "num_channels": 0,
          "num_clients": 0,
          "num_users": 0,
          "uid": "f844a2ed-5edf-4815-b83c-271974003db9",
          "uptime": 0,
          "version": ""
        }
      ]
    }
  }'
    end

    describe '#info' do
      subject(:response) { client.info }

      let(:params) do
        {
          method: 'info',
          params: {}
        }
      end

      let(:expectation) do
        {
          'result' => {
            'nodes' => [
              {
                'name' => 'Alexanders-MacBook-Pro.local_8000',
                'num_channels' => 0,
                'num_clients' => 0,
                'num_users' => 0,
                'uid' => 'f844a2ed-5edf-4815-b83c-271974003db9',
                'uptime' => 0,
                'version' => ''
              }
            ]
          }
        }
      end

      it 'returns channel history information' do
        expect(response).to eq(expectation)
      end
    end
  end
end
