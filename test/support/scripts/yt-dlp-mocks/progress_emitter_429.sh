#!/bin/bash

# Mock yt-dlp that streams one progress line to stdout, then fails with an
# HTTP 429 on stderr (exercising 429 detection on the streaming/port path).

echo '{"status":"downloading","downloaded_bytes":1024,"total_bytes":1048576,"_speed_str":"1.00MiB/s","_eta_str":"00:10"}'

echo "ERROR: [youtube] abc123: HTTP Error 429: Too Many Requests. Sign in to confirm you are not a bot" 1>&2

exit 1
