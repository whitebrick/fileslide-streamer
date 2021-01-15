require 'securerandom'

class FileslideStreamer < Sinatra::Base

  DOWNLOAD_EXPIRATION_LIMIT_SECONDS = 7 * 24 * 60 * 60 # one week in seconds
  DEFAULT_FILE_NAME = 'download.zip'
  CLIENT_CUSTOM_HEADER_PREFIX = 'fs_add_header-'

  set :views, File.dirname(__FILE__)+'/../views'

  FailedUri = Struct.new(:uri, :response_code, keyword_init: true) do
    def to_s
      "#{uri.to_s} [#{response_code}]\n"
    end
  end

  get "/" do
    redirect to('https://fileslide.io')
  end

  get "/health_check" do
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
    puts "** POST /download params[:fs_request_id]=#{params[:fs_request_id]} params[:fs_uri_list].size=#{ params[:fs_uri_list].size if !params[:fs_uri_list].nil?}"
    @error_records = []
    @response_format = :html
    @error_redirect_uri = nil

    # Inital requests may be either form url encoded (default) or json encoded
    is_json_request = (request.content_type.downcase == 'application/json')
    if is_json_request
      @response_format = :json
      # cannot 'request.body.read' more then once so assigned to variable 
      json_body = request.body.read
      parsed_params = FileslideStreamer.valid_json(json_body)
      halt 400, 'MALFORMED_JSON_BODY' if parsed_params.nil?
      params.merge!(parsed_params)
    end

    # how errors will be returned (defaults set above)
    if !params[:fs_response_format].nil?
      sym = params[:fs_response_format].to_s.downcase.to_sym
      if [:json, :redirect].include?(sym)
        @response_format = sym
      end
    end

    # if asking for errors to be redirected must have valid URL
    if @response_format==:redirect
      if params[:fs_error_redirect_uri].nil? || params[:fs_error_redirect_uri].size==0
        @response_format==:html
        halt 400, 'EMPTY_ERROR_REDIRECT_URI'
      elsif params[:fs_error_redirect_uri] !~ URI::regexp(['http','https'])
        @response_format==:html
        halt 400, 'INVALID_ERROR_REDIRECT_URI'
      else
        @error_redirect_uri = params[:fs_error_redirect_uri]
      end
    end
    
    # file name
    zip_file_name = (!params[:fs_file_name].nil? && params[:fs_file_name].size>0) ? params[:fs_file_name].gsub!(/[^-_0-9A-Za-z.]/, '_') : DEFAULT_FILE_NAME

    # uri list - nb: a form url encoded request can have a json encoded uri list
    uri_list = []
    if !params[:fs_uri_list].nil? && params[:fs_uri_list].size>0
      if params[:fs_uri_list].is_a?(Array)
        uri_list = params[:fs_uri_list]
      else
        if !FileslideStreamer.valid_json(params[:fs_uri_list])
          halt 400, 'MALFORMED_URI_LIST'
        else
          uri_list = JSON.parse(params[:fs_uri_list])
        end
      end
    end
    halt 400, 'EMPTY_URI_LIST' if uri_list.size==0
    halt 400, 'DUPLICATE_URIS' if uri_list.uniq.size != uri_list.size

    # check uris
    @error_records = uri_list.map{|uri| uri if uri !~ URI::regexp(['http','https'])}.compact
    halt 400, 'INVALID_URIS' if error_records.size > 0
    
    # request_id is optional
    # passed through to report for testing and tracking
    if !params[:fs_request_id].nil?
      request_id = params[:fs_request_id].to_s.downcase
      halt 400, 'MALFORMED_UUID' if !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.match?(request_id)
    else
      request_id = SecureRandom.uuid
    end

    # sometimes clients will want to forward headers when fetching data for authorization etc
    # they can either set fs_forward_all_headers=true or put the header as a param with specific prefix
    client_headers = {}
    if(params[:fs_forward_all_headers].to_s.downcase == 'true')
      client_headers = FileslideStreamer.filter_client_headers(request.env)
    elsif params.keys.any?{ |param| param.start_with?(CLIENT_CUSTOM_HEADER_PREFIX) }
      params.each do |key, val|
        if key.to_s.start_with?(CLIENT_CUSTOM_HEADER_PREFIX)
          header_key = key.to_s[(CLIENT_CUSTOM_HEADER_PREFIX.size)..]
          client_headers[header_key] = val
        end
      end
      client_headers = FileslideStreamer.filter_client_headers(client_headers)
    end

    # if we get to here request is valid
    FileslideStreamer.with_redis do |redis|
      redis.set(request_id, {
        file_name: zip_file_name,
        uri_list: uri_list,
        client_headers: client_headers,
        response_format: @response_format,
        error_redirect_uri: @error_redirect_uri
      }.to_json, ex: DOWNLOAD_EXPIRATION_LIMIT_SECONDS)
    end

    # using the 303 status code forces the browser to change the method to GET.
    redirect to("#{ENV.fetch("BASE_URL")}/stream/#{request_id}"), 303

  rescue StandardError => e
    @error_records = e.backtrace
    halt 500
  end

  get "/stream/:fs_request_id" do
    puts "** GET /stream/:fs_request_id params[:fs_request_id]=#{params[:fs_request_id]}"
    @error_records = []
    @response_format = :html
    @error_redirect_uri = nil

    # until we have a key, default response is html
    @response_format = :html
    request_id = params[:fs_request_id].to_s.downcase
    halt 400, 'MISSING_REQUEST_ID' if request_id.nil?
    halt 400, 'MALFORMED_UUID' if !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.match?(request_id)

    stored_params = FileslideStreamer.with_redis do |redis|
      redis.get(request_id)
    end
    halt 404, 'DOWNLOAD_EXPIRED' if stored_params.nil?

    decoded_params = JSON.parse(stored_params, symbolize_names: true)
    zip_file_name       = decoded_params[:file_name]
    uri_list            = decoded_params[:uri_list]
    client_headers      = decoded_params[:client_headers]
    @response_format    = decoded_params[:response_format]
    @error_redirect_uri = decoded_params[:error_redirect_uri]

    ranged_request = !request.env['HTTP_RANGE'].nil?
    range_start, range_stop = if ranged_request
      halt 400, 'INVALID_RANGE_HEADER' if !request.env['HTTP_RANGE'].downcase.start_with?('bytes=')
      halt 416, 'MULTIPART_UNSUPPORTED' if request.env['HTTP_RANGE'].include? ','
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
          halt 416, 'MALFORMED_RANGE'
        end
      elsif range_stop < range_start
        # See https://tools.ietf.org/html/rfc2616#section-14.35, we must ignore this Range header
        ranged_request = false
      end
    end

    # Check for auth with upstream service
    upstream = UpstreamAPI.new
    verification_result = upstream.verify_uri_list(uri_list: uri_list, file_name: zip_file_name)
    if !verification_result[:authorized]
      @error_records = verification_result[:unauthorized_uris]
      halt 403, 'UNAUTHORIZED_URIS'
    end

    puts "** URIs OK uri_list.size=#{uri_list.size}"

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
        if ![200,206].include?(resp.status)
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
    if !failed_uris.empty?
      @error_records = failed_uris
      halt 502, 'FAILED_FETCHING_URIS'
    end

    puts "** zip_streamer.files.size=#{zip_streamer.files.size}"

    # Deduplicate filenames if required
    zip_streamer.deduplicate_filenames!
    # Compute size of complete zip. This is required even for ranged requests.
    total_size = zip_streamer.compute_total_size!

    headers = {
      'Accept-Ranges' => 'bytes',
      'Content-Disposition' => "attachment; filename=\"#{zip_file_name}\"",
      'X-Accel-Buffering' => 'no', # disable nginx buffering
      'Content-Encoding' => 'none',
      'Content-Type' => 'binary/octet-stream',
    }

    halt 416, 'RANGE_NOT_SATISFIABLE' if range_start >= total_size

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
    @error_records = e.backtrace
    halt 500, 'UPSTREAM_ERROR'
  rescue ZipStreamer::ChecksummingError => e
    @error_records = e.backtrace
    halt 500, 'CHECKSUM_ERROR'
  end

  def self.init!
    @@redis_pool = ConnectionPool.new(size: 8, timeout: 5) { Redis.new(url: ENV.fetch("REDIS_URL")) }
  end

  def self.with_redis
    @@redis_pool.with { |redis| yield(redis) }
  end

  def self.valid_json(value)
    result = JSON.parse(value, symbolize_names: true)
    return (result.is_a?(Hash) || result.is_a?(Array)) ? result : nil
  rescue JSON::ParserError, TypeError
    return nil
  end

  # Don't forward system headers
  def self.filter_client_headers(header_hash)
    [
      'ACCEPT-RANGES',
      'CONTENT-DISPOSITION',
      'CONTENT-ENCODING',
      'DATE',
      'GATEWAY_INTERFACE',
      'HOST',
      'HTTP_*',
      'PATH_*',
      'PUMA.*',
      'QUERY_STRING',
      'RACK.*',
      'RANGE',
      'REMOTE_ADDR',
      'REQUEST_*',
      'SCRIPT_*',
      'SERVER_*',
      'SINATRA.*',
      'TRANSFER-ENCODING',
      'X-ACCEL-*'
    ].each do |exclude_key|
      header_hash.keys.each do |header_key|
        if  ( exclude_key.end_with?('*') && header_key.upcase.start_with?(exclude_key.chop) ) ||
            ( exclude_key==header_key.upcase )
              header_hash.delete(header_key)
        end
      end
    end
    return header_hash
  end

  def self.error_message(error_key)
    messages = {
      UNKNOWN:                    'Unknown server error',
      # 400
      MALFORMED_JSON_BODY:        'The request body must be valid JSON when using the application/json content type header',
      MALFORMED_URI_LIST:         'The fs_uri_list parameter value must either be a form-url encoded or json encoded array',
      EMPTY_URI_LIST:             'The fs_uri_list parameter value must contain at least one URI',
      DUPLICATE_URIS:             'The fs_uri_list parameter value contains duplicate URIs',
      INVALID_URIS:               'The fs_uri_list parameter value contains one or more invalid URIs',
      MISSING_REQUEST_ID:         'This URL is missing a Request ID',
      INVALID_RANGE_HEADER:       'Range header must start with \'bytes=\'',
      EMPTY_ERROR_REDIRECT_URI:   'The fs_error_redirect_uri parameter value is empty and is required for redirect response format',
      INVALID_ERROR_REDIRECT_URI: 'The fs_error_redirect_uri parameter value is invalid and is required for redirect response format',
      # 403
      UNAUTHORIZED_URIS:          'One or more of the files requested for zipping have not been permitted',
      # 404
      DOWNLOAD_EXPIRED:           'This download is unavailable or has expired',
      # 416
      MULTIPART_UNSUPPORTED:      'Multipart ranges are not supported',
      MALFORMED_RANGE:            'Range could not be parsed',
      RANGE_NOT_SATISFIABLE:      'Start of range outside zip size',
      # 500
      UPSTREAM_ERROR:             'Could not connect to authorization server',
      CHECKSUM_ERROR:             'Error occurred during checksum computation',
      # 502
      FAILED_FETCHING_URIS:       'One or more of the files requested for zipping could not be fetched'
    }
    error_key = :UNKNOWN if !messages.has_key?(error_key.to_sym)
    return messages[error_key.to_sym]
  end

  error 400..510 do
    error_key = !body[0].nil? ? body[0] : 'UNKNOWN'
    error_message = FileslideStreamer.error_message(error_key)
    error_hash = {
      fs_error_key: error_key,
      fs_error_message: error_message,
      fs_error_records: @error_records
    }
    if @response_format==:redirect
      redirect_uri = "#{@error_redirect_uri}?#{URI.encode_www_form({fs_error_key: error_key})}"
      if !@error_records.nil? && @error_records.size>0
        redirect_uri = "#{redirect_uri}&#{URI.encode_www_form({fs_error_records: @error_records.join(';')[0...1000]})}" # limit GET length
      end
      redirect to(redirect_uri), 303
    elsif @response_format==:json
      content_type :json
      error_hash.to_json
    else
      erb :fs_error, locals: error_hash
    end
  end

end
