#!/bin/bash

port=${1:-38080}

typeset CMD="ncat -lp ${port} -e ./bashttpd"
echo "${CMD}"
eval ${CMD}
