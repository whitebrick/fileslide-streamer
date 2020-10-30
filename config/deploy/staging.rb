set :stage, :staging
set :default_env, 'RACK_ENV' => 'staging'
set :puma_workers, 2
set :puma_threads, [0, 5]
server 'stream.fileslide-staging.io', user: 'ec2-user', roles: %w{web app db}
