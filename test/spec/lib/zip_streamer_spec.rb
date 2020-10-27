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
end
