#!/usr/bin/env bash

if [[ $(basename $(pwd)) != "fileslide-streamer" ]]; then
  echo -e "\nError: Run this script from the top level 'fileslide-streamer' directory.\n"
  exit 1
fi

brew services start redis
redis-cli ping