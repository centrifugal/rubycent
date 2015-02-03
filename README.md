# Centrifuge
[![Code Climate](https://codeclimate.com/github/arrowcircle/centrifuge-ruby/badges/gpa.svg)](https://codeclimate.com/github/arrowcircle/centrifuge-ruby)
[![Build Status](https://travis-ci.org/arrowcircle/centrifuge-ruby.svg)](https://travis-ci.org/arrowcircle/centrifuge-ruby)

Ruby gem for [Centrifuge](https://github.com/centrifugal/centrifuge) real-time messaging broker

## Installation

Add this line to your application's Gemfile:

```
gem 'centrifuge'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install centrifuge

## Usage

`Centrifuge::Client` - is main usable class. Start with:

	client = Centrifute::Client.new(scheme: :http, host: :localhost, port: 80, project_id: 'abc', secret: 'cde')

If you are planning to use only one project, its convenient to set all data and use class methods:

	Centrifuge.scheme = :http
	Centrifuge.host = 'localhost'
	Centrifuge.port = 8000
	Centrifuge.project_id = 'abc'
	Centrifuge.secret = 'def'

There are five methds available:

### Publish

Sends message to all connected users:

	client.publish('teshchannel', { data: :foo })

You can also use class methods if you set all necessary config data:

	Centrifuge.publish('testchannel', { data: :foo })

### Unsubscribe

Unsubscribes user from channel:

	client.unsubscribe('testchannel', 'user#23')

`user#23` - is string identificator of user.

### Disconnect

Disconnects user from Centrifuge:

	client.disconnect('user#23')

### Presence

Gets presence info of the channel:

	client.presence('testchannel')

### History

Gets message history of the channel:

	client.history('test_channel')

### JS Client token generation

Generates token for JS client:

  client.token_for('testuser', '123123')

Where `123123` is UNIX timestamp. You can also add user info as valid json string as third parameter:

  client.token_for('testuser', '123123', "{}")

### Other API

Other API methods, like projects and channels management are unavailable now.

## Contributing

1. Fork it ( https://github.com/centrifugal/centrifuge-ruby/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
