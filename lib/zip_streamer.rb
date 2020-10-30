require 'thwait'
require 'zlib'

class ZipStreamer
  CHECKSUMMING_TIMEOUT = 30 # seconds
  CHECKSUMMING_CHUNK_SIZE = 512 * 1024 * 1024 # chunk of 512 MB, about 5 sec/chunk?

  NotYetAvailable = Class.new(StandardError)
  ChecksummingError = Class.new(StandardError)
  ChecksummingTimeout = Class.new(ChecksummingError)

  attr_reader :files

  class SingleFile
    attr_reader :uri, :canonical_filename, :size, :etag
    attr_accessor :directory, :crc32

    def initialize(original_uri: , content_disposition: , size: , etag: )
      @uri = original_uri
      @content_disposition = content_disposition
      @size = size
      @etag = etag
      # The canonical filename is the one from content-disposition if it's defined or 
      # the base filename from the URI if content-disposition was not defined. Multiple
      # files can have the same canonical filename.
      if @content_disposition && @content_disposition.start_with?("attachment; filename=\"")
        # according to the spec, format must be 'attachment; filename="cool.html"'
        # so we need to strip off the first 22 characters and the ending `"`
        @canonical_filename = @content_disposition[22..-2]
      else
        @canonical_filename = File.basename(URI.parse(original_uri).path)
      end
      @directory = ""
      @crc32 = nil
    end

    def zip_name
      directory.empty? ? canonical_filename : "#{directory}/#{canonical_filename}"
    end
  end

  class StreamingBody
    def initialize(segments: , start:, stop:)
      @segments = segments
      @start = start
      @stop = stop
    end

    def each
      download_complete = false
      start_time = Time.now.utc
      bytes_total = 0
      uris_written = []
      @segments.each do |segment|
        if @stop < 0
          break # stop processing this request, we're done
        end
        if segment.size < @start
          # the range requested starts after this segment, so we can skip this
          # segment entirely
          @start -= segment.size
          @stop  -= segment.size
          next
        elsif @start == 0 && segment.size <= @stop
          # the segment is entirely within the range
          case segment
          when String
            yield segment
          when SingleFile
            http = HTTP.timeout(connect: 5, read: 10).follow(max_hops: 2)
            resp = http.get(segment.uri)
            raise HTTP::Error.new("Error when downloading #{segment.uri}") unless resp.status.success?
            uris_written << segment.uri
            resp.body.each do |chunk|
              bytes_total += chunk.size
              yield(chunk)
            end
          end
          # start remains the same (ie zero) and stop gets decremented with the amount of bytes
          # we just sent out
          @stop -= segment.size
        elsif segment.size <= @stop
          # the segment starts at a byte other than zero and runs to the end of the segment
          case segment
          when String
            yield segment[@start..-1]
          when SingleFile
            http = HTTP.timeout(connect: 5, read: 10).follow(max_hops: 2).headers({"Range" => "bytes=#{@start}-"})
            resp = http.get(segment.uri)
            raise HTTP::Error.new("Error when downloading #{segment.uri}") unless resp.status.success?
            uris_written << segment.uri
            resp.body.each do |chunk|
              bytes_total += chunk.size
              yield(chunk)
            end
          end
          # stop gets decremented by however many files we sent out, start becomes 0 because we need to continue
          # with the next segment from its start
          @stop -= (segment.size - @start)
          @start = 0
        else
          # both start and stop fall in this segment
          case segment
          when String
            yield segment[@start..@stop]
          when SingleFile
            http = HTTP.timeout(connect: 5, read: 10).follow(max_hops: 2).headers({"Range" => "bytes=#{@start}-#{@stop}"})
            resp = http.get(segment.uri)
            raise HTTP::Error.new("Error when downloading #{segment.uri}") unless resp.status.success?
            uris_written << segment.uri
            resp.body.each do |chunk|
              bytes_total += chunk.size
              yield(chunk)
            end
          end
          # we're done here!
          break
        end
      end
      download_complete = true
    rescue HTTP::Error
      # no real way to recover at this point
    ensure
      # after we're done, but still within the rack body, regardless of if there was
      # an exception, notify upstream about the results
      stop_time = Time.now.utc
      UpstreamAPI.new.report(
        uris: uris_written,
        start_time: start_time,
        stop_time: stop_time,
        bytes_sent: bytes_total,
        complete: download_complete)
    end
  end

  def initialize
    @files = []
  end

  def <<(file)
    @files << file
  end

  def deduplicate_filenames!
    # deduplication procedure:
    names_hash = Hash.new(0)
    @files.each {|f| names_hash[f.canonical_filename] += 1 }
    # any filename that occurs more than once must have a value >= 2
    duplicated_names = names_hash.filter {|k,v| v >= 2 }.keys
    duplicated_names.each do |dup_name|
      duplicated_name_files = @files.filter {|f| f.canonical_filename == dup_name}
      find_non_common_path_prefix!(duplicated_name_files) # will update the directory attribute of the files involved
    end
  end

  def compute_total_size!
    # warning: should only be called _after_ deduplication of filenames is complete; otherwise the computation
    # might give incorrect results because the filenames will change (and therefore the total size, since the
    # filenames are included in the zip file headers)
    ZipTricks::SizeEstimator.estimate do |z|
      @files.each do |singlefile|
        z.add_stored_entry(filename: singlefile.zip_name, size: singlefile.size, use_data_descriptor: true)
      end
    end
  end

  def make_complete_streaming_body
    ZipTricks::RackBody.new do |zip|
      download_complete = false
      start_time = Time.now.utc
      bytes_total = 0
      uris_written = []
      current_etag = nil
      http = HTTP.timeout(connect: 5, read: 10).follow(max_hops: 2)
      @files.each do |singlefile|
        checksummer = ZipTricks::StreamCRC32.new
        zip.write_stored_file(singlefile.zip_name) do |sink|
          resp = http.get(singlefile.uri)
          raise HTTP::Error.new("Error when downloading #{singlefile.uri}") unless resp.status.success?
          current_etag = resp.headers["ETag"]
          puts "zip.write_stored_file: ** #{singlefile.uri} => #{resp.status}\n"
          resp.body.each do |chunk|
            bytes_total += chunk.size
            checksummer << chunk
            sink.write(chunk)
          end
        end
        uris_written << singlefile.uri
        FileslideStreamer.with_redis do |redis|
          redis.set(singlefile.uri, {state: "done", etag: current_etag, crc32: checksummer.to_i}.to_json)
        end
      end
      # If an exception happens during streaming, download_complete will never
      # become true and will be reported as `false`.
      download_complete = true
    rescue HTTP::Error
      # no real way to recover at this point
    ensure
      # after we're done, but still within the rack body, regardless of if there was
      # an exception, notify upstream about the results
      stop_time = Time.now.utc
      UpstreamAPI.new.report(
        uris: uris_written,
        start_time: start_time,
        stop_time: stop_time,
        bytes_sent: bytes_total,
        complete: download_complete)
    end
  end

  def make_partial_streaming_body(start:, stop:)
    # To efficiently make a range request into a zip archive we reconstruct it first,
    # simulating the files with placeholder objects. To do this, we need to have the checksums
    # available so we fetch those first.
    update_files_with_checksums!
    # Now that everything has checksums, we can create a stream of segments:
    zip_segments = []
    string_capturer = StringIO.new
    string_capturer.set_encoding(Encoding::BINARY)
    zipstreamer = ZipTricks::Streamer.new(ZipTricks::WriteAndTell.new(string_capturer))
    @files.each do |file|
      # local header
      string_capturer.truncate(0)
      string_capturer.rewind
      zipstreamer.add_stored_entry(filename: file.zip_name, size: 0, use_data_descriptor: true) # size will be written later
      zip_segments << string_capturer.string.dup
      # the file itself
      zipstreamer.simulate_write(file.size)
      zip_segments << file
      # the data descriptor "footer" containing the checksum and sizes
      string_capturer.truncate(0)
      string_capturer.rewind
      zipstreamer.update_last_entry_and_write_data_descriptor(crc32: file.crc32, compressed_size: file.size, uncompressed_size: file.size)
      zip_segments << string_capturer.string.dup
    end
    # now the central directory and EOCD
    string_capturer.truncate(0)
    string_capturer.rewind
    zipstreamer.close
    zip_segments << string_capturer.string.dup
    # Combining the segments into a something that can be streamed and can have a range applied:
    StreamingBody.new(segments: zip_segments, start: start, stop: stop)
  end


  def update_files_with_checksums!
    files_needing_checksums = []
    files_with_pending_checksums = []
    all_uris = @files.map(&:uri)
    all_values = FileslideStreamer.with_redis do |redis|
      redis.mget(all_uris)
    end

    @files.each_with_index do |file,i|
      data = all_values[i]
      if data.nil?
        # file has never been seen yet
        files_needing_checksums << file
        next
      end
      parsed_data = JSON.parse(data, symbolize_names: true) rescue nil
      if parsed_data.fetch(:state,nil) != "done"
        # file is being processed somewhere else, possibly on another server
        files_with_pending_checksums << file
        next
      end
      if parsed_data.fetch(:etag,nil) != file.etag
        # file has been seen already, but the etag changed. Invalidate the data ASAP and queue up
        # a recalculation.
        FileslideStreamer.with_redis do |redis|
          redis.del(file.uri)
        end
        files_needing_checksums << file
        next
      end
      # we know that state == "done" at this point, so the crc must be set
      file.crc32 = parsed_data.fetch(:crc32)
    end
    # Now we dispatch as many threads as we need to find the checksums. Yes, this is potentially many threads
    # and this is usually not ideal for Ruby. However, the threads will spend the vast majority of their time sleeping
    # or waiting on I/O and therefore won't be taking up the GVL. In the case that all checksums were already known,
    # the amount of work threads needed is zero and we skip the whole thing.
    number_of_work_threads_remaining = files_with_pending_checksums.length + files_needing_checksums.length
    if number_of_work_threads_remaining > 0
      checksumming_threads = files_needing_checksums.map do |file|
        Thread.new do
          fetch_single_checksum(uri: file.uri, size: file.size)
        end
      end
      polling_threads = files_with_pending_checksums.map do |file|
        Thread.new do
          wait_for_single_checksum(uri: file.uri)
        end
      end
      timeout_thread = Thread.new { sleep CHECKSUMMING_TIMEOUT }
      waiter = ThreadsWait.new(checksumming_threads + polling_threads + [timeout_thread])
      # number_of_work_threads_remaining starts out as the total number of threads waited on minus one (the timeout thread)
      # Every time a thread finishes there are a few options:
      # - It's the timeout thread. This means the whole operation has timed out. We raise ChecksummingTimeout and return 500; the
      #   other threads have timeouts as well and will finish in due course.
      # - It's a work thread and there's more work since number_of_work_threads_remaining is higher than zero. Continue the loop
      # - It's a work thread and number_of_work_threads_remaining is zero. The only remaining thread must be the timeout thread
      #   so we finish and just let the timeout thread be.
      while number_of_work_threads_remaining > 0
        t = waiter.next_wait
        raise ChecksummingTimeout.new if t == timeout_thread
        number_of_work_threads_remaining -= 1
      end

      # Now all checksum-related threads are done and the checksums for each file SHOULD be in redis. If this is not the case
      # for any of them, some of them errored out.
      all_values = FileslideStreamer.with_redis do |redis|
        redis.mget(all_uris)
      end
      @files.each_with_index do |file,i|
        data = all_values[i]
        parsed_data = JSON.parse(data, symbolize_names: true) rescue nil
        raise ChecksummingError if parsed_data.nil?
        raise ChecksummingError unless parsed_data.fetch(:state,nil) == "done"
        # we know that state == "done" at this point, so the crc must be set
        file.crc32 = parsed_data.fetch(:crc32)
      end
    end
  end

  # This method is called inside a separate thread when the state for a certain URI was "pending". This means that another
  # thread is already checksumming the file. To prevent multiple downloads etc, we don't re-download the thread but rather just
  # poll the redis until the value becomes available (when checksumming finishes succesfully) or becomes `nil` (when checksumming
  # failed)
  def fetch_single_checksum(uri:, size: )
    try_claim_key = FileslideStreamer.with_redis do |redis|
      redis.set(uri, {state: "pending"}.to_json, ex: CHECKSUMMING_TIMEOUT, nx: true)
    end
    if try_claim_key
      begin
        ranges = RangeUtils.split_range_into_subranges_of(0..(size-1), CHECKSUMMING_CHUNK_SIZE)
        threads = ranges.map do |range|
          Thread.new { fetch_checksum_part(uri: uri,range: range) }
        end
        results = threads.map(&:value)
        checksum = results.reduce(Zlib.crc32('')) {|acc,n| Zlib.crc32_combine(acc,n[0], n[1]) }
        etag = results.first[2]
        FileslideStreamer.with_redis do |redis|
          redis.set(uri, {state: "done", etag: etag, crc32: checksum}.to_json)
        end
      rescue Exception => e
        # Something went wrong; we should try to relinquish our claim on the Redis key as soon as possible
        # so that another request won't be stuck waiting for it. Also, while usually it's not a good idea to
        # rescue Exception directly instead of StandardError, we reraise it so it should be fine.
        FileslideStreamer.with_redis do |redis|
          redis.del(uri)
        end
        raise e
      end
    else
      # between the time we first checked and now, another request already claimed this key and
      # spun off a thread to calculate the checksum. Instead of computing it another time we poll the
      # redis instead, just as if it had already been set during the first check.
      wait_for_single_checksum(uri: uri)
    end
  end

  def fetch_checksum_part(uri:, range: )
    checksummer = ZipTricks::StreamCRC32.new
    http = HTTP.timeout(connect: 5, read: 10).follow(max_hops: 2).headers({"Range" => "bytes=#{range.begin}-#{range.end}"})
    resp = http.get(uri)
    raise HTTP::Error.new("Error when downloading #{singlefile.uri}") unless resp.status.success?
    resp.body.each do |chunk|
      checksummer << chunk
    end
    [checksummer.to_i, RangeUtils.size_from_range(range), resp.headers["ETag"]]
  end

  # This method is called inside a separate thread when the state for a certain URI was "pending". This means that another
  # thread is already checksumming the file. To prevent multiple downloads etc, we don't re-download the thread but rather just
  # poll the redis until the value becomes available (when checksumming finishes succesfully) or becomes `nil` (when checksumming
  # failed)
  def wait_for_single_checksum(uri:)
    # Try every 2 seconds for 30 seconds, with random jitter applied so that many threads don't stampede the Redis
    Retriable.retriable(on: NotYetAvailable, base_interval: 2, multiplier: 1, tries: 20, max_elapsed_time: 30) do
      data = FileslideStreamer.with_redis do |redis|
        redis.get(uri)
      end
      parsed_data = JSON.parse(data, symbolize_names: true)
      if parsed_data.fetch[:state] == "pending"
        raise NotYetAvailable.new
      end
      # if the key was nil, the checksumming failed for some reason and we have no reason to believe retrying would help
      # if the state was anything other than "pending", the checksumming thread is done and on the next pass we'll finish
      # in either case we are done with checking redis and can let the thread finish
    end
  rescue TypeError
    # Thrown when trying to json parse a `nil`. See comments above.
  end

  def find_non_common_path_prefix!(files)
    # so here we have a couple of files with a common filename
    # This implies that the paths (including hostname) must not be the same
    # Finding the first non-common postfix of a set of arrays is equal to the longest common prefix
    # of the reversed arrays, plus one element (which is by definition )

    # convert from http://example.com/a/coolfile.jpg to ["a", "example.com", "", "http:"]
    # Drop the filename before we go since that is already known to be a duplicate
    # and in any case it might have come from the content-disposition header and not the URI.
    split_file_URI_paths = files.map {|f| f.uri.split("/")[0..-2].reverse }
    number_of_duplicates = split_file_URI_paths.length
    # iterate until we find a prefix length where they're all different
    index = 0
    index += 1 until split_file_URI_paths.map{|sp| sp.take(index)}.uniq.length == number_of_duplicates
    # using the length we found, set the directory of each file while replacing slashes with underscores
    files.each do |f|
      f.directory = f.uri.split("/")[(-1-index)..-2].join("_")
    end
  end
end
