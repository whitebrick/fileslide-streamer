# fileslide-streamer

Package and stream files for download

- [Docs](https://hello.fileslide.io/zaas-zip-as-a-service/api/)
- [Server Setup](doc/new_server_setup.md)

## Running and setup

Install dependencies using `bundle install` and then start the server using `bundle exec rackup`. You will need correct environment variables as well. For development, `cp .env.example .env` to get a file with reasonable defaults. Both testing and running the app requires Redis. The `REDIS_URI` value in the example `.env` file will point at the one at the default location (ie `localhost`, port 6379). WARNING: The test suite will delete all values in Redis using `flushall` before each test, so make sure you don't have any important information in there.

## Testing

To run the test suite, `cd test` then run `bundle exec rspec` from the root folder of the repo. For testing the zip streaming, the test suite covers starts up a second Puma process to deliver static files from spec/fixtures. You can extend this server with extra static files or custom endpoints as needed.

## Deployment

We deploy the streamer using Capistrano. To deploy, `bundle exec cap (staging|production) deploy`, if you have the correct keypair to login to the box.
