#!/usr/bin/env bash
set -Eeuo pipefail

BASE="${BASE:-/srv/heimdall/voice}"

INBOX_DIR="$BASE/inbox"
PROCESSING_DIR="$BASE/processing"
AUDIO_DIR="$BASE/audio"
NOTES_DIR="$BASE/notes"
RAW_DIR="$BASE/notes/raw"
CORRECTED_DIR="$BASE/notes/corrected"
JSON_DIR="$BASE/notes/json"
FAILED_DIR="$BASE/failed"
LOG_DIR="$BASE/logs"
TMP_DIR="$BASE/tmp"

CORRECTIONS_SCRIPT="${CORRECTIONS_SCRIPT:-$BASE/bin/apply_corrections.py}"
CORRECTIONS_RULES="${CORRECTIONS_RULES:-$BASE/config/corrections.rules}"

WHISPER_BIN="${WHISPER_BIN:-$BASE/bin/whisper-cli}"
MODEL_NAME="${MODEL_NAME:-medium}"
MODEL_PATH="${MODEL_PATH:-$BASE/models/ggml-${MODEL_NAME}.bin}"
LANGUAGE="${LANGUAGE:-hu}"
SOURCE_NAME="${SOURCE_NAME:-$(hostname -s)}"

LOG_FILE="${LOG_FILE:-$LOG_DIR/voice-stt.log}"

work_file=""
note_id=""
output_base=""
note_final=""

mkdir -p "$LOG_DIR" "$FAILED_DIR"

log() {
  local level="$1"
  local msg="$2"

  printf '%s [%s] %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$level" \
    "$msg" \
    | tee -a "$LOG_FILE" >/dev/null
}

move_work_to_failed() {
  [[ -n "${work_file:-}" && -f "$work_file" ]] || return 0

  mkdir -p "$FAILED_DIR"

  local failed_file
  failed_file="$FAILED_DIR/$(basename "$work_file").failed"

  if mv -f -- "$work_file" "$failed_file"; then
    log "ERROR" "Moved work file to failed/: $(basename "$failed_file")"
  else
    log "ERROR" "Could not move work file to failed/: $work_file"
  fi
}

cleanup_tmp_outputs() {
  [[ -n "${output_base:-}" ]] || return 0

  rm -f -- \
    "${output_base}.txt" \
    "${output_base}.json"
}

die() {
  local msg="$1"

  trap - ERR
  set +e

  log "ERROR" "$msg"
  cleanup_tmp_outputs
  move_work_to_failed

  exit 1
}

on_error() {
  local exit_code="$?"

  trap - ERR
  set +e

  log "ERROR" \
    "Processing failed: note_id=${note_id:-unknown}, exit_code=$exit_code"

  cleanup_tmp_outputs
  move_work_to_failed

  exit "$exit_code"
}

trap on_error ERR

sanitize() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9._-]/_/g; s/__*/_/g; s/^_//; s/_$//'
}

yaml_escape() {
  printf '%s' "$1" \
    | sed 's/\\/\\\\/g; s/"/\\"/g'
}

usage() {
  cat <<USAGE
Usage:
  $0 /path/to/audio.mp3

Supported input:
  mp3, wav, flac, ogg

Optional environment variables:
  BASE=/srv/heimdall/voice
  MODEL_NAME=medium|small
  MODEL_PATH=/path/to/model.bin
  LANGUAGE=hu
  SOURCE_NAME=thinclient-kitchen
  WHISPER_BIN=/path/to/whisper-cli
  CORRECTIONS_SCRIPT=/path/to/apply_corrections.py
  CORRECTIONS_RULES=/path/to/corrections.rules
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ $# -eq 1 ]] || die "Exactly one input file is required."

INPUT="$1"

[[ -f "$INPUT" ]] ||
  die "Input file not found: $INPUT"

[[ -x "$WHISPER_BIN" ]] ||
  die "whisper-cli not executable: $WHISPER_BIN"

[[ -f "$MODEL_PATH" ]] ||
  die "Model not found: $MODEL_PATH"

mkdir -p \
  "$INBOX_DIR" \
  "$PROCESSING_DIR" \
  "$AUDIO_DIR" \
  "$NOTES_DIR" \
  "$RAW_DIR" \
  "$CORRECTED_DIR" \
  "$JSON_DIR" \
  "$FAILED_DIR" \
  "$LOG_DIR" \
  "$TMP_DIR"

input_abs="$(readlink -f "$INPUT")"
input_base="$(basename "$input_abs")"
input_name="${input_base%.*}"
input_ext="${input_base##*.}"
input_ext_lc="$(printf '%s' "$input_ext" | tr '[:upper:]' '[:lower:]')"

case "$input_ext_lc" in
  mp3|wav|flac|ogg)
    ;;
  part)
    die "Refusing to process .part file: $input_base"
    ;;
  *)
    die "Unsupported file extension: .$input_ext_lc"
    ;;
