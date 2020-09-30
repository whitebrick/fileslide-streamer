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
    it 'fails with 400 if the request is not valid JSON'
    it 'fails with 400 if the request JSON does not contain a file_name key'
    it 'fails with 400 if the request JSON does not contain a uri_list key'
    it 'fails with 403 and the returned html if the upstream API does not authorize the download'
    it 'fails with 502 and a list of failed URIs is any of the URIs are not 200/206'
    it 'streams the uris as a zip'
    it 'deduplicates filenames if multiple files have the same name'
  end
end
