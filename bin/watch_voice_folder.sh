#!/usr/bin/env bash
set -Eeuo pipefail

BASE="${BASE:-/srv/heimdall/voice}"

WATCH_DIR="${WATCH_DIR:-$BASE/inbox}"
SOURCE_NAME="${SOURCE_NAME:-voice-folder}"

PROCESS_SCRIPT="${PROCESS_SCRIPT:-$BASE/bin/process_voice_note.sh}"

LOG_DIR="$BASE/logs"

sanitize() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9._-]/_/g; s/__*/_/g; s/^_//; s/_$//'
}

SOURCE_CLEAN="$(sanitize "$SOURCE_NAME")"

LOG_FILE="${LOG_FILE:-$LOG_DIR/watch-${SOURCE_CLEAN}.log}"
STATE_FILE="${STATE_FILE:-$LOG_DIR/watch-${SOURCE_CLEAN}.processed.sha256}"

mkdir -p "$LOG_DIR"
touch "$STATE_FILE"

log() {
  local level="$1"
  local msg="$2"
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" | tee -a "$LOG_FILE"
}

acquire_lock() {
  LOCK_DIR="${LOCK_DIR:-$LOG_DIR/watch-${SOURCE_CLEAN}.lock}"

  if [[ -d "$LOCK_DIR" ]]; then
    if [[ -f "$LOCK_DIR/pid" ]] && kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
      log "ERROR" "Watcher already running: source=$SOURCE_NAME lock=$LOCK_DIR pid=$(cat "$LOCK_DIR/pid")"
      exit 1
    fi

    log "WARN" "Removing stale lock: $LOCK_DIR"
    rm -rf "$LOCK_DIR"
  fi

  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "ERROR" "Could not acquire watcher lock: $LOCK_DIR"
    exit 1
  fi

  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
}

is_audio_file() {
  local file="$1"
  local ext="${file##*.}"
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"

  case "$ext" in
    mp3|wav|flac|ogg)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_ignored_file() {
  local file="$1"
  local base
  base="$(basename "$file")"

  case "$base" in
    .*|*.part|*.tmp|*.crdownload|*.sync|*.syncthing*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

wait_until_stable() {
  local file="$1"
  local previous_size="-1"
  local current_size="-2"

  for _ in {1..10}; do
    [[ -f "$file" ]] || return 1

    current_size="$(stat -c '%s' "$file" 2>/dev/null || echo -1)"

    if [[ "$current_size" == "$previous_size" && "$current_size" -gt 0 ]]; then
      return 0
    fi

    previous_size="$current_size"
    sleep 2
  done

  return 1
}

already_processed() {
  local sha="$1"
  grep -q "^${sha} " "$STATE_FILE"
}

mark_processed() {
  local sha="$1"
  local file="$2"
  printf '%s  %s  %s\n' "$sha" "$(date '+%Y-%m-%d %H:%M:%S')" "$file" >> "$STATE_FILE"
}

process_one() {
  local file="$1"

  [[ -f "$file" ]] || return 0

  if is_ignored_file "$file"; then
    log "INFO" "Ignored temp/hidden file: $file"
    return 0
  fi

  if ! is_audio_file "$file"; then
    log "INFO" "Ignored non-audio file: $file"
    return 0
  fi

  log "INFO" "Detected audio file: $file"

  if ! wait_until_stable "$file"; then
    log "WARN" "File did not become stable, skipping for now: $file"
    return 0
  fi

  local sha
  sha="$(sha256sum "$file" | awk '{print $1}')"

  if already_processed "$sha"; then
    log "INFO" "Already processed, skipping: $file"
    return 0
  fi

  log "INFO" "Processing audio: source=$SOURCE_NAME file=$file"

  if SOURCE_NAME="$SOURCE_NAME" "$PROCESS_SCRIPT" "$file"; then
    mark_processed "$sha" "$file"
    log "INFO" "Processing done: $file"
  else
    log "ERROR" "Processing failed: $file"
  fi
}

initial_scan() {
  log "INFO" "Initial scan started: source=$SOURCE_NAME watch_dir=$WATCH_DIR"

  find "$WATCH_DIR" -maxdepth 1 -type f \( \
    -iname '*.mp3' -o \
    -iname '*.wav' -o \
    -iname '*.flac' -o \
    -iname '*.ogg' \
  \) -print0 | while IFS= read -r -d '' file; do
    process_one "$file"
  done

  log "INFO" "Initial scan finished"
}

watch_loop() {
  log "INFO" "Watching folder: source=$SOURCE_NAME watch_dir=$WATCH_DIR"

  inotifywait -m \
    -e close_write,moved_to \
    --format '%w%f' \
    "$WATCH_DIR" | while IFS= read -r file; do
      process_one "$file"
    done
}

[[ -d "$WATCH_DIR" ]] || {
  log "ERROR" "Watch directory does not exist: $WATCH_DIR"
  exit 1
}

[[ -x "$PROCESS_SCRIPT" ]] || {
  log "ERROR" "Process script is not executable: $PROCESS_SCRIPT"
  exit 1
}

acquire_lock
initial_scan
watch_loop
