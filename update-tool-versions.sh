#!/usr/bin/env bash

echo "************ begin devtools ************"

# rvm gemset empty --force
rvm use
nvm use
bundle install
yarn install

echo "************ end devtools ************"
