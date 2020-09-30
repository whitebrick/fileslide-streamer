class UpstreamAPI
  UPSTREAM_API_LOCATION = ENV.fetch("UPSTREAM_API_LOCATION")
  class NotAuthorizedError < Exception
  end
  class UpstreamNotFoundError < Exception
  end

  def initialize
    @http = HTTP.timeout(connect: 5, read: 10) # both servers are on AWS so this is pretty generous
  end

  def verify_uri_list(uri_list: )
    auth_response = @http.post("#{UPSTREAM_API_LOCATION}/authorize", json: uri_list.to_json)
    unless auth_response == 200
      raise UpstreamNotFoundError
    end
    auth_body_json = JSON.parse(auth_response.to_s, symbolize_names: true)
    return auth_body_json
  rescue HTTP::Error
    raise UpstreamNotFoundError
  end

  def report()
  end

end
