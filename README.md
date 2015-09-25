# Centrifuge
[![Code Climate](https://codeclimate.com/github/centrifugal/centrifuge-ruby/badges/gpa.svg)](https://codeclimate.com/github/centrifugal/centrifuge-ruby)
[![Build Status](https://travis-ci.org/centrifugal/centrifuge-ruby.svg)](https://travis-ci.org/centrifugal/centrifuge-ruby)

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

Compatible version for Centrifuge version 0.8.0 and above are 0.1.0+. Please use 0.0.x versions for older Centrifuge

## Usage

`Centrifuge::Client` - is main usable class. Start with:

	client = Centrifute::Client.new(scheme: :http, host: :localhost, port: 80, project_key: 'abc', secret: 'cde')

If you are planning to use only one project, its convenient to set all data and use class methods:

	Centrifuge.scheme = :http
	Centrifuge.host = 'localhost'
	Centrifuge.port = 8000
	Centrifuge.project_key = 'abc'
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

### Channel Sign token generation

Generates Sign token for a Channel:

```ruby
	client.generate_channel_sign(params[:client], params[:channels], "{}")
```

Where ```params[:client]``` is client passed during authentication and ```params[:channels]``` is a list or a single channel. You can also add user info as valid json string as third parameter:

```ruby
	client.generate_channel_sign(params[:client], params[:channels], "{"name": "John"}")
```

You can use this in rails like so:

```ruby

	#routes.rb or any router lib
	post 'sockets/auth'

	# Auth method to authenticate private channels
	#sockets_controller.rb or anywhere in your app

	# client = Instance of Centrifuge initialized // check Usage section
	# params[:channels] = single/array of channels
	def auth
	  if current_user
	    data = {}
	    sign = client.generate_channel_sign(
	        params[:client], params[:channels], "{}"
	    )
	    data[channel] = {
	        "sign": sign,
	        "info": "{}"
	    }
	    render :json => data
	  else
	    render :text => "Not authorized", :status => '403'
	  end
	end
```
On client side initialize Centrifuge like so:

``` javascript

	// client_info = valid JSON string of user_info
	// client_token = client.token_for (described above)

	var centrifuge = new Centrifuge({
	   url: "http://localhost:8000/connection",
	   project: "project_name",
	   user: window.currentUser.id,
	   timestamp: window.currentUser.current_timestamp,
	   debug: true,
	   info: JSON.stringify(window.client_info),
	   token: window.client_token,
	   refreshEndpoint: "/sockets/refresh",
	   authEndpoint: "/sockets/auth",
	   authHeaders: {
	      'X-Transaction': 'WebSocket Auth',
	      'X-CSRF-Token': window.currentUser.form_authenticity_token
	   },
	   refreshHeaders: {
	      'X-Transaction': 'WebSocket Auth',
	      'X-CSRF-Token': window.currentUser.form_authenticity_token
	   }
	 });

	centrifuge.connect();

	// If you using jbuiler use raw render(template_name) and use a data-*/window vars attribute and load valid json from there
```

If you want to batch sign channels request, you can use JS client to batch channels ```centrifuge.startBatching();``` and on the server loop through channels and subscribe. You can read more here: [Documentation](https://fzambia.gitbooks.io/centrifugal/content/client/api.html)

## Rails assets

To use Centrifuge js client just add this line to your application.js manifest:

	//= require centrifuge

If you want to use sockjs require it before centrifuge:

	//= require sockjs
	//= require centrifuge

### Other API

Other API methods, like projects and channels management are unavailable now.

## Contributing

1. Fork it ( https://github.com/centrifugal/centrifuge-ruby/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
