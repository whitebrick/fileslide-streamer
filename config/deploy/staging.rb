set :stage, :staging
set :default_env, 'RACK_ENV' => 'staging'
server '3.87.220.24', user: 'ec2-user', roles: %w{web app db}