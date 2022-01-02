#!/usr/bin/env bash

if [[ $(basename $(pwd)) != "fileslide-streamer" ]]; then
  echo -e "\nError: Run this script from the top level 'fileslide-streamer' directory.\n"
  exit 1
fi

cd test/file_server/
ruby file_server.rb