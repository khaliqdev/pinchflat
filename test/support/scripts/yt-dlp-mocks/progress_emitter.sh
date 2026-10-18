#!/bin/bash

# Mock yt-dlp that streams progress lines to stdout while "downloading".
# Emits, in order:
#   1. a >4096-byte junk line (exercises :noeol fragment reassembly)
#   2. a JSON progress line with exact totals and Unknown speed/eta
#   3. a JSON progress line with only total_bytes_estimate
#   4. a JSON progress line with no totals at all
#   5. a JSON progress line with STRING-valued numeric fields
#   6. a WARNING on stderr (exercises stderr merging)
# then writes minimal finished JSON to the --print-to-file path and exits 0.

# Args come in the format of "<unknown number of args> --print-to-file <output template> <file location> <unknown number of args>".
# I need to extract <file location> and write the finished JSON to it.
file_location=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" == "--print-to-file" ]; then
    file_location="${@:i+2:1}"
    break
  fi
done

# 1. Single junk line longer than the 4096-byte port line buffer
long_junk=$(head -c 5000 /dev/zero | tr '\0' 'x')
echo "$long_junk"

# 2. Exact totals known; speed/eta not yet measured (yt-dlp sentinels)
echo '{"status":"downloading","downloaded_bytes":1024,"total_bytes":1048576,"_speed_str":" Unknown B/s","_eta_str":"Unknown"}'

# 3. Only an estimate is known
echo '{"status":"downloading","downloaded_bytes":524288,"total_bytes_estimate":2097152,"_speed_str":"2.00MiB/s","_eta_str":"00:30"}'

# 4. No totals at all
echo '{"status":"downloading","downloaded_bytes":2048,"_speed_str":"1.00MiB/s","_eta_str":"01:00"}'

# 5. Humanized strings where numbers would normally be
echo '{"status":"downloading","downloaded_bytes":"45.32MiB","total_bytes":"Unknown"}'

# 6. Stderr warning (merged into stdout by the runner)
echo "WARNING: [generic] This is a stderr warning" 1>&2

if [ -n "$file_location" ]; then
  echo '{"id":"abc123","title":"Finished Video","filepath":"/tmp/fake-download.mkv"}' >"$file_location"
fi

exit 0
