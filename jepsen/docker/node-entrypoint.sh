#!/bin/bash
# [jepsen] A node: sshd for the control node, then the YT node as dbinvent/yt runs it
set -e
/usr/sbin/sshd
exec yt-entrypoint.sh "$@"
