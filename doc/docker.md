Make sure to install docker https://docs.docker.com/get-docker/

For the first time we need to build the images first

From root folder of project execute this command
```
docker-compose -f ./dev/docker/docker-compose.yml build
```

once the build is completed

run 
```
sh ./dev/run.sh
```

to stop all the running containers

run 

```
docker-compose -f ./dev/docker/docker-compose.yml down
```

