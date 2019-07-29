#!/bin/bash

port=${1:-38080}

typeset CMD="ncat -4lkp ${port} -e ./bashttpd"
echo "${CMD}"
eval ${CMD}
