require 'bundler'
Bundler.require

require 'rack/test'
require_relative('../lib/fileslide_streamer.rb')

RSpec.configure do |config|
  config.include Rack::Test::Methods
  config.color = true
  config.order = :random
end
