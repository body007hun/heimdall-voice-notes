# Heimdall Voice Notes

Local-first voice note pipeline for Heimdall.

Phone or thin client records audio, Syncthing or rsync delivers it to the server, whisper.cpp transcribes it, and the server generates Markdown notes for a future Heimdall Library / RAG workflow.

## Current status

- Phone → Syncthing → server pipeline
- whisper.cpp medium model
- Hungarian transcription
- Markdown note generation
- Raw txt and JSON output
- Audio archive
- SHA256-based duplicate detection
- Watch folder importer

## Directory layout

/srv/heimdall/voice/
├── audio/
├── bin/
├── config/
├── failed/
├── inbox/
├── logs/
├── models/
├── notes/
├── processing/
└── tmp/

## Requirements

Arch Linux server:

sudo pacman -S --needed git cmake make gcc ffmpeg inotify-tools

whisper.cpp must be built separately and linked as:

bin/whisper-cli -> /path/to/whisper.cpp/build/bin/whisper-cli

## Model example:

models/ggml-medium.bin

## Phone watcher

Copy the example config:

cp config/phone-watch.env.example config/phone-watch.env

Edit:

nano config/phone-watch.env

Run manually:

source config/phone-watch.env
bin/watch_phone_voice.sh

## Process one file manually
SOURCE_NAME=manual-test bin/process_voice_note.sh /path/to/audio.mp3

## Output

Generated Markdown notes are written under:

notes/YYYY-MM/

Each note includes:

source
audio path
raw transcript path
JSON path
model
language
duration
sha256
transcript
processing metadata
