#!/usr/bin/env bash
# config_lib.sh — shared parsing for the line-based files in /config.

# conf_lines <file>
# Prints one entry per line. Strips CR characters, surrounding whitespace,
# full-line comments and trailing " # comments", then drops blank lines and
# repeated entries (first one wins). A missing or unreadable file, or a
# directory, yields no lines. Any other entry is passed through unchanged,
# so a typo still shows up later as a visible smartctl failure.
conf_lines() {
    local file="$1"
    [[ -f "$file" && -r "$file" ]] || return 0
    awk '
        { gsub(/\r/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+#.*$/, ""); sub(/[ \t]+$/, "") }
        $0 == "" || /^#/ { next }
        !seen[$0]++
    ' "$file"
}

# load_drives: device paths from DRIVES_FILE, one per line.
load_drives() {
    conf_lines "${DRIVES_FILE:-/config/drives.conf}"
}
