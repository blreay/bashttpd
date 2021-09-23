#!/bin/bash

# nohup start.sh >/dev/null 2>&1 &

port=${1:-38080}

if ! type tree >/dev/null 2>&1; then
  echo "tree is not installed. please install tree: yum install -y tree"
fi

typeset CMD="ncat -4lkp ${port} -e ./bashttpd"
echo "${CMD}"
eval ${CMD}

