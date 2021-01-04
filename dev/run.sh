#!/usr/bin/env bash
unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)     machine=Linux;;
    Darwin*)    machine=Mac;;
    CYGWIN*)    machine=Cygwin;;
    MINGW*)     machine=MinGw;;
    *)          machine="UNKNOWN:${unameOut}"
esac

echo "OPERATING SYSTEM: ${machine}"
# directory=`SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"`

# echo "Directory is $directory"
if [ ${machine} = 'Mac' ]
then
  cd test/spec/fixtures
  dd if=/dev/zero of=fs_test_file-1kb-a.bin bs=1k  count=1
  dd if=/dev/zero of=fs_test_file-1kb-b.bin bs=1k  count=1
  dd if=/dev/zero of=fs_test_file-1kb-c.bin bs=1k  count=1
  dd if=/dev/zero of=fs_test_file-1mb-a.bin bs=1m  count=1
  dd if=/dev/zero of=fs_test_file-1mb-b.bin bs=1m  count=1
  dd if=/dev/zero of=fs_test_file-1mb-c.bin bs=1m  count=1
  dd if=/dev/zero of=fs_test_file-10mb-a.bin bs=10m  count=1
  dd if=/dev/zero of=fs_test_file-10mb-b.bin bs=10m  count=1
  dd if=/dev/zero of=fs_test_file-10mb-c.bin bs=10m  count=1
  dd if=/dev/zero of=fs_test_file-100mb-a.bin bs=100m  count=1
  dd if=/dev/zero of=fs_test_file-100mb-b.bin bs=100m  count=1
  dd if=/dev/zero of=fs_test_file-100mb-c.bin bs=100m  count=1
else
  cd test/spec/fixtures
  dd if=/dev/zero of=fs_test_file-1kb-a.bin bs=1K  count=1
  dd if=/dev/zero of=fs_test_file-1kb-b.bin bs=1K  count=1
  dd if=/dev/zero of=fs_test_file-1kb-c.bin bs=1K  count=1
  dd if=/dev/zero of=fs_test_file-1mb-a.bin bs=1M  count=1
  dd if=/dev/zero of=fs_test_file-1mb-b.bin bs=1M  count=1
  dd if=/dev/zero of=fs_test_file-1mb-c.bin bs=1M  count=1
  dd if=/dev/zero of=fs_test_file-10mb-a.bin bs=10M  count=1
  dd if=/dev/zero of=fs_test_file-10mb-b.bin bs=10M  count=1
  dd if=/dev/zero of=fs_test_file-10mb-c.bin bs=10M  count=1
  dd if=/dev/zero of=fs_test_file-100mb-a.bin bs=100M  count=1
  dd if=/dev/zero of=fs_test_file-100mb-b.bin bs=100M  count=1
  dd if=/dev/zero of=fs_test_file-100mb-c.bin bs=100M  count=1
fi

echo 'Launching docker containers'

echo `docker-compose up -d`

docker-compose ps

echo 'Downloading test zip'

wget --post-data 'file_name=test.zip&uri_list=[
        "http://file_server:8084/fs_test_file-10mb-a.bin",
        "http://file_server:8086/fs_test_file-100mb-a.bin","http://file_server:8086/fs_test_file-100mb-b.bin"
      ]' http://localhost:8081/download
