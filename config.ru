require 'bundler'
Bundler.require
require 'json'

Dotenv.load

require __dir__ + '/lib/fileslide_streamer'

run FileslideStreamer
