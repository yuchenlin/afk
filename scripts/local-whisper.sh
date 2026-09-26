#!/usr/bin/env bash
# Runs a local Whisper speech-to-text server that AFK can use (Settings → Speech-to-text →
# "Local Whisper"). Uses whisper.cpp (Metal-accelerated) with a model from Hugging Face
# (huggingface.co/ggerganov/whisper.cpp), served in the OpenAI format at
# http://127.0.0.1:8178/v1/audio/transcriptions.
#
#   scripts/local-whisper.sh [model]     e.g. base (141 MB), small (465 MB),
#                                        large-v3-turbo-q5_0 (547 MB, best quality)
set -euo pipefail

MODEL="${1:-base}"
PORT="${AFK_WHISPER_PORT:-8178}"
DIR="$HOME/Library/Application Support/AFK/models"
FILE="$DIR/ggml-$MODEL.bin"

if ! command -v whisper-server >/dev/null; then
    echo "Installing whisper.cpp (brew install whisper-cpp)…"
    brew install whisper-cpp
fi

mkdir -p "$DIR"
if [ ! -s "$FILE" ]; then
    echo "Downloading ggml-$MODEL.bin from Hugging Face…"
    curl -fL --progress-bar -o "$FILE.part" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"
    mv "$FILE.part" "$FILE"
fi

echo "Serving $FILE on http://127.0.0.1:$PORT/v1 (Ctrl-C to stop)"
# -l auto: detect the language per recording (whisper.cpp defaults to English only).
exec whisper-server -m "$FILE" -l auto --host 127.0.0.1 --port "$PORT" \
    --inference-path /v1/audio/transcriptions
