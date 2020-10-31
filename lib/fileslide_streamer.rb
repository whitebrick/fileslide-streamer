require 'securerandom'

class FileslideStreamer < Sinatra::Base
  DOWNLOAD_EXPIRATION_LIMIT_SECONDS = 7 * 24 * 60 * 60 # one week in seconds

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
    puts "** params[:file_name]=#{params[:file_name]} params[:uri_list]=#{params[:uri_list]}"
    # Parse the request and do some initial filtering for badly formatted requests:
    halt 400, 'Request must include non-empty file_name and uri_list parameters' unless (!params[:file_name].nil? && params[:file_name].length>0) &&
      (!params[:uri_list].nil? && params[:uri_list].length>0)

    zip_filename = params[:file_name]
    uri_list = JSON.parse(params[:uri_list].gsub(/\s/,''))

    halt 400, 'Duplicate URIs found' unless uri_list.uniq.length == uri_list.length

    unique_key = SecureRandom.uuid
    FileslideStreamer.with_redis do |redis|
      redis.set(unique_key, {file_name: zip_filename, uri_list: uri_list}.to_json, ex: DOWNLOAD_EXPIRATION_LIMIT_SECONDS)
    end

    # using the 303 status code forces the browser to change the method to GET.
    redirect to("/stream/#{unique_key}"), 303
  rescue JSON::ParserError, KeyError => e
    halt 400, 'uri_list is not a valid JSON array'
  end

  get "/stream/:uk" do
    stored_params = FileslideStreamer.with_redis do |redis|
      redis.get(params[:uk])
    end

    halt 404, "This download is unavailable or has expired" if stored_params.nil?

    decoded_params = JSON.parse(stored_params, symbolize_names: true)
    zip_filename = decoded_params[:file_name]
    uri_list = decoded_params[:uri_list]
    
    ranged_request = !request.env['HTTP_RANGE'].nil?
    range_start, range_stop = if ranged_request
      halt 400, 'Invalid Range header' unless request.env['HTTP_RANGE'].start_with? 'bytes='
      halt 416, 'Multipart ranges are not supported' if request.env['HTTP_RANGE'].include? ','
      byte_range_requested = request.env['HTTP_RANGE'][6..-1] # drop 'bytes=' prefix
      byte_range_requested.split('-').map(&:to_i)
    else
      [0, 0]
    end

    if ranged_request
      if range_stop.nil?
        # It is possible that this request was of shape "Range: bytes=123-", meaning
        # that they want all bytes from 123 until EOF. In that case we set it to a negative number to
        # indicate that it needs to be updated to the total zip size
        if request.env['HTTP_RANGE'][-1] == '-'
          range_stop = -1
        else
          halt 416, 'Range could not be parsed correctly'
        end
      elsif range_stop < range_start
        # See https://tools.ietf.org/html/rfc2616#section-14.35, we must ignore this Range header
        ranged_request = false
      end
    end

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
          next
        end
        headers = resp.headers.to_h
        content_disposition = headers['Content-Disposition']
        total_size = headers['Content-Range'].split('/')[1].to_i
        etag = headers['ETag']
        zip_streamer << ZipStreamer::SingleFile.new(original_uri: uri, content_disposition: content_disposition, size: total_size, etag: etag)
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
    # Compute size of complete zip. This is required even for ranged requests.
    total_size = zip_streamer.compute_total_size!

    headers = {
      'Accept-Ranges' => 'bytes',
      'Content-Disposition' => "attachment; filename=\"#{zip_filename}\"",
      'X-Accel-Buffering' => 'no', # disable nginx buffering
      'Content-Encoding' => 'none',
      'Content-Type' => 'binary/octet-stream',
    }

    halt 416, 'Start of range outside zip size' if range_start >= total_size

    # Create the body and any additional headers if required
    http_body = nil
    if ranged_request
      if range_stop >= total_size || range_stop < 0
        # straight from the HTTP RFC.
        range_stop = total_size - 1
      end
      headers.merge!({
        'Content-Range'  => "bytes #{range_start}-#{range_stop}/#{total_size}",
        'Content-Length' => (1+range_stop-range_start).to_s
      })
      http_body = zip_streamer.make_partial_streaming_body(start: range_start, stop: range_stop)
    else
      headers.merge!({
        'Content-Length' => total_size.to_s
      })
      http_body = zip_streamer.make_complete_streaming_body
    end

    puts "** http_body: #{http_body.inspect}\n"
    response_code = ranged_request ? 206 : 200
    [response_code,headers,http_body]

  rescue UpstreamAPI::UpstreamNotFoundError => e
    halt 500, 'Error connecting to upstream'
  rescue ZipStreamer::ChecksummingError => e
    puts e.backtrace
    halt 500, 'Error occurred during checksum computation'
  rescue Exception => e
    p e
    puts e.backtrace
    raise e
  end

  def construct_error_message(failed_uris: )
    resp = "502 Bad Gateway\nThe following files could not be fetched:\n"
    failed_uris.each do |f|
      resp << f.to_s
    end
    resp
  end

  def self.init!
    @@redis_pool = ConnectionPool.new(size: 8, timeout: 5) { Redis.new }
  end

  def self.with_redis
    @@redis_pool.with { |redis| yield(redis) }
  end
end
