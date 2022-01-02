#!/usr/bin/env bash

if [[ $(basename $(pwd)) != "fileslide-streamer" ]]; then
  echo -e "\nError: Run this script from the top level 'fileslide-streamer' directory.\n"
  exit 1
fi

which rerun
if [ $? -ne 0 ]; then
  echo -e "\nError: The command 'rerun' could not be found.\n"
  exit 1
fi

rerun "bundle exec rackup"