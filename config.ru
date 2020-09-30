require 'bundler'
Bundler.require
require 'json'

Dotenv.load

require __dir__ + '/lib/fileslide_streamer'
require __dir__ + '/lib/upstream_api'
require __dir__ + '/lib/filename_utils'

run FileslideStreamer
