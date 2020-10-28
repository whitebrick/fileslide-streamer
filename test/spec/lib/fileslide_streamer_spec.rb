require 'spec_helper.rb'
require 'zip'
require 'zlib'
require 'timecop'

RSpec.describe FileslideStreamer do
  def app
    FileslideStreamer.new
  end

  before :all do
    file_provider_app = File.expand_path(__dir__ + '/../file_provider.rb')
    command = "bundle exec ruby #{file_provider_app}"
    @provider_pid = spawn(command)
    sleep 3 # server needs some time to start up
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
    it 'fails with 400 if the request file_name is blank' do
      post '/download', uri_list: ["http://localhost:9293/random_bytes1.bin"].to_json
      expect(last_response.status).to eq 400
      expect(last_response.body).to eq 'Request must include non-empty file_name and uri_list parameters'
    end

    it 'fails with 400 if the request uri_list is blank' do
      post '/download', file_name: 'files.zip'
      expect(last_response.status).to eq 400
      expect(last_response.body).to eq 'Request must include non-empty file_name and uri_list parameters'
    end

    it 'fails with 400 if the request uri_list is not valid JSON' do
      post '/download', file_name: 'files.zip', uri_list: "I'm not valid json"
      expect(last_response.status).to eq 400
      expect(last_response.body).to eq 'uri_list is not a valid JSON array'
    end

    it 'fails with 400 if some of the uris in the request occur more than once' do
      post '/download', file_name: 'files.zip', uri_list: [
        "http://localhost:9293/random_bytes1.bin",
        "http://localhost:9293/random_bytes1.bin",
        "http://localhost:9293/random_bytes2.bin"
      ].to_json
      expect(last_response.status).to eq 400
      expect(last_response.body).to eq 'Duplicate URIs found'
    end

    it 'fails with 403 and the returned html if the upstream API does not authorize the download' do
      expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
        and_return({authorized: false, unauthorized_html: "NOT ALLOWED"})

      post '/download', file_name: 'files.zip', uri_list: ["http://example.com/not_allowed_file"].to_json

      expect(last_response.status).to eq 403
      expect(last_response.body).to eq "NOT ALLOWED"
    end

    it 'fails with 502 and proper errors if any of the upstream servers are unavailable' do
      expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
        and_return({authorized: true, unauthorized_html: nil})

      post '/download', file_name: 'files.zip', uri_list: [
        # http://example.invalid... preferred (shouldn't exist per RFC 6761)
        # but some ISPs still respond with 200 so localhost:9999 used instead
        "http://localhost:9999/allowed_but_unavailable_file1",
        "http://localhost:9999/allowed_but_unavailable_file2",
        "http://localhost:9293/random_bytes1.bin",
      ].to_json

      expect(last_response.status).to eq 502
      expect(last_response.body).to include '502 Bad Gateway'
      expect(last_response.body).to include 'The following files could not be fetched:'
      expect(last_response.body).to include 'http://localhost:9999/allowed_but_unavailable_file1 [503 Service Unavailable]'
      expect(last_response.body).to include 'http://localhost:9999/allowed_but_unavailable_file2 [503 Service Unavailable]'
    end

    it 'fails with 502 and a list of failed URIs if any of the URIs are not 200/206' do
      expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
        and_return({authorized: true, unauthorized_html: nil})

      post '/download', file_name: 'files.zip', uri_list: [
        "http://example.com/allowed_but_unavailable_file1",
        "http://example.com/allowed_but_unavailable_file2",
        "http://localhost:9293/random_bytes1.bin",
      ].to_json

      expect(last_response.status).to eq 502
      expect(last_response.body).to include '502 Bad Gateway'
      expect(last_response.body).to include 'The following files could not be fetched:'
      expect(last_response.body).to include 'http://example.com/allowed_but_unavailable_file1 [404 Not Found]'
      expect(last_response.body).to include 'http://example.com/allowed_but_unavailable_file2 [404 Not Found]'
    end

    context 'when auth is OK'
      context 'streaming full files' do
        it 'attaches the correct filename and reports to upstream' do
          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          expect_any_instance_of(UpstreamAPI).to receive(:report)

          post '/download', file_name: 'zero_files.zip', uri_list: [].to_json

          expect(last_response.status).to eq 200
          expect(last_response.headers["Content-Disposition"]).to eq "attachment; filename=\"zero_files.zip\""
          expect(last_response.headers["Content-Length"]).to eq last_response.body.length.to_s

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

        it 'streams the uris as a zip, stores checksums in Redis and reports to upstream' do
          r = Redis.new
          r.flushall

          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          expect_any_instance_of(UpstreamAPI).to receive(:report)

          post '/download', file_name: 'three_files.zip', uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin",
            "http://localhost:9293/random_bytes3.bin",
          ].to_json

          expect(last_response.status).to eq 200
          expect(last_response.headers["Content-Disposition"]).to eq "attachment; filename=\"three_files.zip\""
          expect(last_response.headers["Content-Length"]).to eq last_response.body.length.to_s

          # The received body should be a valid zip file with three items in it and the items
          # should match the files in spec/fixtures
          tf = Tempfile.new
          tf << last_response.body
          tf.flush
          f1 = File.open(File.expand_path(__dir__ + '/../fixtures/random_bytes1.bin'),'rb') {|file| file.read}
          f2 = File.open(File.expand_path(__dir__ + '/../fixtures/random_bytes2.bin'),'rb') {|file| file.read}
          f3 = File.open(File.expand_path(__dir__ + '/../fixtures/random_bytes3.bin'),'rb') {|file| file.read}
          Zip::File.open(tf) do | zip |
            expect(zip.entries.length).to eq(3)
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

          expect(r.dbsize).to eq 3
          expect(r.get("http://localhost:9293/random_bytes1.bin")).to eq({
            state: "done",
            etag: nil,
            crc32: Zlib.crc32(f1)
          }.to_json)
          expect(r.get("http://localhost:9293/random_bytes2.bin")).to eq({
            state: "done",
            etag: nil,
            crc32: Zlib.crc32(f2)
          }.to_json)
          expect(r.get("http://localhost:9293/random_bytes3.bin")).to eq({
            state: "done",
            etag: nil,
            crc32: Zlib.crc32(f3)
          }.to_json)
        ensure
          tf.unlink if tf
        end

        it 'still reports to upstream even if there is an exception during streaming' do
          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          expect_any_instance_of(UpstreamAPI).to receive(:report)
          expect_any_instance_of(ZipTricks::Streamer).to receive(:write_stored_file).and_raise(HTTP::Error.new("BOOM!"))

          post '/download', file_name: 'one_file.zip', uri_list: [
            "http://localhost:9293/random_bytes1.bin",
          ].to_json
        end
      end

      context 'when streaming partial zips' do
        it 'returns 400 if an invalid range header is requested' do
          header 'Range', 'gimme all the bytes'
          post '/download', file_name: 'files.zip', uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin"
          ].to_json
          expect(last_response.status).to eq 400
          expect(last_response.body).to eq 'Invalid Range header'
        end

        it 'returns 416 if a multipart range is requested' do
          header 'Range', 'bytes=0-50, 100-150'
          post '/download', file_name: 'files.zip', uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin"
          ].to_json
          expect(last_response.status).to eq 416
          expect(last_response.body).to eq 'Multipart ranges are not supported'
        end

        it 'returns 416 if the start of the range is beyond the size of the zip' do
          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})

          header 'Range', 'bytes=123456-'
          post '/download', file_name: 'files.zip', uri_list: [
            "http://localhost:9293/random_bytes1.bin",
          ].to_json

          expect(last_response.status).to eq 416
        end

        it 'falls back to whole file fetching if an inverse range is requested' do
          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          expect_any_instance_of(UpstreamAPI).to receive(:report)

          header 'Range', 'bytes=50-0'
          post '/download', file_name: 'files.zip', uri_list: [
            "http://localhost:9293/random_bytes1.bin",
          ].to_json

          expect(last_response.status).to eq 200
        end

        it 'returns the whole file for range "0-"' do
          now = Time.now
          Timecop.freeze(now) # otherwise the modification times of files in the zip will differ
          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          expect_any_instance_of(UpstreamAPI).to receive(:report)

          post '/download', file_name: 'files.zip', uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin"
          ].to_json

          expect(last_response.status).to eq 200
          full_response_body = last_response.body.dup

          allow_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          allow_any_instance_of(UpstreamAPI).to receive(:report)

          header 'Range', 'bytes=0-'
          post '/download', file_name: 'files.zip', uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin"
          ].to_json

          expect(last_response.status).to eq 206
          expect(last_response.body.length).to eq full_response_body.length
          expect(last_response.body).to eq full_response_body
          Timecop.return
        end

        it 'returns ranges that can sum to the whole response' do
          Timecop.freeze(Time.now) # otherwise the modification times of files in the zip will differ
          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          expect_any_instance_of(UpstreamAPI).to receive(:report)

          post '/download', file_name: 'files.zip', uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin"
          ].to_json

          expect(last_response.status).to eq 200
          full_response_body = last_response.body.dup

          allow_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          allow_any_instance_of(UpstreamAPI).to receive(:report)

          header 'Range', 'bytes=0-1234'
          post '/download', file_name: 'files.zip', uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin"
          ].to_json

          expect(last_response.status).to eq 206
          first_partial_body = last_response.body.dup

          allow_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          allow_any_instance_of(UpstreamAPI).to receive(:report)


          header 'Range', 'bytes=1235-'
          post '/download', file_name: 'files.zip', uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin"
          ].to_json

          expect(last_response.status).to eq 206
          second_partial_body = last_response.body.dup
          expect(first_partial_body + second_partial_body).to eq full_response_body

          Timecop.return
        end

        it 'returns the whole rest of the file if the end of the range is beyond the zip size' do
          now = Time.now
          Timecop.freeze(now) # otherwise the modification times of files in the zip will differ
          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          expect_any_instance_of(UpstreamAPI).to receive(:report)

          post '/download', file_name: 'files.zip', uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin"
          ].to_json

          expect(last_response.status).to eq 200
          full_response_body = last_response.body.dup

          allow_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          allow_any_instance_of(UpstreamAPI).to receive(:report)

          header 'Range', 'bytes=0-123456'
          post '/download', file_name: 'files.zip', uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin"
          ].to_json

          expect(last_response.status).to eq 206
          expect(last_response.body.length).to eq full_response_body.length
          expect(last_response.body).to eq full_response_body
          Timecop.return
        end

        it 'does not fetch any extra checksums if all checksums are already known'
        it 'fetches checksums for unknown files'
        it 'fetches checksums in parallel for large files'
      end

  end
end
