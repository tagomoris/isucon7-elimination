#!/bin/bash

RACK_ENV=production bundle exec puma -p 5000 -t 10
