# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cent do
  it 'has a version number' do
    expect(Cent::VERSION).not_to be_nil
  end

  describe 'Cent::Client' do
    it 'yields the Faraday connection for customization' do
      yielded = nil
      Cent::Client.new(api_key: 'k') do |conn|
        yielded = conn
        conn.headers['User-Agent'] = 'test-agent'
      end
      expect(yielded).to be_a(Faraday::Connection)
      expect(yielded.headers['User-Agent']).to eq('test-agent')
    end
  end
end
