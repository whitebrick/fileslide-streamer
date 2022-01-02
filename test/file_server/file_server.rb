require 'sinatra'

set :public_folder, "#{File.expand_path(File.dirname(__FILE__))}/files"
set :port, 9293
 
get "/" do
  "FileSlide Streamer Test File Server"
end
