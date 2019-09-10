#!/bin/bash

# nohup start.sh >/dev/null 2>&1 &

port=${1:-38080}

typeset CMD="ncat -4lkp ${port} -e ./bashttpd"
echo "${CMD}"
eval ${CMD}

