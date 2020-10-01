class ZipStreamer
  class SingleFile
    attr_reader :uri
    attr_accessor :canonical_filename

    def initialize(original_uri: , content_disposition: )
      @uri = original_uri
      @content_disposition = content_disposition
      if @content_disposition && @content_disposition.start_with?("attachment; filename=\"")
        # according to the spec, format must be 'attachment; filename="cool.html"'
        # so we need to strip off the first 22 characters and the ending `"`
        @canonical_filename = @content_disposition[22..-2]
      else
        @canonical_filename = File.basename(URI.parse(original_uri).path)
      end

    end
  end

  def initialize
    @files = []
  end

  def <<(file)
    @files << file
  end

  def make_streaming_body
    ZipTricks::RackBody.new do |zip|
      download_complete = false
      start_time = Time.now.utc
      bytes_total = 0
      http = HTTP.timeout(connect: 5, read: 10).follow(max_hops: 2)
      @files.each do |singlefile|
        zip.write_stored_file(singlefile.canonical_filename) do |sink|
          resp = http.get(singlefile.uri)
          resp.body.each do |chunk|
            bytes_total += chunk.size
            sink.write(chunk)
          end
        end
      end
      # If an exception happens during streaming, download_complete will never
      # become true and will be reported as `false`.
      download_complete = true
    ensure
      # after we're done, but still within the rack body, notify
      # upstream about the results
      stop_time = Time.now.utc
      UpstreamAPI.new.report(
        start_time: start_time,
        stop_time: stop_time,
        bytes_sent: bytes_total,
        complete: download_complete)
    end
  end
end
