require 'spec_helper'

RSpec.describe ZipStreamer do
  context 'when choosing filename' do
    it 'uses the content-disposition value if there is one'
    it 'uses the URI basename if there is no content-disposition value'
  end

  context 'when deduplicating filenames' do
    it 'leaves the filenames as-is if they are all different'
    it 'deduplicates filenames if multiple files have the same name'
  end
end