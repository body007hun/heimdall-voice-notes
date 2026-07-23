#!/usr/bin/env bash
set -Eeuo pipefail

BASE="${BASE:-/srv/heimdall/voice}"

export WATCH_DIR="${WATCH_DIR:-/mnt/raid/backup/dcim_backup/hang}"
export SOURCE_NAME="${SOURCE_NAME:-phone-syncthing}"

# Preserve the existing phone watcher history and log filenames.
export LOG_FILE="${LOG_FILE:-$BASE/logs/phone-import.log}"
export STATE_FILE="${STATE_FILE:-$BASE/logs/phone-import.processed.sha256}"

exec "$BASE/bin/watch_voice_folder.sh"
