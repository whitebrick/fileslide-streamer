require 'bundler'
Bundler.require

Dotenv.load

require __dir__ + '/lib/fileslide_streamer'

run FileslideStreamer
