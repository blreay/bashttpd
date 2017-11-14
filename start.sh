#!/bin/bash

typeset CMD="ncat -lp 38080 -e ./bashttpd"
echo "${CMD}"
eval ${CMD}
