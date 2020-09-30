class FileslideStreamer < Sinatra::Base
  FailedUri = Struct.new(:uri, :response_code, keyword_init: true) do
    def to_s
      "#{uri.to_s} [#{response_code}]\n"
    end
  end


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

    # Do a head request to all the URIs to check they're available.
    # We do a range request the first byte instead of doing a HEAD request
    # because S3 presigned URLs (and possibly other cloud providers too) are
    # only valid for GET.
    availability_checking_http = HTTP.timeout(connect: 5, read: 10).headers("Range" => "bytes=0-0").follow(max_hops: 2)
    failed_uris = []
    seen_files = uri_list.map do |uri|
      begin
        resp = availability_checking_http.get(uri)
        unless [200,206].include? resp.status
          failed_uris << FailedUri.new(uri: uri, response_code: resp.status)
        end
        content_disposition = resp.headers.to_h["Content-Disposition"]
        ZipStreamer::SingleFile.new(original_uri: uri, content_disposition: content_disposition)
      rescue HTTP::ConnectionError
        # Most likely the server we're trying to connect to is offline. In this case we display this URI with
        # a 503 error which means "Service Unavailable".
        failed_uris << FailedUri.new(uri: uri, response_code: HTTP::Response::Status.new(503))
      end
    end
    unless failed_uris.empty?
      halt 502, construct_error_message(failed_uris: failed_uris)
    end

    # Deduplicate filenames if required
    # TODO

    # Pull in the URI contents and stream as zip
    body = ZipStreamer.make_streaming_body(files: seen_files)
    headers = {'Transfer-Encoding' => 'chunked', 'Content-Disposition' => "attachment; filename=\"#{zip_filename}\""}
    [200,headers,body]
  rescue JSON::ParserError, KeyError => e
    halt 400
  rescue UpstreamAPI::UpstreamNotFoundError => e
    halt 500
  end

  def construct_error_message(failed_uris: )
    resp = "502 Bad Gateway\nThe following files could not be fetched:\n"
    failed_uris.each do |f|
      resp << f.to_s
    end
    resp
  end
end
