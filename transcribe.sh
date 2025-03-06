#!/usr/bin/env bash

# region function definitions
installDeps() {
    # Check if whisper CLI is installed
    if ! command -v whisper &> /dev/null
    then
        echo "whisper CLI is not installed. Installing it now..."
        pip3 install openai-whisper
        if [ $? -ne 0 ]; then
            echo "Error: Failed to install whisper CLI. Please install it manually with 'pip3 install openai-whisper'."
            exit 1
        fi
    fi

    # Check if ffmpeg is installed
    if ! command -v ffmpeg &> /dev/null
    then
        echo "ffmpeg is not installed. Installing it now..."
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            sudo apt update && sudo apt install -y ffmpeg
        elif [[ "$OSTYPE" == "darwin"* ]]; then
            brew install ffmpeg
        else
            echo "Error: Unsupported OS. Please install ffmpeg manually."
            exit 1
        fi
    fi
}

transcribeAudio() {
    # Check if an argument (audio file) is provided
    if [ $# -eq 0 ]; then
        echo "Usage: $0 <audio_file>"
        exit 1
    fi

    AUDIO_FILE="$1"

    # Check if the file exists
    if [ ! -f "$AUDIO_FILE" ]; then
        echo "Error: File '$AUDIO_FILE' not found!"
        exit 1
    fi

    # Run whisper CLI to transcribe the audio
    echo "Transcribing '$AUDIO_FILE'..."
    AUDIO_DIR="$(cd "$(dirname "$AUDIO_FILE")" && pwd)"
    TRANSCRIPT_DIR="${AUDIO_DIR}/$(basename "$AUDIO_FILE" .${AUDIO_FILE##*.})_${AUDIO_FILE##*.}_transcripts"
    mkdir -p "$TRANSCRIPT_DIR"
    echo "Output files will be saved in: $TRANSCRIPT_DIR"
    whisper "$AUDIO_FILE" --model medium --output_format txt --output_dir "$TRANSCRIPT_DIR"
}

moveTranscriptFiles() {
    TRANSCRIPT_DIR="$AUDIO_DIR/$(basename "$AUDIO_FILE" | sed 's/\.[^.]*$//').transcripts"
    mkdir -p "$TRANSCRIPT_DIR"
    AUDIO_FILE="$1"
    AUDIO_DIR="$(cd "$(dirname "$AUDIO_FILE")" && pwd)"
    BASE_FILENAME=$(basename "$AUDIO_FILE" | sed 's/\.[^.]*$//')
    TRANSCRIPT_DIR="$AUDIO_DIR/$BASE_FILENAME.transcripts"
    mkdir -p "$TRANSCRIPT_DIR"
    for ext in json srt tsv txt vtt; do
        if [ -f "$BASE_FILENAME.$ext" ]; then
            mv "$BASE_FILENAME.$ext" "$TRANSCRIPT_DIR/$BASE_FILENAME.$ext"
        fi
    done
}
# endregion function definitions

main() {
    installDeps
    transcribeAudio "$1"
    # moveTranscriptFiles "$1"
}

main "$1"