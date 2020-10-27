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

    puts "** params[:file_name]=#{params[:file_name]} params[:uri_list]=#{params[:uri_list]}"
    
    halt 400, 'Request must include non-empty file_name and uri_list parameters' unless (!params[:file_name].nil? && params[:file_name].length>0) && 
      (!params[:uri_list].nil? && params[:uri_list].length>0)

    zip_filename = params[:file_name]
    uri_list = JSON.parse(params[:uri_list].gsub(/\s/,''))

    halt 400, 'Duplicate URIs found' unless uri_list.uniq.length == uri_list.length

    # Check for auth with upstream service
    upstream = UpstreamAPI.new
    verification_result = upstream.verify_uri_list(uri_list: uri_list, file_name: zip_filename)
    halt 403, verification_result[:unauthorized_html] unless verification_result[:authorized]

    puts "** URIs OK: #{uri_list}\n"

    # Do a head request to all the URIs to check they're available.
    # We do a range request the first byte instead of doing a HEAD request
    # because S3 presigned URLs (and possibly other cloud providers too) are
    # only valid for GET.
    availability_checking_http = HTTP.timeout(connect: 5, read: 10).headers("Range" => "bytes=0-0").follow(max_hops: 2)
    failed_uris = []
    zip_streamer = ZipStreamer.new
    uri_list.each do |uri|
      begin
        resp = availability_checking_http.get(uri)
        puts "** availability_checking_http: #{uri} => #{resp.status}\n"
        unless [200,206].include? resp.status
          failed_uris << FailedUri.new(uri: uri, response_code: resp.status)
        end
        content_disposition = resp.headers.to_h["Content-Disposition"]
        zip_streamer << ZipStreamer::SingleFile.new(original_uri: uri, content_disposition: content_disposition)
      rescue HTTP::ConnectionError
        # Most likely the server we're trying to connect to is offline. In this case we display this URI with
        # a 503 error which means "Service Unavailable".
        failed_uris << FailedUri.new(uri: uri, response_code: HTTP::Response::Status.new(503))
      end
    end
    unless failed_uris.empty?
      halt 502, construct_error_message(failed_uris: failed_uris)
    end

    puts "** zip_streamer.files.size: #{zip_streamer.files.size}\n"

    # Deduplicate filenames if required
    zip_streamer.deduplicate_filenames!

    # Pull in the URI contents and stream as zip
    http_body = zip_streamer.make_streaming_body

    puts "** http_body: #{http_body.inspect}\n"

    headers = {
      'Content-Disposition' => "attachment; filename=\"#{zip_filename}\"",
      'X-Accel-Buffering' => 'no', # disable nginx buffering
      'Content-Encoding' => 'none',
      'Content-Type' => 'binary/octet-stream',
    }
    [200,headers,http_body]
  rescue JSON::ParserError, KeyError => e
    halt 400, 'uri_list is not a valid JSON array'
  rescue UpstreamAPI::UpstreamNotFoundError => e
    puts e.backtrace
    halt 500, 'Error connecting to upstream'
  end

  def construct_error_message(failed_uris: )
    resp = "502 Bad Gateway\nThe following files could not be fetched:\n"
    failed_uris.each do |f|
      resp << f.to_s
    end
    puts resp
    resp
  end

  def self.init!
    @@redis_pool = ConnectionPool.new(size: 8, timeout: 5) { Redis.new }
  end

  def self.with_redis
    @@redis_pool.with { |redis| yield(redis) }
  end
end
