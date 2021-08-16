# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cent::Notary do
  describe '.new' do
    context 'with empty secret' do
      it { expect { described_class.new(secret: nil) }.to raise_error(Cent::Error) }
    end
  end

  describe '#issue_connection_token' do
    let(:instance) { described_class.new(secret: 'secret') }

    context 'without expiration' do
      subject(:connection_token) { instance.issue_connection_token(sub: '1') }

      it { expect(connection_token).to match(/^eyJhbGciOiJIUzI1NiJ9.*1853CA$/) }
    end

    context 'with expiration' do
      subject(:connection_token) do
        instance.issue_connection_token(sub: '1', exp: 1_628_877_060, info: { 'foo' => 'bar' })
      end

      it { expect(connection_token).to match(/^eyJhbGciOiJIUzI1NiJ9.*PErWc8$/) }
    end
  end

  describe '#issue_channel_token' do
    let(:instance) { described_class.new(secret: 'secret') }

    context 'with no expiration' do
      subject(:channel_token) do
        instance.issue_channel_token(client: 'client', channel: 'channel', info: { 'foo' => 'bar' })
      end

      it { expect(channel_token).to match(/^eyJhbGciOiJIUzI1NiJ9.*SopvNY$/) }
    end

    context 'with expiration' do
      subject(:channel_token) do
        instance.issue_channel_token(client: 'client', channel: 'channel', info: { 'foo' => 'bar' }, exp: 1_628_877_060)
      end

      it { expect(channel_token).to match(/^eyJhbGciOiJIUzI1NiJ9.*uQCqas$/) }
    end
  end
end
