require 'bundler'
Bundler.require
Dotenv.load

require 'rack/test'
require_relative('../lib/fileslide_streamer.rb')
require_relative('../lib/upstream_api.rb')
require_relative('../lib/zip_streamer.rb')

RSpec.configure do |config|
  config.include Rack::Test::Methods
  config.color = true
  config.order = :random
end
