# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cent::Notary do
  describe '.new' do
    context 'with empty secret' do
      it { expect { described_class.new(secret: nil) }.to raise_error(Cent::Error) }
    end
  end

  describe '#issue_connection_token' do
    subject(:connection_token) { notary.issue_connection_token(sub: '1') }

    let(:notary) { described_class.new(secret: 'secret') }

    context 'without expiration' do
      it { expect(connection_token).to match(/^eyJhbGciOiJIUzI1NiJ9.*uEnHk$/) }
    end

    context 'with expiration' do
      subject(:connection_token) do
        notary.issue_connection_token(sub: '1', exp: 1_628_877_060, info: { 'foo' => 'bar' })
      end

      it { expect(connection_token).to match(/^eyJhbGciOiJIUzI1NiJ9.*PErWc8$/) }
    end

    context 'with RSA key' do
      let(:pem_key) do
        <<~PEM_KEY
          -----BEGIN RSA PRIVATE KEY-----
          MIIEpQIBAAKCAQEAuzo3AZZKBXOKBdNyDSsnrQzzR5gLN/Ps+Bg0pXKxWzKzXR6M
          tkWz3EomOCVG2sN9EhmfJ67y3QccrkKi0LokuNgDcjJA9D7Py3fjduN6mSCG9Ecp
          pSK+xHm6rN3WI7wg8iynWTX31vhpxyz5ILnAU/S8W/QBsFmoA5EWvRa0gFtx3a5M
          RC2ZpNSgkuJiAOVDXJoWVPUWynI3KFEUfEU20Q21clnpGaOdZuEgYMeUUGN1h0d8
          ixnmQ7NUd4NdNjz5U8OaINIi09nwznP21QA+bNUshY9UOB87njVesBf/mqOStjh4
          7bzYQBJFU3t02qRevLakzC/8HyITp8VNZ4AfKwIDAQABAoIBACYeWRqinZl0h5Je
          FWdm9OH/s/xMkWQn7oQocXeJ3WAi92+rC50EnfTox9VAiad6i5lGzCeJL/seOpGk
          EYALlfRoTnNOlfjkXOwhEZegAtLwU2min3D2nP5lhkMxuyp1YAPOYZgBK9+Bng+m
          MWafSvAM8NiL2lgsOM/ZF1cSK1fCbQc132/up9Me6+coBU7Pmq8eFMbLa6tKAb10
          Vo4F9kbxYcDFeCpnxGRL/eC4nuHlvms7GRcjcK4fgGwrDfO364TCxN5phn98vTLw
          /z67YwFs+AO7z2wDK6pUQs9ftkpfeTWgP58IznG9TCEDOw67rYsXuzoqTNMwrqIi
          NRqXsSECgYEA7I7dTJJoAqDn+JssRQAmuHgcXvBTw6qMZeFvy/NQTJpK7rm5v79K
          ZdP0ZGrjYCHEwJb50iaGXFTr4HBN8vqbDbZ9LZpHHCq6eltZJ1Q7pivgZHdVITZS
          Ieb3B1ZaxI5LszIKtnsWiNA3P/wRjpdeckXZGbJAuBAx8Vf8MNyhBzECgYEAyp1x
          YdDZ/UgPIhEAB0SvFpeAdkcjKtH4VN2MAEEJjal7JCeOKot8QTkqM/6D/kJenoK4
          wZWWK7fdcv+aEBneEHBHN7jSfvUJp3UAGZXv8O95LR1KskCpoa2TPKtxVkChP6zT
          RfGiWUnBxkVVXnbenteAHsJqsK46+3uIbj2c7RsCgYEAtAWc3/Li+G0fW5ArRm9x
          CB1P6egWtucJZVcETz9hMoqQz8/DTerzYT7F082ML9JC+xVqFMWApq9xuiF9EJYq
          fWsNJDEuQH873nW6CTYPFsx5Pbuaq2W9Z1NvVsQe20o2za4dfPV7Fq7t/OGFMvB6
          zZfeObHvkqOwfiwpHb4pRWECgYEAvwo+Ws1SjLdB1YwT68Z+FB4bOOqQJRK/RD10
          gNTRzilr+0X0jPbh3JmqykWDbNxlXK3CyHxjkKsXeRO5zs6lC/jhnY99ocknJiZy
          Rq2SBCm3pqsEwBeqGdCQkFbSUVI099XbiwpvWiLqOykqehw4gaqNmfMUJ6zP3ki2
          9cLQUNsCgYEAhtBfAYw2pkqOfm7PFGCWoOi5fQg7EPeTyZnMmWFJDZj4TtE1B0Kz
          FDYdI+MwQFh76WAZN599LShnRP6Hb1SIRxqkeoelFe88hOaquTJAksHfqsIml2Ya
          af2HW4+3cGQbdzakZ4Iy+fIM+timAEZ0dVJKl9/rcMpQeNq4lKDIspQ=
          -----END RSA PRIVATE KEY-----
        PEM_KEY
      end
      let(:secret) { OpenSSL::PKey::RSA.new(pem_key) }
      let(:notary) { described_class.new(secret: secret, algorithm: 'RS256') }

      it { expect(connection_token).to match(/^eyJhbGciOiJSUzI1NiJ9.*$/) }
    end

    context 'with ECDSA key' do
      let(:pem_key) do
        <<~PEM_KEY
          -----BEGIN EC PRIVATE KEY-----
          MHcCAQEEIMotgJBpoUge/YyUSRmR+AwK3Ymh5O8w7vhA56nzWjGYoAoGCCqGSM49
          AwEHoUQDQgAENU4BF7Wxnnmp4JP5bRUYXOz51T7Ot/BC83zbhizsgupPqobhDToi
          4udmmyn0Ltnioiw5rRwA6gDvdx83q6+a+w==
          -----END EC PRIVATE KEY-----
        PEM_KEY
      end
      let(:secret) { OpenSSL::PKey::EC.new(pem_key) }
      let(:notary) { described_class.new(secret: secret, algorithm: 'ES256') }

      it { expect(connection_token).to match(/^eyJhbGciOiJFUzI1NiJ9.*$/) }
    end
  end

  describe '#issue_channel_token' do
    subject(:channel_token) do
      notary.issue_channel_token(sub: '1', channel: 'channel', info: { 'foo' => 'bar' })
    end

    let(:notary) { described_class.new(secret: 'secret') }

    context 'with no expiration' do
      it { expect(channel_token).to match(/^eyJhbGciOiJIUzI1NiJ9.*50TnzY$/) }
    end

    context 'with expiration' do
      subject(:channel_token) do
        notary.issue_channel_token(sub: '1', channel: 'channel', info: { 'foo' => 'bar' }, exp: 1_628_877_060)
      end

      it { expect(channel_token).to match(/^eyJhbGciOiJIUzI1NiJ9.*yht5hk$/) }
    end

    context 'with RSA key' do
      let(:pem_key) do
        <<~PEM_KEY
          -----BEGIN RSA PRIVATE KEY-----
          MIIEpQIBAAKCAQEAuzo3AZZKBXOKBdNyDSsnrQzzR5gLN/Ps+Bg0pXKxWzKzXR6M
          tkWz3EomOCVG2sN9EhmfJ67y3QccrkKi0LokuNgDcjJA9D7Py3fjduN6mSCG9Ecp
          pSK+xHm6rN3WI7wg8iynWTX31vhpxyz5ILnAU/S8W/QBsFmoA5EWvRa0gFtx3a5M
          RC2ZpNSgkuJiAOVDXJoWVPUWynI3KFEUfEU20Q21clnpGaOdZuEgYMeUUGN1h0d8
          ixnmQ7NUd4NdNjz5U8OaINIi09nwznP21QA+bNUshY9UOB87njVesBf/mqOStjh4
          7bzYQBJFU3t02qRevLakzC/8HyITp8VNZ4AfKwIDAQABAoIBACYeWRqinZl0h5Je
          FWdm9OH/s/xMkWQn7oQocXeJ3WAi92+rC50EnfTox9VAiad6i5lGzCeJL/seOpGk
          EYALlfRoTnNOlfjkXOwhEZegAtLwU2min3D2nP5lhkMxuyp1YAPOYZgBK9+Bng+m
          MWafSvAM8NiL2lgsOM/ZF1cSK1fCbQc132/up9Me6+coBU7Pmq8eFMbLa6tKAb10
          Vo4F9kbxYcDFeCpnxGRL/eC4nuHlvms7GRcjcK4fgGwrDfO364TCxN5phn98vTLw
          /z67YwFs+AO7z2wDK6pUQs9ftkpfeTWgP58IznG9TCEDOw67rYsXuzoqTNMwrqIi
          NRqXsSECgYEA7I7dTJJoAqDn+JssRQAmuHgcXvBTw6qMZeFvy/NQTJpK7rm5v79K
          ZdP0ZGrjYCHEwJb50iaGXFTr4HBN8vqbDbZ9LZpHHCq6eltZJ1Q7pivgZHdVITZS
          Ieb3B1ZaxI5LszIKtnsWiNA3P/wRjpdeckXZGbJAuBAx8Vf8MNyhBzECgYEAyp1x
          YdDZ/UgPIhEAB0SvFpeAdkcjKtH4VN2MAEEJjal7JCeOKot8QTkqM/6D/kJenoK4
          wZWWK7fdcv+aEBneEHBHN7jSfvUJp3UAGZXv8O95LR1KskCpoa2TPKtxVkChP6zT
          RfGiWUnBxkVVXnbenteAHsJqsK46+3uIbj2c7RsCgYEAtAWc3/Li+G0fW5ArRm9x
          CB1P6egWtucJZVcETz9hMoqQz8/DTerzYT7F082ML9JC+xVqFMWApq9xuiF9EJYq
          fWsNJDEuQH873nW6CTYPFsx5Pbuaq2W9Z1NvVsQe20o2za4dfPV7Fq7t/OGFMvB6
          zZfeObHvkqOwfiwpHb4pRWECgYEAvwo+Ws1SjLdB1YwT68Z+FB4bOOqQJRK/RD10
          gNTRzilr+0X0jPbh3JmqykWDbNxlXK3CyHxjkKsXeRO5zs6lC/jhnY99ocknJiZy
          Rq2SBCm3pqsEwBeqGdCQkFbSUVI099XbiwpvWiLqOykqehw4gaqNmfMUJ6zP3ki2
          9cLQUNsCgYEAhtBfAYw2pkqOfm7PFGCWoOi5fQg7EPeTyZnMmWFJDZj4TtE1B0Kz
          FDYdI+MwQFh76WAZN599LShnRP6Hb1SIRxqkeoelFe88hOaquTJAksHfqsIml2Ya
          af2HW4+3cGQbdzakZ4Iy+fIM+timAEZ0dVJKl9/rcMpQeNq4lKDIspQ=
          -----END RSA PRIVATE KEY-----
        PEM_KEY
      end
      let(:secret) { OpenSSL::PKey::RSA.new(pem_key) }
      let(:notary) { described_class.new(secret: secret, algorithm: 'RS256') }

      it { expect(channel_token).to match(/^eyJhbGciOiJSUzI1NiJ9.*$/) }
    end

    context 'with ECDSA key' do
      let(:pem_key) do
        <<~PEM_KEY
          -----BEGIN EC PRIVATE KEY-----
          MHcCAQEEIMotgJBpoUge/YyUSRmR+AwK3Ymh5O8w7vhA56nzWjGYoAoGCCqGSM49
          AwEHoUQDQgAENU4BF7Wxnnmp4JP5bRUYXOz51T7Ot/BC83zbhizsgupPqobhDToi
          4udmmyn0Ltnioiw5rRwA6gDvdx83q6+a+w==
          -----END EC PRIVATE KEY-----
        PEM_KEY
      end
      let(:secret) { OpenSSL::PKey::EC.new(pem_key) }
      let(:notary) { described_class.new(secret: secret, algorithm: 'ES256') }

      it { expect(channel_token).to match(/^eyJhbGciOiJFUzI1NiJ9.*$/) }
    end
  end
end
