require 'spec_helper'

RSpec.describe ZipStreamer do
  context 'when choosing filename' do
    it 'uses the content-disposition value if there is one' do
      sf = ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/coolfile.jpg',
        content_disposition: 'attachment; filename="filename.jpg"')
      expect(sf.canonical_filename).to eq("filename.jpg")
    end

    it 'uses the URI basename if there is a content-disposition value but it does not contain a filename' do
      sf = ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/coolfile.jpg',
        content_disposition: 'inline')
      expect(sf.canonical_filename).to eq("coolfile.jpg")
    end

    it 'uses the URI basename if there is no content-disposition value' do
      sf = ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/coolfile.jpg',
        content_disposition: nil)
      expect(sf.canonical_filename).to eq("coolfile.jpg")
    end
  end

  context 'when deduplicating filenames' do
    it 'leaves the filenames as-is if they are all different' do
      zs = ZipStreamer.new
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/coolfile.jpg',
        content_disposition: nil)
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/coolfile.jpg',
        content_disposition: 'attachment; filename="first_filename.jpg"')
      zs << ZipStreamer::SingleFile.new(
        original_uri: 'http://example.com/coolfile.jpg',
        content_disposition: 'attachment; filename="second_filename.jpg"')
      zs.deduplicate_filenames!

      expect(zs.files.map(&:exposed_filename).uniq.length).to eq 3
      expect(zs.files.map(&:exposed_filename)).to eq ["coolfile.jpg", "first_filename.jpg", "second_filename.jpg"]
    end



    it 'deduplicates filenames if multiple files have the same name'
  end
end
