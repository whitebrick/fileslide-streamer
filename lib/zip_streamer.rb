class ZipStreamer
  attr_reader :files

  class SingleFile
    attr_reader :uri, :canonical_filename
    attr_accessor :directory

    def initialize(original_uri: , content_disposition: )
      @uri = original_uri
      @content_disposition = content_disposition
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
    end

    def zip_name
      directory.empty? ? canonical_filename : "#{directory}/#{canonical_filename}"
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

  def make_streaming_body
    ZipTricks::RackBody.new do |zip|
      download_complete = false
      start_time = Time.now.utc
      bytes_total = 0
      http = HTTP.timeout(connect: 5, read: 10).follow(max_hops: 2)
      @files.each do |singlefile|
        zip.write_stored_file(singlefile.zip_name) do |sink|
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
    rescue HTTP::Error
      # no real way to recover at this point
    ensure
      # after we're done, but still within the rack body, regardless of if there was
      # an exception, notify upstream about the results
      stop_time = Time.now.utc
      UpstreamAPI.new.report(
        start_time: start_time,
        stop_time: stop_time,
        bytes_sent: bytes_total,
        complete: download_complete)
    end
  end

  private

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
