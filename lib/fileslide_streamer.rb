class FileslideStreamer < Sinatra::Base
  get "/" do
    redirect to('https://fileslide.io')
  end

  get "/healthcheck" do
    "All good\n"
  end
end
