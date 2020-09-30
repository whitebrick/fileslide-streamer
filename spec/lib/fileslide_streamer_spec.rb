require 'spec_helper.rb'
require 'zip'

RSpec.describe FileslideStreamer do
  def app
    FileslideStreamer.new
  end

  before :all do
    file_provider_app = File.expand_path(__dir__ + '/../file_provider.rb')
    command = "bundle exec ruby #{file_provider_app}"
    @provider_pid = spawn(command)
    sleep 1 # server needs some time to start up
  end

  after :all do
    Process.kill("TERM", @provider_pid)
    Process.wait(@provider_pid)
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

    it 'fails with 502 and proper errors if any of the upstream servers are unavailable'
    # hostnames ending with .invalid are guarantueed not to exist per RFC 6761

    it 'fails with 502 and a list of failed URIs if any of the URIs are not 200/206' do
      expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
        and_return({authorized: true, unauthorized_html: nil})

      post '/download', {file_name: 'files.zip', uri_list: [
        "http://example.com/allowed_but_unavailable_file1",
        "http://example.com/allowed_but_unavailable_file2",
      ]}.to_json

      expect(last_response.status).to eq 502
      expect(last_response.body).to include '502 Bad Gateway'
      expect(last_response.body).to include 'The following files could not be fetched:'
      expect(last_response.body).to include 'http://example.com/allowed_but_unavailable_file1 [404 Not Found]'
      expect(last_response.body).to include 'http://example.com/allowed_but_unavailable_file2 [404 Not Found]'
    end

    context 'when auth is OK'
      it 'attaches the correct filename and reports to upstream' do
        expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
          and_return({authorized: true, unauthorized_html: nil})
        expect_any_instance_of(UpstreamAPI).to receive(:report)

        post '/download', {file_name: 'zero_files.zip', uri_list: []}.to_json

        expect(last_response.status).to eq 200
        expect(last_response.headers["Content-Disposition"]).to eq "attachment; filename=\"zero_files.zip\""

        # The received body should be a valid zip file with zero items in it.
        tf = Tempfile.new
        tf << last_response.body
        tf.flush
        Zip::File.open(tf) do | zip |
          expect(zip.entries.length).to eq(0)
        end
      ensure
        tf.unlink
      end

      it 'streams the uris as a zip and reports to upstream' do
        expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
          and_return({authorized: true, unauthorized_html: nil})
        expect_any_instance_of(UpstreamAPI).to receive(:report)

        post '/download', {file_name: 'three_files.zip', uri_list: [
          "http://localhost:9293/random_bytes1.bin",
          "http://localhost:9293/random_bytes2.bin",
          "http://localhost:9293/random_bytes3.bin",
        ]}.to_json

        expect(last_response.status).to eq 200
        expect(last_response.headers["Content-Disposition"]).to eq "attachment; filename=\"three_files.zip\""
        # The received body should be a valid zip file with three items in it and the items
        # should match the files in spec/fixtures
        tf = Tempfile.new
        tf << last_response.body
        tf.flush
        Zip::File.open(tf) do | zip |
          expect(zip.entries.length).to eq(3)
          f1 = File.open(File.expand_path(__dir__ + '/../fixtures/random_bytes1.bin'),'rb') {|file| file.read}
          f2 = File.open(File.expand_path(__dir__ + '/../fixtures/random_bytes2.bin'),'rb') {|file| file.read}
          f3 = File.open(File.expand_path(__dir__ + '/../fixtures/random_bytes3.bin'),'rb') {|file| file.read}
          expect(zip.entries[0].name).to eq "random_bytes1.bin"
          expect(zip.entries[0].size).to eq 1024
          expect(zip.entries[0].get_input_stream.read).to eq f1
          expect(zip.entries[1].name).to eq "random_bytes2.bin"
          expect(zip.entries[1].size).to eq 2048
          expect(zip.entries[1].get_input_stream.read).to eq f2
          expect(zip.entries[2].name).to eq "random_bytes3.bin"
          expect(zip.entries[2].size).to eq 4096
          expect(zip.entries[2].get_input_stream.read).to eq f3
        end
      ensure
        tf.unlink if tf
      end

    it 'deduplicates filenames if multiple files have the same name'
  end
end
