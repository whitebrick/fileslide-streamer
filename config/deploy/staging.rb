set :stage, :staging
set :default_env, 'RACK_ENV' => 'staging'
set :puma_workers, 2
set :puma_threads, [0, 5]
server '3.227.183.196', user: 'ec2-user', roles: %w{web app db}
server '34.199.63.18', user: 'ec2-user', roles: %w{web app db}
