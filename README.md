# Cent
[![Code Climate](https://codeclimate.com/github/centrifugal/centrifuge-ruby/badges/gpa.svg)](https://codeclimate.com/github/centrifugal/centrifuge-ruby)
![Build Status](https://github.com/centrifugal/rubycent/actions/workflows/main.yml/badge.svg)

[Centrifugo HTTP API v2](https://centrifugal.github.io/centrifugo/server/http_api/) client in Ruby.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'cent' 
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install cent

## Usage

Functionality is split between two classes:
 - `Cent::Client` to call API methods
 - `Cent::Notary` to generate tokens

### Token Generation

```ruby
notary = Cent::Notary.new(secret: 'secret')
```

By default it uses HS256 to generate tokens, but you can set it to one of the HMAC, RSA or ECDSA family. 

#### RSA

```ruby
secret = OpenSSL::PKey::RSA.new(File.read('./rsa_secret.pem'))
notary = Cent::Notary.new(secret: secret, algorithm: 'RS256')
```

#### ECDSA

```ruby
secret = OpenSSL::PKey::EC.new(File.read('./ecdsa_secret.pem'))
notary = Cent::Notary.new(secret: secret, algorithm: 'ES256')
```

#### Connection token

When connecting to Centrifugo client [must provide connection JWT token](https://centrifugal.github.io/centrifugo/server/authentication/) with several predefined credential claims.

```ruby
notary.issue_connection_token(sub: '42') 

#=> "eyJhbGciOiJIUzI1NiJ9..."
```

`info` and `exp` are supported as well: 

```ruby
notary.issue_connection_token(sub: '42', info: { scope: 'admin' }, exp: 1629050099) 

#=> "eyJhbGciOiJIUzI1NiJ9..."
```

### Private channel token

All channels starting with $ considered private and require a **channel token** to subscribe. 
Private channel subscription token is also JWT([see the claims](https://centrifugal.github.io/centrifugo/server/private_channels/))

```ruby
notary.issue_channel_token(client: 'client', channel: 'channel', exp: 1629050099, info: { scope: 'admin' }) 

#=> "eyJhbGciOiJIUzI1NiJ9..."
```
 
### API Client

A client requires your Centrifugo API key to execute all requests.

```ruby
client = Cent::Client.new(api_key: 'key')
```

you can customize your connection as you wish, just remember it's a [Faraday::Connection](https://lostisland.github.io/faraday/usage/#customizing-faradayconnection) instance:

```ruby
client = Cent::Client.new(api_key: 'key', endpoint: 'https://centrifu.go/api') do |connection|
  connection.headers['User-Agent'] = 'Centrifugo Ruby Client'
  connection.options.open_timeout = 3
  connection.options.timeout = 7
  connection.adapter :typhoeus
end
```

#### Publish

Send data to the channel.

[https://centrifugal.github.io/centrifugo/server/http_api/#publish](https://centrifugal.github.io/centrifugo/server/http_api/#publish)

```ruby
client.publish(channel: 'chat', data: 'hello') # => {}
```

#### Broadcast

Sends data to multiple channels.

[https://centrifugal.github.io/centrifugo/server/http_api/#broadcast](https://centrifugal.github.io/centrifugo/server/http_api/#broadcast)

```ruby
client.broadcast(channels: ["clients", "staff"], data: 'hello') # => {}
```

#### Unsubscribe

Unsubscribe user from channel. Receives to arguments: channel and user (user ID you want to unsubscribe)

[https://centrifugal.github.io/centrifugo/server/http_api/#unsubscribe](https://centrifugal.github.io/centrifugo/server/http_api/#unsubscribe)

```ruby
client.unsubscribe(channel: 'chat', user: '1') # => {}
```

#### Disconnect

Allows to disconnect user by it's ID. Receives user ID as an argument.

[https://centrifugal.github.io/centrifugo/server/http_api/#disconnect](https://centrifugal.github.io/centrifugo/server/http_api/#disconnect)

```ruby
# Disconnect user with `id = 1`
# 
client.disconnect(user: '1') # => {}
```

#### Presence

Get channel presence information(all clients currently subscribed on this channel).

[https://centrifugal.github.io/centrifugo/server/http_api/#presence](https://centrifugal.github.io/centrifugo/server/http_api/#presence)

```ruby
client.presence(channel: 'chat') 

# {
#   'result' => {
#     'presence' => {
#       'c54313b2-0442-499a-a70c-051f8588020f' => {
#         'client' => 'c54313b2-0442-499a-a70c-051f8588020f',
#         'user' => '42'
#       },
#       'adad13b1-0442-499a-a70c-051f858802da' => {
#         'client' => 'adad13b1-0442-499a-a70c-051f858802da',
#         'user' => '42'
#       }
#     }
#   }
# }
``` 

#### Presence stats

Get short channel presence information.

[https://centrifugal.github.io/centrifugo/server/http_api/#presence_stats](https://centrifugal.github.io/centrifugo/server/http_api/#precence_stats)

```ruby
client.presence_stats(channel: 'chat')

# {
#   "result" => {
#     "num_clients" => 0,
#     "num_users" => 0
#   }
# }
```

#### History

Get channel history information (list of last messages published into channel).

[https://centrifugal.github.io/centrifugo/server/http_api/#history](https://centrifugal.github.io/centrifugo/server/http_api/#hisotry)

```ruby
client.history(channel: 'chat') 

# {
#   'result' => {
#     'publications' => [
#       {
#         'data' => {
#           'text' => 'hello'
#         }
#       },
#       {
#         'data' => {
#           'text' => 'hi!'
#         }
#       }
#     ]
#   }
# }
```

#### Channels

Get list of active(with one or more subscribers) channels.

[https://centrifugal.github.io/centrifugo/server/http_api/#channels](https://centrifugal.github.io/centrifugo/server/http_api/#channels)

```ruby
client.channels

# {
#   'result' => {
#     'channels' => [
#       'chat'
#     ]
#   }
# }
```

#### Info

Get running Centrifugo nodes information.

[https://centrifugal.github.io/centrifugo/server/http_api/#info](https://centrifugal.github.io/centrifugo/server/http_api/#info)

```ruby
client.info

# {
#   'result' => {
#     'nodes' => [
#       {
#         'name' => 'Alexanders-MacBook-Pro.local_8000',
#         'num_channels' => 0,
#         'num_clients' => 0,
#         'num_users' => 0,
#         'uid' => 'f844a2ed-5edf-4815-b83c-271974003db9',
#         'uptime' => 0,
#         'version' => ''
#       }
#     ]
#   }
# }
```

### Errors

Network errors are not wrapped and will raise `Faraday::ClientError`.

In cases when Centrifugo returns 200 with `error` key in the body we wrap it and return custom error:

```ruby
# Raised when response from Centrifugo contains any error as result of API command execution.
#
begin
  client.publish(channel: 'channel', data: { foo: :bar })
rescue Cent::ResponseError => ex
  ex.message # => "Invalid format"
end
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/centrifugal/rubycent. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
