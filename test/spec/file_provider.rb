require 'sinatra'

set :public_folder, "#{File.expand_path(File.dirname(__FILE__))}/fixtures"
set :port, 9293
set :logging, false
set :quiet, true
