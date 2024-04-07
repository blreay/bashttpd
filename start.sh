#!/bin/bash

# nohup start.sh >/dev/null 2>&1 &

typeset daemon=0

unset OPTIND
while getopts :d ch; do
  case $ch in
    d) daemon=1;;
  esac
done
shift $((OPTIND-1))

typeset port=${1:-38080}
echo "port=${port} daemon=${daemon}"

if ! type tree >/dev/null 2>&1; then
  echo "tree is not installed. please install tree: yum install -y tree"
fi

if [[ ${daemon} -eq 1 ]]; then
  nohup ./start.sh ${port} > /dev/null 2>&1 &
else
  typeset CMD="ncat -4lkp ${port} -e ./bashttpd"
  echo "${CMD}"
  eval ${CMD}
fi

