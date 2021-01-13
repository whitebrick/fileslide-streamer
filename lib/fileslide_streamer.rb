require 'securerandom'

class FileslideStreamer < Sinatra::Base
  DOWNLOAD_EXPIRATION_LIMIT_SECONDS = 7 * 24 * 60 * 60 # one week in seconds
  DEFAULT_FILE_NAME = 'download.zip'
  CLIENT_HEADER_START_WITH = 'fs_add_header-'
  EXCLUDED_HEADERS = [
    'Host',
    'Date',
    'Range',
    'Transfer-Encoding',
    'Accept-Ranges',
    'Content-Disposition',
    'X-Accel-Buffering',
    'Content-Encoding',
    'SCRIPT_NAME',
    'QUERY_STRING',
    'SERVER_PROTOCOL',
    'SERVER_SOFTWARE',
    'GATEWAY_INTERFACE',
    'REQUEST_METHOD',
    'REQUEST_PATH',
    'REQUEST_URI',
    'HTTP_VERSION',
    'HTTP_HOST',
    'HTTP_CONNECTION',
    'HTTP_CACHE_CONTROL',
    'HTTP_USER_AGENT',
    'HTTP_POSTMAN_TOKEN',
    'HTTP_ACCEPT',
    'HTTP_SEC_FETCH_SITE',
    'HTTP_SEC_FETCH_MODE',
    'HTTP_SEC_FETCH_DEST',
    'HTTP_ACCEPT_ENCODING',
    'HTTP_ACCEPT_LANGUAGE',
    'SERVER_NAME',
    'SERVER_PORT',
    'PATH_INFO',
    'REMOTE_ADDR',
    "rack.version",
    "rack.errors",
    "rack.multithread",
    "rack.multiprocess",
    "rack.run_once",
    "puma.socket",
    "rack.hijack?",
    "rack.hijack",
    "rack.input",
    "rack.url_scheme",
    "rack.after_reply",
    "puma.config",
    "sinatra.commonlogger",
    "rack.tempfiles",
    "rack.logger",
    "rack.request.query_string",
    "rack.request.query_hash",
    "sinatra.route",
    'HTTP_RANGE'
  ]
  
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

  get '/clear_test_records' do
    FileslideStreamer.with_redis do |redis|
      redis.keys.each do |key|
        if key.start_with?("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee")
          stored_params = JSON.parse(redis.get(key))
          (stored_params['uri_list'] || []).each do |uri|
            redis.del(uri)
          end
          redis.del(key)
        end
      end
    end
    "Test records deleted successfully"
  end

  post "/download" do
    puts "** POST params[:fs_request_id]=#{params[:fs_request_id]} params[:fs_file_name]=#{params[:fs_file_name]} params[:fs_uri_list]=#{params[:fs_uri_list]}"
    #handle JSON request
    is_json_request = request.content_type.downcase == 'application/json'
    if is_json_request 
      #cannot read 'request.body.read' more then once so assigned to variable 
      json_body = request.body.read
      @params = JSON.parse(json_body, symbolize_names: true) unless json_body.empty?
    end
    params[:fs_file_name] = DEFAULT_FILE_NAME if (params[:fs_file_name].nil? || params[:fs_file_name] == '')
    # Parse the request and do some initial filtering for badly formatted requests:
    halt 400, 'Request must include non-empty file_name and uri_list parameters' unless (!params[:fs_file_name].nil? && params[:fs_file_name].length>0) &&
      (!params[:fs_uri_list].nil? && params[:fs_uri_list].length>0)

    zip_filename = params[:fs_file_name]
    if params[:fs_uri_list].is_a?(Array)
      uri_list = params[:fs_uri_list]
    else
      uri_list = JSON.parse(params[:fs_uri_list].gsub(/\s/,''))
    end

    halt 400, 'Duplicate URIs found' unless uri_list.uniq.length == uri_list.length

    # request_id is optional - passed through to report for end-to-end testing
    if !params[:fs_request_id].nil?
      request_id = params[:fs_request_id].to_s.downcase
      halt 400, 'Malformed UUID for request_id parameter' unless /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.match?(request_id)
    else
      request_id = SecureRandom.uuid
    end

    FileslideStreamer.with_redis do |redis|
      redis.set(request_id, ({file_name: zip_filename, uri_list: uri_list}.merge(params)).to_json, ex: DOWNLOAD_EXPIRATION_LIMIT_SECONDS)
    end

    # using the 303 status code forces the browser to change the method to GET.
    redirect to("#{ENV.fetch("BASE_URL")}/stream/#{request_id}"), 303
  rescue JSON::ParserError, KeyError => e
    halt 400, "#{(is_json_request ? 'request body' : 'uri_list')} is not valid JSON"
  end

  get "/stream/:fs_request_id" do
    puts "** GET #{params[:fs_request_id]}"
    request_id = params[:fs_request_id]
    halt 400 unless request_id
    stored_params = FileslideStreamer.with_redis do |redis|
      redis.get(request_id)
    end

    halt 404, "This download is unavailable or has expired" if stored_params.nil?

    decoded_params = JSON.parse(stored_params, symbolize_names: true)
    zip_filename = decoded_params[:file_name]
    uri_list = decoded_params[:uri_list]
    client_headers = {}
    #Get client headers that can be forwarded with request
    if(decoded_params[:fs_forward_all_headers].to_s == 'true')
      client_headers = request.env.select{ |key, val| !FileslideStreamer::EXCLUDED_HEADERS.include?(key) }
    else
      decoded_params.each do |key, val|
        if key.to_s.start_with?(CLIENT_HEADER_START_WITH)
          header_key = key.to_s.split(CLIENT_HEADER_START_WITH).last
          client_headers[header_key] = val unless FileslideStreamer::EXCLUDED_HEADERS.include?(header_key)
        end
      end
    end

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
    availability_checking_http = HTTP.timeout(connect: 5, read: 10).headers({"Range" => "bytes=0-0"}.merge(client_headers)).follow(max_hops: 2)
    failed_uris = []
    zip_streamer = ZipStreamer.new(client_headers: client_headers)
    uri_list.each do |uri|
      begin
        resp = availability_checking_http.get(uri)
        puts "** availability_checking_http: #{uri} => #{resp.status}\n"
        unless [200,206].include? resp.status
          failed_uris << FailedUri.new(uri: uri, response_code: resp.status)
          next
        end
        content_disposition = resp.headers['Content-Disposition']
        total_size = resp.headers['Content-Range'].split('/')[1].to_i
        etag = resp.headers['ETag']
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
      http_body = zip_streamer.make_partial_streaming_body(request_id: request_id, start: range_start, stop: range_stop)
    else
      headers.merge!({
        'Content-Length' => total_size.to_s
      })
      http_body = zip_streamer.make_complete_streaming_body(request_id: request_id)
    end

    response_code = ranged_request ? 206 : 200
    [response_code,headers,http_body]

  rescue UpstreamAPI::UpstreamNotFoundError => e
    halt 500, 'Error connecting to upstream'
  rescue ZipStreamer::ChecksummingError => e
    halt 500, 'Error occurred during checksum computation'
  end

  def construct_error_message(failed_uris: )
    resp = "502 Bad Gateway\nThe following files could not be fetched:\n"
    failed_uris.each do |f|
      resp << f.to_s
    end
    resp
  end

  def self.init!
    @@redis_pool = ConnectionPool.new(size: 8, timeout: 5) { Redis.new(url: ENV.fetch("REDIS_URL")) }
  end

  def self.with_redis
    @@redis_pool.with { |redis| yield(redis) }
  end
end
