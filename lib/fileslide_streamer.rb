class FileslideStreamer < Sinatra::Base
  UPSTREAM_API_LOCATION = ENV.fetch("UPSTREAM_API_LOCATION")


  get "/" do
    redirect to('https://fileslide.io')
  end

  get "/healthcheck" do
    "All good\n"
  end

  post "/download" do
    request.body.rewind
    request_payload = JSON.parse(request.body.read, symbolize_keys: true)
    zip_filename = request_payload.fetch(:file_name)
    uri_list = request_payload.fetch(:uri_list)

    200
  rescue JSON::ParserError
    halt 400
  end
end
