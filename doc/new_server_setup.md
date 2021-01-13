# New Server Setup

Copy keys from existing server
```
scp ec2-user@3.227.183.196:/home/ec2-user/.ssh/id_rsa .
scp ec2-user@3.227.183.196:/home/ec2-user/.ssh/id_rsa.pub .
scp id_rsa id_rsa.pub ec2-user@<new server>:/home/ec2-user/.ssh/
<on new server> $ cat .ssh/id_rsa.pub >> .ssh/authorized_keys
<on new server> chmod 600 ~/.ssh/id_rsa; chmod 600 ~/.ssh/id_rsa.pub
```

```
sudo yum install -y git-core zlib zlib-devel gcc-c++ patch readline readline-devel libyaml-devel libffi-devel openssl-devel make bzip2 autoconf automake libtool bison curl sqlite-devel

# Install rbenv and ruby
git clone git://github.com/sstephenson/rbenv.git .rbenv
echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bash_profile
echo 'eval "$(rbenv init -)"' >> ~/.bash_profile
. .bash_profile

git clone git://github.com/sstephenson/ruby-build.git ~/.rbenv/plugins/ruby-build
echo 'export PATH="$HOME/.rbenv/plugins/ruby-build/bin:$PATH"' >> ~/.bash_profile
. .bash_profile
rbenv install 2.6.6
rbenv global 2.6.6
gem install bundler
git clone git@github.com:whitebrick/fileslide-streamer.git

# Install 
sudo amazon-linux-extras install nginx1
sudo systemctl start nginx
sudo systemctl enable nginx
sudo systemctl status nginx # to check it's working
cd /etc/nginx/conf.d/

sudo nano reverse-proxy.conf

server {
	server_name stream.fileslide-staging.io;
  access_log /var/log/nginx/reverse-access.log;
  error_log /var/log/nginx/reverse-error.log;
  proxy_buffering off;
	# By default the Connection header is passed to the origin. If a client sends a request with Connection: close, Nginx would send this to the upstream, effectively disabling keepalive. By clearing this header, Nginx will not send it on to the upstream source, leaving it to send its own Connection header as appropriate.	
	proxy_set_header Connection "";
  proxy_http_version 1.1;
  location / {
	  if ($request_method = 'POST') {
      add_header 'Access-Control-Allow-Origin' '*';
      add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
      add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
      add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
    }
    proxy_pass http://127.0.0.1:9292;
  }
  listen 80;
  listen [::]:80;
}

sudo systemctl restart nginx
# Now verify you can reach it with curl on port 80.

# Setup a keypair for github (skip - currently using same key for all instances)
# see https://docs.github.com/en/free-pro-team@latest/github/authenticating-to-github/connecting-to-github-with-ssh
# Add the public key to the repo as a "deploy key" in the settings part of the repo
# in the end, verify you can ssh to github from the repo. You are now done on the server itself.

# On your own box, setup ssh so that you can login to the box as the required user (default is `ec2-user`)
# without needing to supply any password. Capistrano will need this later. To get it setup, add config
# for the box to ~/.ssh/config.

# Add the ip of the new server to config/deploy/production|staging.rb

bundle exec cap production|staging deploy
<on new server> scp 3.227.183.196:/home/ec2-user/fileslide-streamer/shared/.env /home/ec2-user/fileslide-streamer/shared/.env
bundle exec cap production|staging puma:config
bundle exec cap production|staging deploy

# Test
curl -v http://localhost:9292/healthcheck
```