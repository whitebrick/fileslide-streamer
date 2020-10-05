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
    auth_response = @http.post("#{UPSTREAM_API_LOCATION}/authorize", json: {uri_list: uri_list, file_name: file_name}.to_json)
    unless auth_response == 200
      raise UpstreamNotFoundError
    end
    auth_body_json = JSON.parse(auth_response.to_s, symbolize_names: true)
    return auth_body_json
  rescue HTTP::Error
    raise UpstreamNotFoundError
  end

  def report(start_time:, stop_time: , bytes_sent:, complete: )
    @http.post("#{UPSTREAM_API_LOCATION}/report", json: {
      start_time: start_time,
      stop_time: stop_time,
      bytes_sent: bytes_sent,
      complete: complete,
    })
  rescue HTTP::Error
    # it's already after the response to the user has completed, not much
    # that we can do
    nil
  end
end