esac

timestamp_file="$(date -r "$input_abs" '+%Y-%m-%d_%H%M%S')"
timestamp_human="$(date -r "$input_abs" '+%Y-%m-%d %H:%M:%S')"
month_dir="$(date -r "$input_abs" '+%Y-%m')"

source_clean="$(sanitize "$SOURCE_NAME")"
name_clean="$(sanitize "$input_name")"

note_id="${timestamp_file}_${source_clean}_${name_clean}"

work_file="$PROCESSING_DIR/${note_id}.${input_ext_lc}"
output_base="$TMP_DIR/$note_id"

raw_txt_tmp="${output_base}.txt"
json_tmp="${output_base}.json"

raw_txt_final="$RAW_DIR/${note_id}.txt"
corrected_txt_final="$CORRECTED_DIR/${note_id}.txt"
json_final="$JSON_DIR/${note_id}.json"

audio_month_dir="$AUDIO_DIR/$month_dir"
audio_final="$audio_month_dir/${note_id}.${input_ext_lc}"

note_month_dir="$NOTES_DIR/$month_dir"
note_final="$note_month_dir/${note_id}.md"

whisper_log="$LOG_DIR/${note_id}.whisper.log"
corrections_log="$LOG_DIR/${note_id}.corrections.log"

mkdir -p "$audio_month_dir" "$note_month_dir"

log "INFO" \
  "Start processing: input=$input_base note_id=$note_id model=$MODEL_NAME language=$LANGUAGE source=$SOURCE_NAME"

if [[ "$input_abs" == "$INBOX_DIR/"* ]]; then
  mv -f -- "$input_abs" "$work_file"
  log "INFO" \
    "Moved inbox file to processing: $(basename "$work_file")"
else
  cp -f -- "$input_abs" "$work_file"
  log "INFO" \
    "Copied external file to processing: $(basename "$work_file")"
fi

start_epoch="$(date +%s)"

rm -f -- \
  "$raw_txt_tmp" \
  "$json_tmp" \
  "$raw_txt_final" \
  "$corrected_txt_final" \
  "$json_final" \
  "$note_final"

"$WHISPER_BIN" \
  -m "$MODEL_PATH" \
  -f "$work_file" \
  -l "$LANGUAGE" \
  -otxt \
  -oj \
  --no-prints \
  -of "$output_base" \
  > "$whisper_log" 2>&1

[[ -f "$raw_txt_tmp" ]] ||
  die "Whisper txt output missing: $raw_txt_tmp"

if [[ -f "$json_tmp" ]]; then
  mv -f -- "$json_tmp" "$json_final"
else
  log "WARN" "Whisper json output missing: $json_tmp"
  json_final=""
fi

mv -f -- "$raw_txt_tmp" "$raw_txt_final"

transcript_for_note="$raw_txt_final"
transcript_status="raw"
correction_layer="none"
correction_count=0

if [[ -x "$CORRECTIONS_SCRIPT" && -f "$CORRECTIONS_RULES" ]]; then
  rm -f -- "$corrected_txt_final"

  if "$CORRECTIONS_SCRIPT" \
      -r "$CORRECTIONS_RULES" \
      "$raw_txt_final" \
      "$corrected_txt_final" \
      > "$corrections_log" 2>&1 \
      && [[ -f "$corrected_txt_final" ]]; then

    correction_count="$(
      awk -F= '
        /^total_replacements=/ {
          count = $2
        }
        END {
          print count + 0
        }
      ' "$corrections_log"
    )"

    transcript_for_note="$corrected_txt_final"
    transcript_status="corrected"
    correction_layer="basic-rules"

    log "INFO" \
      "Corrections applied: corrected=${corrected_txt_final#$BASE/} replacements=$correction_count"
  else
    log "WARN" \
      "Corrections failed, using raw transcript: log=${corrections_log#$BASE/}"

    rm -f -- "$corrected_txt_final"
  fi
else
  log "INFO" \
    "Correction layer not available, using raw transcript"
fi

duration=""

