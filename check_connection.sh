#!/bin/sh
TIMEOUT=5
# telnet to the specified destination/port
nc -w $TIMEOUT -z $1 $2
if $?; then
	exit 0
else
	exit 1
fi
