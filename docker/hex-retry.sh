#!/bin/sh
set -eu

output_file=$(mktemp)
trap 'rm -f "$output_file"' EXIT

for delay in 0 60 120 240; do
    if [ "$delay" -gt 0 ]; then
        echo "Hex API rate limit exceeded; retrying in $delay seconds." >&2
        sleep "$delay"
    fi

    if "$@" >"$output_file" 2>&1; then
        cat "$output_file"
        exit 0
    else
        status=$?
        cat "$output_file" >&2
    fi

    if ! grep -Fq 'The rate limit for the Hex API has been exceeded' "$output_file"; then
        exit "$status"
    fi
done

exit "$status"
