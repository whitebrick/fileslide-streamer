require 'spec_helper.rb'

RSpec.describe FileslideStreamer do
  def app
    FileslideStreamer.new
  end

  context 'utility endpoints' do
    it 'redirects to the main site on index' do
      get '/'
      expect(last_response.status).to eq 302
    end

    it 'returns 200/All good on the healthcheck' do
      get 'healthcheck'
      expect(last_response.status).to eq 200
      expect(last_response.body).to eq "All good\n"
    end
  end

  context '/download' do
    it 'fails with 400 if the request is not valid JSON' do
      post '/download', "I'm not valid json"
      expect(last_response.status).to eq 400
    end

    it 'fails with 400 if the request JSON does not contain a file_name key' do
      post '/download', {uri_list: []}.to_json
      expect(last_response.status).to eq 400
    end
    it 'fails with 400 if the request JSON does not contain a uri_list key' do
      post '/download', {file_name: 'files.zip'}.to_json
      expect(last_response.status).to eq 400
    end

    it 'fails with 403 and the returned html if the upstream API does not authorize the download' do
      expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
        and_return({authorized: false, unauthorized_html: "NOT ALLOWED"})

      post '/download', {file_name: 'files.zip', uri_list: ["http://example.com/not_allowed_file"]}.to_json

      expect(last_response.status).to eq 403
      expect(last_response.body).to eq "NOT ALLOWED"
    end

    it 'fails with 502 and a list of failed URIs is any of the URIs are not 200/206'
    it 'streams the uris as a zip'
    it 'deduplicates filenames if multiple files have the same name'
  end
end
