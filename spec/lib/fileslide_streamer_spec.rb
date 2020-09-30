require 'spec_helper.rb'

RSpec.describe FileslideStreamer do
  def app
    FileslideStreamer.new
  end

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
