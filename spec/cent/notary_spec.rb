# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cent::Notary do
  let(:secret) { 'secret' }
  let(:notary) { described_class.new(secret: secret) }

  def decode(token, key = secret, algo = 'HS256')
    JWT.decode(token, key, true, algorithm: algo, verify_expiration: false).first
  end

  describe '.new' do
    it 'raises when secret is nil' do
      expect { described_class.new(secret: nil) }.to raise_error(Cent::Error)
    end
  end

  describe '#issue_connection_token' do
    it 'includes only sub when only sub is passed' do
      payload = decode(notary.issue_connection_token(sub: '42'))
      expect(payload).to eq('sub' => '42')
    end

    it 'includes all supported claims when provided' do
      token = notary.issue_connection_token(
        sub: '42', exp: 100, iat: 90, jti: 'id1', aud: 'cent', iss: 'app',
        info: { 'scope' => 'admin' }, b64info: 'YmFy',
        channels: %w[a b], subs: { 'c' => { 'data' => {} } },
        meta: { 'internal' => true }, expire_at: 200
      )
      payload = decode(token)
      expect(payload).to eq(
        'sub' => '42',
        'exp' => 100,
        'iat' => 90,
        'jti' => 'id1',
        'aud' => 'cent',
        'iss' => 'app',
        'info' => { 'scope' => 'admin' },
        'b64info' => 'YmFy',
        'channels' => %w[a b],
        'subs' => { 'c' => { 'data' => {} } },
        'meta' => { 'internal' => true },
        'expire_at' => 200
      )
    end

    it 'supports RSA keys' do
      rsa = OpenSSL::PKey::RSA.new(2048)
      token = described_class.new(secret: rsa, algorithm: 'RS256')
                             .issue_connection_token(sub: '1')
      expect(decode(token, rsa.public_key, 'RS256')).to eq('sub' => '1')
    end

    it 'supports ECDSA keys' do
      ec = OpenSSL::PKey::EC.generate('prime256v1')
      token = described_class.new(secret: ec, algorithm: 'ES256')
                             .issue_connection_token(sub: '1')
      expect(decode(token, ec, 'ES256')).to eq('sub' => '1')
    end
  end

  describe '#issue_channel_token' do
    it 'includes sub and channel by default' do
      payload = decode(notary.issue_channel_token(sub: '42', channel: 'chat'))
      expect(payload).to eq('sub' => '42', 'channel' => 'chat')
    end

    it 'includes all supported claims when provided' do
      token = notary.issue_channel_token(
        sub: '42', channel: 'chat', exp: 100, iat: 90, jti: 'id1', aud: 'cent',
        iss: 'app', info: { 'role' => 'writer' }, b64info: 'YmFy',
        override: { 'presence' => { 'value' => true } }, expire_at: 200
      )
      payload = decode(token)
      expect(payload).to eq(
        'sub' => '42',
        'channel' => 'chat',
        'exp' => 100,
        'iat' => 90,
        'jti' => 'id1',
        'aud' => 'cent',
        'iss' => 'app',
        'info' => { 'role' => 'writer' },
        'b64info' => 'YmFy',
        'override' => { 'presence' => { 'value' => true } },
        'expire_at' => 200
      )
    end
  end
end
