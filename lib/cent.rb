# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "zlib"

# Ruby SDK for Centrifugo's HTTP server API:
#
#   client = Cent::Client.new(api_endpoint: "http://localhost:8000/api", api_key: ENV.fetch("CENTRIFUGO_API_KEY"))
#   client.publish(channel: "news", data: { text: "hello" })
#
# See https://github.com/centrifugal/rubycent for the documentation.
module Cent
end

require_relative "cent/version"
require_relative "cent/errors"
require_relative "cent/payload"
require_relative "cent/wire"
require_relative "cent/http"
require_relative "cent/generated/types"
require_relative "cent/generated/methods"
require_relative "cent/reply"
require_relative "cent/broadcast"
require_relative "cent/retry"
require_relative "cent/batch"
require_relative "cent/command"
require_relative "cent/auto_batch"
require_relative "cent/client"
require_relative "cent/handler"
require_relative "cent/token"
require_relative "cent/shared_poll"
require_relative "cent/endpoints"
require_relative "cent/generated/proxy_types"
require_relative "cent/proxy"
