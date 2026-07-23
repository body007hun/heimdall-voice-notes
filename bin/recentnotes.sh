#!/usr/bin/env bash
set -Eeuo pipefail

BASE="${BASE:-/srv/heimdall/voice}"
NOTES_DIR="$BASE/notes"

if [[ ! -d "$NOTES_DIR" ]]; then
  printf 'Hiba: notes mappa nem található: %s\n' "$NOTES_DIR" >&2
  exit 1
fi

if pgrep -f "$BASE/bin/process_voice_note.sh" >/dev/null 2>&1; then
  printf '%s\n' "Megjegyzés: jelenleg is folyik hangjegyzet-feldolgozás."
  printf '%s\n\n' "A lent látható fájl a legutóbbi már elkészült jegyzet."
fi

RECENT="$(
  find "$NOTES_DIR" \
    -type f \
    -name '*.md' \
    -printf '%T@ %p\n' \
    | sort -nr \
    | head -n 1 \
    | cut -d' ' -f2-
)"

if [[ -z "$RECENT" || ! -f "$RECENT" ]]; then
  printf 'Nem található elkészült Markdown jegyzet.\n' >&2
  exit 1
fi

printf 'Legutóbbi jegyzet:\n%s\n\n' "$RECENT"

printf '%s\n' '===== METADATA ====='

grep -E \
  '^(title|date|source|audio|raw_transcript|corrected_transcript|model|language|transcript_status|correction_layer|correction_replacements|duration_seconds):' \
  "$RECENT" \
  || true

printf '\n%s\n' '===== TRANSCRIPT ÉS FELDOLGOZÁS ====='

sed -n '/^## Transcript/,$p' "$RECENT"
