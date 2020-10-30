require 'spec_helper'

RSpec.describe ZipStreamer do
  context 'when choosing filename' do
    it 'uses the content-disposition value if there is one' do
      sf = ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/coolfile.jpg',
        content_disposition: 'attachment; filename="filename.jpg"',
        size: 123,
        etag: nil)
      expect(sf.canonical_filename).to eq("filename.jpg")
    end

    it 'uses the URI basename if there is a content-disposition value but it does not contain a filename' do
      sf = ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/coolfile.jpg',
        content_disposition: 'inline',
        size: 123,
        etag: nil)
      expect(sf.canonical_filename).to eq("coolfile.jpg")
    end

    it 'uses the URI basename if there is no content-disposition value' do
      sf = ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/coolfile.jpg',
        content_disposition: nil,
        size: 123,
        etag: nil)
      expect(sf.canonical_filename).to eq("coolfile.jpg")
    end
  end

  context 'when deduplicating filenames' do
    it 'leaves the filenames as-is if they are all different' do
      zs = ZipStreamer.new
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/coolfile.jpg',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/coolfile.jpg',
        content_disposition: 'attachment; filename="first_filename.jpg"',
        size: 123,
        etag: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/coolfile.jpg',
        content_disposition: 'attachment; filename="second_filename.jpg"',
        size: 123,
        etag: nil)
      zs.deduplicate_filenames!

      expect(zs.files.map(&:zip_name).uniq.length).to eq 3
      expect(zs.files.map(&:zip_name)).to eq ["coolfile.jpg", "first_filename.jpg", "second_filename.jpg"]
    end

    it 'deduplicates filenames if multiple files have the same name' do
      zs = ZipStreamer.new
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/a/coolfile.jpg',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/b/coolfile.jpg',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/c/coolfile.jpg',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs.deduplicate_filenames!

      expect(zs.files.map(&:zip_name).uniq.length).to eq 3
      expect(zs.files.map(&:zip_name)).to eq ["a/coolfile.jpg", "b/coolfile.jpg", "c/coolfile.jpg"]
    end

    # some more examples direct from the project specifications:
    it 'deduplicates filenames if multiple files have the same name, part two' do
      zs = ZipStreamer.new
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/a/b/c/document.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/a/y/z/document.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs.deduplicate_filenames!

      expect(zs.files.map(&:zip_name).uniq.length).to eq 2
      expect(zs.files.map(&:zip_name)).to eq ["c/document.doc", "z/document.doc"]
    end

    it 'deduplicates filenames if multiple files have the same name' do
      zs = ZipStreamer.new
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/a/b/c/document.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/a/y/z/document.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data2.server1.com/a/y/z/document.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs.deduplicate_filenames!

      expect(zs.files.map(&:zip_name).uniq.length).to eq 3
      expect(zs.files.map(&:zip_name)).to eq [
        "data1.server1.com_a_b_c/document.doc",
        "data1.server1.com_a_y_z/document.doc",
        "data2.server1.com_a_y_z/document.doc",
        ]
    end
  end

  context 'when fetching checksums' do
    it 'does not fetch any extra checksums if all files are already in Redis' do
      r = Redis.new
      r.flushall
      r.set('https://data1.server1.com/document1.doc', {state: "done", etag: nil, crc32: 123}.to_json)
      r.set('https://data1.server1.com/document2.doc', {state: "done", etag: nil, crc32: 123}.to_json)
      r.set('https://data1.server1.com/document3.doc', {state: "done", etag: nil, crc32: 123}.to_json)

      zs = ZipStreamer.new
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/document1.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/document2.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/document3.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)

      expect(zs).not_to receive(:fetch_single_checksum)
      expect(zs).not_to receive(:wait_for_single_checksum)

      zs.update_files_with_checksums!
    end

    it 'will fetch checksums not in Redis yet and raises ChecksummingError if the files are not in redis after fetching' do
      r = Redis.new
      r.flushall

      zs = ZipStreamer.new
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/document1.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/document2.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/document3.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)

      expect(zs).to receive(:fetch_single_checksum).exactly(3).times

      # because we intercept `fetch_single_checksum` and don't actually fill the values in redis,
      # `update_files_with_checksums!` should raise ChecksummingError
      expect {
        zs.update_files_with_checksums!
      }.to raise_error(ZipStreamer::ChecksummingError)
    end

    it 'will poll for checksums if the state is "pending"' do
      r = Redis.new
      r.flushall
      r.set('https://data1.server1.com/document1.doc', {state: "pending"}.to_json)
      r.set('https://data1.server1.com/document2.doc', {state: "pending"}.to_json)
      r.set('https://data1.server1.com/document3.doc', {state: "pending"}.to_json)

      zs = ZipStreamer.new
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/document1.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/document2.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/document3.doc',
        content_disposition: nil,
        size: 123,
        etag: nil)

      expect(zs).to receive(:wait_for_single_checksum).exactly(3).times

      # because we intercept `fetch_single_checksum` and don't actually fill the values in redis,
      # `update_files_with_checksums!` should raise ChecksummingError
      expect {
        zs.update_files_with_checksums!
      }.to raise_error(ZipStreamer::ChecksummingError)
    end

    it 'will fetch checksums in parallel if required' do
      r = Redis.new
      r.flushall

      zs = ZipStreamer.new
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'https://data1.server1.com/document1.doc',
        content_disposition: nil,
        size: 1100 * 1024 * 1024, # big enough for three chunks
        etag: nil)

      expect(zs).to receive(:fetch_single_checksum).and_call_original
      expect(zs).to receive(:fetch_checksum_part).exactly(3).times.and_return([0,0,nil])

      zs.update_files_with_checksums!

      # Since we tightly controlled the output of fetch_checksum_part, we know what the output should be
      expect(r.get('https://data1.server1.com/document1.doc')).to eq({state: "done", etag: nil, crc32: 0}.to_json)
    end
  end
end
