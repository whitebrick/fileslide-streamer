class UpstreamAPI
  UPSTREAM_API_LOCATION = ENV.fetch("UPSTREAM_API_LOCATION")

  class NotAuthorizedError < Exception
  end
  class UpstreamNotFoundError < Exception
  end

  def initialize
    @http = HTTP.timeout(connect: 5, read: 10) # both servers are on AWS so this is pretty generous
  end

  def verify_uri_list(uri_list:, file_name: )
    auth_response = @http.post("#{UPSTREAM_API_LOCATION}/authorize", form: {uri_list: uri_list.to_json})
    if !auth_response.status.ok?
      raise UpstreamNotFoundError
    end
    auth_body_json = JSON.parse(auth_response.to_s, symbolize_names: true)
    return auth_body_json
  rescue HTTP::Error
    raise UpstreamNotFoundError
  end

  def report(request_id:, written_uri_list:, start_time:, stop_time:, bytes_sent:, complete: )
    stored_params = FileslideStreamer.with_redis do |redis|
      redis.get(request_id)
    end
    uri_list = JSON.parse(stored_params, symbolize_names: true)[:uri_list]
    report_hash = {
      request_id: request_id,
      uri_list: uri_list.to_json,
      written_uri_list: written_uri_list.to_json,
      start_time: start_time,
      stop_time: stop_time,
      bytes_sent: bytes_sent,
      complete: complete,
    }
    puts "** reporting: #{report_hash}\n\n"
    @http.post("#{UPSTREAM_API_LOCATION}/report", form: report_hash)
  rescue HTTP::Error
    # it's already after the response to the user has completed, not much
    # that we can do
    nil
  end
end
