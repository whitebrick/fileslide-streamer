class FileslideStreamer < Sinatra::Base
  get "/" do
    redirect to('https://fileslide.io')
  end

  get "/healthcheck" do
    "All good\n"
  end

  post "/download" do
    # Parse the request
    request.body.rewind
    request_payload = JSON.parse(request.body.read, symbolize_names: true)
    zip_filename = request_payload.fetch(:file_name)
    uri_list = request_payload.fetch(:uri_list)

    # Check for auth with upstream service
    upstream = UpstreamAPI.new
    verification_result = upstream.verify_uri_list(uri_list: uri_list)
    halt 403, verification_result[:unauthorized_html] unless verification_result[:authorized]

    # Do a head request to all the URIs to check they're available

    # Deduplicate filenames if required


    # Pull in the URI contents and stream as zip
    200
  rescue JSON::ParserError, KeyError => e
    halt 400
  rescue UpstreamAPI::UpstreamNotFoundError => e
    halt 500
  end
end
