class ZipStreamer
  class SingleFile
    def initialize(original_uri: , content_disposition: )
      @original_uri = original_uri
      @content_disposition = content_disposition
    end  
  end

  def self.make_streaming_body(files: )
    ZipTricks::RackBody.new do |zip|
      start_time = Time.now.utc
      bytes_total = 0
      http = HTTP.timeout(connect: 5, read: 10).follow(max_hops: 2)
      files.each do |singlefile|
        zip.write_stored_file(singlefile.canonical_filename) do |sink|
          resp = http.get(singlefile.uri)
          resp.body.each do |chunk|
            bytes_total += chunk.size
            sink.write(chunk)
          end
        end
      end
      # after we're done, but still within the rack body, notify
      # upstream about the results
      stop_time = Time.now.utc
      UpstreamAPI.new.report(start_time: start_time, stop_time: stop_time, bytes_sent: bytes_total)
    end
  end
end
