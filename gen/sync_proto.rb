# frozen_string_literal: true

# Copies api.proto and proxy.proto from a released Centrifugo tag, then
# regenerates the code:
#
#   CENTRIFUGO_REF=v6.10.2 bundle exec rake proto:sync
#
# There is no default ref, so that nothing is synced from an unreleased branch
# by accident.

require "net/http"

ref = ENV.fetch("CENTRIFUGO_REF", "")
abort "set CENTRIFUGO_REF to a Centrifugo tag, e.g. CENTRIFUGO_REF=v6.10.2 bundle exec rake proto:sync" if ref.empty?

root = File.expand_path("..", __dir__)
base = "https://raw.githubusercontent.com/centrifugal/centrifugo/#{ref}/internal"
files = {
  "api.proto" => ["#{base}/apiproto/api.proto", "service CentrifugoApi"],
  "proxy.proto" => ["#{base}/proxyproto/proxy.proto", "service CentrifugoProxy"]
}
got = files.to_h do |name, (url, marker)|
  res = Net::HTTP.get_response(URI(url))
  abort "no #{name} at Centrifugo #{ref}" unless res.is_a?(Net::HTTPSuccess)
  abort "not Centrifugo's #{name}" unless res.body.match?(/^#{Regexp.escape(marker)}\b/)

  [name, res.body]
end
got.each { |name, text| File.write(File.join(root, "proto", name), text) }
system(RbConfig.ruby, File.join(__dir__, "generate.rb"), exception: true)
