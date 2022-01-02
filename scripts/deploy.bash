# !/usr/bin/env bash

if [[ $(basename $(pwd)) != "fileslide-streamer" ]]; then
  echo -e "\nError: Run this script from the top level 'fileslide-streamer' directory.\n"
  exit 1
fi

if [[ "$1" != "staging" && "$1" != "production" ]]; then
  echo -e "\nError: Either 'staging' or 'production' must be passed as the first argument.\n"
  exit 1
fi

cmd="bundle exec cap $1 deploy"
echo -e "\n$cmd\n"
eval $cmd