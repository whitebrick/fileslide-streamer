require 'sinatra'

set :port, 9294
 
get "/" do
  "FileSlide Streamer Test Upstream Server"
end

post "/authorize" do
  puts '==== authorize ===='
  content_type :json
  json_body = JSON.parse(request.body.read, symbolize_names: true)
  if json_body.has_key?(:fs_uri_list) && json_body[:fs_uri_list].is_a?(Array)
    json_body[:fs_uri_list].each do |uri_str|
      puts "Checking URI: #{uri_str}"
    end
  end
  authorized = true
  {authorized: authorized}.to_json
end

post "/report" do
  puts '==== report ===='
  content_type :json
  json_body = JSON.parse(request.body.read, symbolize_names: true)
  puts "Report: #{json_body}"
end
