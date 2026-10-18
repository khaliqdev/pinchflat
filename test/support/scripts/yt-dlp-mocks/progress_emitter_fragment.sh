#!/bin/bash

# Mock yt-dlp that streams one newline-terminated progress line to stdout,
# then writes an HTTP 429 error to stderr WITHOUT a trailing newline before
# exiting 1 - exercising the trailing-:noeol-fragment flush (the fragment
# must still reach the callback and the accumulated output for 429
# detection, matching System.cmd's byte-complete output).

echo '{"status":"downloading","downloaded_bytes":1024,"total_bytes":1048576,"_speed_str":"1.00MiB/s","_eta_str":"00:10"}'

printf 'ERROR: [youtube] abc123: HTTP Error 429: Too Many Requests' 1>&2

exit 1