if command -v ffprobe >/dev/null 2>&1; then
  duration="$(
    ffprobe \
      -i "$work_file" \
      -show_entries format=duration \
      -v quiet \
      -of csv='p=0' \
      2>/dev/null \
      || true
  )"
fi

sha256=""

if command -v sha256sum >/dev/null 2>&1; then
  sha256="$(sha256sum "$work_file" | awk '{print $1}')"
fi

mv -f -- "$work_file" "$audio_final"
work_file=""

end_epoch="$(date +%s)"
elapsed="$((end_epoch - start_epoch))"

title="Voice Note - $timestamp_human"

audio_rel="${audio_final#$BASE/}"
raw_rel="${raw_txt_final#$BASE/}"

corrected_rel=""

if [[ -f "$corrected_txt_final" ]]; then
  corrected_rel="${corrected_txt_final#$BASE/}"
fi

json_rel=""

if [[ -n "${json_final:-}" && -f "$json_final" ]]; then
  json_rel="${json_final#$BASE/}"
fi

{
  printf '%s\n' '---'
  printf 'title: "%s"\n' "$(yaml_escape "$title")"
  printf 'date: "%s"\n' "$(yaml_escape "$timestamp_human")"
  printf 'source: "%s"\n' "$(yaml_escape "$SOURCE_NAME")"
  printf 'audio: "%s"\n' "$(yaml_escape "$audio_rel")"
  printf 'raw_transcript: "%s"\n' "$(yaml_escape "$raw_rel")"

  if [[ -n "$corrected_rel" ]]; then
    printf 'corrected_transcript: "%s"\n' \
      "$(yaml_escape "$corrected_rel")"
  fi

  if [[ -n "$json_rel" ]]; then
    printf 'json: "%s"\n' "$(yaml_escape "$json_rel")"
  fi

  printf 'model: "whisper.cpp-%s"\n' \
    "$(yaml_escape "$MODEL_NAME")"

  printf 'language: "%s"\n' \
    "$(yaml_escape "$LANGUAGE")"

  printf 'type: "voice-note"\n'
  printf 'transcript_status: "%s"\n' \
    "$(yaml_escape "$transcript_status")"

  if [[ "$correction_layer" != "none" ]]; then
    printf 'correction_layer: "%s"\n' \
      "$(yaml_escape "$correction_layer")"

    printf 'correction_replacements: %s\n' \
      "$correction_count"
  fi

  if [[ -n "$duration" ]]; then
    printf 'duration_seconds: "%s"\n' \
      "$(yaml_escape "$duration")"
  fi

  if [[ -n "$sha256" ]]; then
    printf 'sha256: "%s"\n' \
      "$(yaml_escape "$sha256")"
  fi

  printf 'tags:\n'
  printf '  - voice\n'
  printf '  - %s\n' "$(yaml_escape "$transcript_status")"
  printf '  - %s\n' "$(date -r "$audio_final" '+%Y-%m')"
  printf '  - %s\n' "$(yaml_escape "$source_clean")"
  printf '%s\n' '---'

  printf '\n'
  printf '# %s\n\n' "$title"

  printf 'Source: %s  \n' "$SOURCE_NAME"
  printf 'Audio: %s  \n' "$audio_rel"
  printf 'Raw transcript: %s  \n' "$raw_rel"

  if [[ -n "$corrected_rel" ]]; then
    printf 'Corrected transcript: %s  \n' "$corrected_rel"
  fi

  printf 'Model: whisper.cpp-%s  \n' "$MODEL_NAME"
  printf 'Language: %s  \n' "$LANGUAGE"

  if [[ -n "$duration" ]]; then
    printf 'Duration: %s seconds  \n' "$duration"
  fi

  printf '\n'
  printf '## Transcript\n\n'

  cat "$transcript_for_note"

  printf '\n\n'
  printf '## Processing\n\n'

  printf '%s\n' "- Status: $transcript_status"
  printf '%s\n' '- Engine: whisper.cpp'
  printf '%s\n' "- Model: $MODEL_NAME"

  if [[ "$correction_layer" != "none" ]]; then
    printf '%s\n' "- Correction layer: $correction_layer"
    printf '%s\n' "- Correction replacements: $correction_count"
  fi

  printf '%s\n' "- Processing time: $elapsed seconds"
} > "$note_final"

log "INFO" \
  "Done: note=${note_final#$BASE/} audio=${audio_final#$BASE/} raw=${raw_txt_final#$BASE/} status=$transcript_status corrections=$correction_count elapsed=${elapsed}s"

printf '%s\n' "$note_final"
