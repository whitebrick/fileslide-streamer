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
    it 'succeed with 303 if the request file_name is blank' do
      post '/download', fs_uri_list: ["http://localhost:9293/random_bytes1.bin"].to_json
      expect(last_response.status).to eq 303
    end

    it 'fails with 400 if the request uri_list is blank' do
      post '/download', fs_file_name: 'files.zip'
      expect(last_response.status).to eq 400
      expect(last_response.body).to include 'The fs_uri_list parameter value must contain at least one URI'
    end

    it 'fails with 400 if the request uri_list is not valid JSON' do
      post '/download', fs_file_name: 'files.zip', fs_uri_list: "I'm not valid json"
      expect(last_response.status).to eq 400
      expect(last_response.body).to include 'The fs_uri_list parameter value must either be a form-url encoded or json encoded array'
    end

    it 'fails with 400 if some of the uris in the request occur more than once' do
      post '/download', fs_file_name: 'files.zip', fs_uri_list: [
        "http://localhost:9293/random_bytes1.bin",
        "http://localhost:9293/random_bytes1.bin",
        "http://localhost:9293/random_bytes2.bin"
      ].to_json
      expect(last_response.status).to eq 400
      expect(last_response.body).to include 'The fs_uri_list parameter value contains duplicate URIs'
    end

    it 'fails with 403 and the returned html if the upstream API does not authorize the download' do
      expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
        and_return({authorized: false, unauthorized_html: "NOT ALLOWED"})

      post '/download', fs_file_name: 'files.zip', fs_uri_list: ["http://example.com/not_allowed_file"].to_json
      
      # Follow the redirect
      expect(last_response.status).to eq 303
      get (last_response.headers["Location"])

      expect(last_response.status).to eq 403
      expect(last_response.body).to include "One or more of the files requested for zipping have not been permitted"
    end

    it 'fails with 502 and proper errors if any of the upstream servers are unavailable' do
      expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
        and_return({authorized: true, unauthorized_html: nil})

      post '/download', fs_file_name: 'files.zip', fs_uri_list: [
        # http://example.invalid... preferred (shouldn't exist per RFC 6761)
        # but some ISPs still respond with 200 so localhost:9999 used instead
        "http://localhost:9999/allowed_but_unavailable_file1",
        "http://localhost:9999/allowed_but_unavailable_file2",
        "http://localhost:9293/random_bytes1.bin",
      ].to_json

      # Follow the redirect
      expect(last_response.status).to eq 303
      get (last_response.headers["Location"])

      expect(last_response.status).to eq 502
      expect(last_response.body).to include 'One or more of the files requested for zipping could not be fetched'
      expect(last_response.body).to include 'http://localhost:9999/allowed_but_unavailable_file1 [503 Service Unavailable]'
      expect(last_response.body).to include 'http://localhost:9999/allowed_but_unavailable_file2 [503 Service Unavailable]'
    end

    it 'fails with 502 and a list of failed URIs if any of the URIs are not 200/206' do
      expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
        and_return({authorized: true, unauthorized_html: nil})

      post '/download', fs_file_name: 'files.zip', fs_uri_list: [
        "http://example.com/allowed_but_unavailable_file1",
        "http://example.com/allowed_but_unavailable_file2",
        "http://localhost:9293/random_bytes1.bin",
      ].to_json

      # Follow the redirect
      expect(last_response.status).to eq 303
      get (last_response.headers["Location"])

      expect(last_response.status).to eq 502
      expect(last_response.body).to include '503 Service Unavailable'
      expect(last_response.body).to include 'One or more of the files requested for zipping could not be fetched'
    end

    context 'when auth is OK'
      context 'streaming full files' do
        it 'attaches the correct filename and reports to upstream' do
          post '/download', fs_file_name: 'zero_files.zip', fs_uri_list: [].to_json

          expect(last_response.status).to eq 400
        end

        it 'streams the uris as a zip, stores checksums in Redis and reports to upstream' do
          r = Redis.new
          r.flushall

          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          expect_any_instance_of(UpstreamAPI).to receive(:report)

          post '/download', fs_file_name: 'three_files.zip', fs_uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin",
            "http://localhost:9293/random_bytes3.bin",
          ].to_json

          # Follow the redirect
          expect(last_response.status).to eq 303
          get (last_response.headers["Location"])

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

          post '/download', fs_file_name: 'one_file.zip', fs_uri_list: [
            "http://localhost:9293/random_bytes1.bin",
          ].to_json

          # Follow the redirect
          expect(last_response.status).to eq 303
          get (last_response.headers["Location"])
        end

        context 'when uri_list list is in array format' do
          it 'should stream uris as zip' do
            r = Redis.new
            r.flushall

            expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
              and_return({authorized: true, unauthorized_html: nil})
            expect_any_instance_of(UpstreamAPI).to receive(:report)

            post '/download', fs_file_name: 'three_files.zip', fs_uri_list: [
              "http://localhost:9293/random_bytes1.bin",
              "http://localhost:9293/random_bytes2.bin",
              "http://localhost:9293/random_bytes3.bin",
            ]

            # Follow the redirect
            expect(last_response.status).to eq 303
            get (last_response.headers["Location"])

            expect(last_response.status).to eq 200
            expect(last_response.headers["Content-Disposition"]).to eq "attachment; filename=\"three_files.zip\""
            expect(last_response.headers["Content-Length"]).to eq last_response.body.length.to_s

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
          end

          it 'should stream uris as zip if request format is json' do
            r = Redis.new
            r.flushall

            expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
              and_return({authorized: true, unauthorized_html: nil})
            expect_any_instance_of(UpstreamAPI).to receive(:report)

            post '/download', {
              fs_file_name: 'three_files.zip', 
              fs_uri_list: [
                "http://localhost:9293/random_bytes1.bin",
                "http://localhost:9293/random_bytes2.bin",
                "http://localhost:9293/random_bytes3.bin",
              ]
            }, { "ACCEPT" => "application/json" }

            # Follow the redirect
            expect(last_response.status).to eq 303
            get (last_response.headers["Location"])

            expect(last_response.status).to eq 200
            expect(last_response.headers["Content-Disposition"]).to eq "attachment; filename=\"three_files.zip\""
            expect(last_response.headers["Content-Length"]).to eq last_response.body.length.to_s
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
          end          
        end

        context 'when filename is blank' do
          it 'downloaded filename should be download.zip' do
            r = Redis.new
            r.flushall

            expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
              and_return({authorized: true, unauthorized_html: nil})
            expect_any_instance_of(UpstreamAPI).to receive(:report)

            post '/download', {
              fs_uri_list: [
                "http://localhost:9293/random_bytes1.bin",
                "http://localhost:9293/random_bytes2.bin",
                "http://localhost:9293/random_bytes3.bin",
              ]
            }, { "ACCEPT" => "application/json" }

            # Follow the redirect
            expect(last_response.status).to eq 303
            get (last_response.headers["Location"])
            expect(last_response.status).to eq 200
            expect(last_response.headers["Content-Disposition"]).to eq "attachment; filename=\"download.zip\""
            expect(last_response.headers["Content-Length"]).to eq last_response.body.length.to_s
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
          end
        end
      end

      context 'when streaming partial zips' do
        it 'returns 400 if an invalid range header is requested' do
          header 'Range', 'gimme all the bytes'
          post '/download', fs_file_name: 'files.zip', fs_uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin",
            "http://localhost:9293/random_bytes3.bin"
          ].to_json

          # Follow the redirect
          expect(last_response.status).to eq 303
          get (last_response.headers["Location"])

          expect(last_response.status).to eq 400
          expect(last_response.body).to include 'Range header must start with \'bytes=\''
        end

        it 'returns 416 if a multipart range is requested' do
          header 'Range', 'bytes=0-50, 100-150'
          post '/download', fs_file_name: 'files.zip', fs_uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin",
            "http://localhost:9293/random_bytes3.bin"
          ].to_json

          # Follow the redirect
          expect(last_response.status).to eq 303
          get (last_response.headers["Location"])

          expect(last_response.status).to eq 416
          expect(last_response.body).to include 'Multipart ranges are not supported'
        end

        it 'returns 416 if the start of the range is beyond the size of the zip' do
          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})

          header 'Range', 'bytes=123456-'
          post '/download', fs_file_name: 'files.zip', fs_uri_list: [
            "http://localhost:9293/random_bytes1.bin",
          ].to_json

          # Follow the redirect
          expect(last_response.status).to eq 303
          get (last_response.headers["Location"])

          expect(last_response.status).to eq 416
        end

        it 'falls back to whole file fetching if an inverse range is requested' do
          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          expect_any_instance_of(UpstreamAPI).to receive(:report)

          header 'Range', 'bytes=50-0'
          post '/download', fs_file_name: 'files.zip', fs_uri_list: [
            "http://localhost:9293/random_bytes1.bin",
          ].to_json

          # Follow the redirect
          expect(last_response.status).to eq 303
          get (last_response.headers["Location"])

          expect(last_response.status).to eq 200
        end

        it 'returns the whole file for range "0-"' do
          r = Redis.new
          r.flushall
          now = Time.now
          Timecop.freeze(now) # otherwise the modification times of files in the zip will differ
          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          expect_any_instance_of(UpstreamAPI).to receive(:report)

          post '/download', fs_file_name: 'files.zip', fs_uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin"
          ].to_json

          # Follow the redirect
          expect(last_response.status).to eq 303
          stream_uri = last_response.headers["Location"]
          # Save the UUID and download parameter. The succesful download would delete it but we need it
          # for the ranged request later.
          saved_uuid = stream_uri.split('/').last
          saved_params = r.get(saved_uuid)
          get stream_uri

          expect(last_response.status).to eq 200
          full_response_body = last_response.body.dup

          allow_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          allow_any_instance_of(UpstreamAPI).to receive(:report)

          # Re-set the download params:
          r.set(saved_uuid, saved_params)

          header 'Range', 'bytes=0-'
          get stream_uri
          expect(last_response.status).to eq 206
          expect(last_response.body.length).to eq full_response_body.length
          expect(last_response.body).to eq full_response_body
          Timecop.return
        end

        it 'returns ranges that can sum to the whole response' do
          r = Redis.new
          r.flushall
          Timecop.freeze(Time.now) # otherwise the modification times of files in the zip will differ
          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          expect_any_instance_of(UpstreamAPI).to receive(:report)

          post '/download', fs_file_name: 'files.zip', fs_uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin"
          ].to_json

          # Follow the redirect
          expect(last_response.status).to eq 303
          stream_uri = last_response.headers["Location"]
          # Save the UUID and download parameter. The succesful download would delete it but we need it
          # for the ranged request later.
          saved_uuid = stream_uri.split('/').last
          saved_params = r.get(saved_uuid)
          get stream_uri

          expect(last_response.status).to eq 200
          full_response_body = last_response.body.dup

          allow_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          allow_any_instance_of(UpstreamAPI).to receive(:report)

          # Re-set the download params:
          r.set(saved_uuid, saved_params)

          header 'Range', 'bytes=0-1234'
          get stream_uri

          expect(last_response.status).to eq 206
          first_partial_body = last_response.body.dup

          allow_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          allow_any_instance_of(UpstreamAPI).to receive(:report)


          header 'Range', 'bytes=1235-'
          get stream_uri

          expect(last_response.status).to eq 206
          second_partial_body = last_response.body.dup
          expect(first_partial_body + second_partial_body).to eq full_response_body

          Timecop.return
        end

        it 'returns the whole rest of the file if the end of the range is beyond the zip size' do
          r = Redis.new
          r.flushall
          now = Time.now
          Timecop.freeze(now) # otherwise the modification times of files in the zip will differ
          expect_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          expect_any_instance_of(UpstreamAPI).to receive(:report)

          post '/download', fs_file_name: 'files.zip', fs_uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin"
          ].to_json

          # Follow the redirect
          expect(last_response.status).to eq 303
          stream_uri = last_response.headers["Location"]
          # Save the UUID and download parameter. The succesful download would delete it but we need it
          # for the ranged request later.
          saved_uuid = stream_uri.split('/').last
          saved_params = r.get(saved_uuid)
          get stream_uri

          expect(last_response.status).to eq 200
          full_response_body = last_response.body.dup

          allow_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          allow_any_instance_of(UpstreamAPI).to receive(:report)
          expect(Thread).not_to receive(:new) # all checksums already known

          # Re-set the download params:
          r.set(saved_uuid, saved_params)

          header 'Range', 'bytes=0-123456'
          get stream_uri

          expect(last_response.status).to eq 206
          expect(last_response.body.length).to eq full_response_body.length
          expect(last_response.body).to eq full_response_body
          Timecop.return
        end

        it 'fetches checksums for unknown files' do
          r = Redis.new
          r.flushall
          allow_any_instance_of(UpstreamAPI).to receive(:verify_uri_list).
            and_return({authorized: true, unauthorized_html: nil})
          allow_any_instance_of(UpstreamAPI).to receive(:report)
          expect_any_instance_of(ZipStreamer).to receive(:fetch_single_checksum).exactly(2).times.and_call_original

          header 'Range', 'bytes=0-'
          post '/download', fs_file_name: 'files.zip', fs_uri_list: [
            "http://localhost:9293/random_bytes1.bin",
            "http://localhost:9293/random_bytes2.bin"
          ].to_json

          # Follow the redirect
          expect(last_response.status).to eq 303
          header 'Range', 'bytes=0-'
          get (last_response.headers["Location"])

          expect(last_response.status).to eq 206
          # The received body should be a valid zip file with three items in it and the items
          # should match the files in spec/fixtures
          tf = Tempfile.new
          tf << last_response.body
          tf.flush
          f1 = File.open(File.expand_path(__dir__ + '/../fixtures/random_bytes1.bin'),'rb') {|file| file.read}
          f2 = File.open(File.expand_path(__dir__ + '/../fixtures/random_bytes2.bin'),'rb') {|file| file.read}
          Zip::File.open(tf) do | zip |
            expect(zip.entries.length).to eq(2)
            expect(zip.entries[0].name).to eq "random_bytes1.bin"
            expect(zip.entries[0].size).to eq 1024
            expect(zip.entries[0].get_input_stream.read).to eq f1
            expect(zip.entries[1].name).to eq "random_bytes2.bin"
            expect(zip.entries[1].size).to eq 2048
            expect(zip.entries[1].get_input_stream.read).to eq f2
          end

          expect(r.dbsize).to eq 3 # 2 checksums and the download UUID
        end
      end

  end
end
