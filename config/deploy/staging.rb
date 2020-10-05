set :stage, :staging
set :default_env, 'RACK_ENV' => 'staging'
server 'stream.fileslide-staging.io', user: 'ec2-user', roles: %w{web app db}
