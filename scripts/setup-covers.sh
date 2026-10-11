#!/bin/zsh
# Installs reference transcription: its own Python environment and models.
set -euo pipefail
cd "${0:A:h:h}"
source scripts/setup-common.sh
need ffmpeg 'FFmpeg is missing. Install it with: brew install ffmpeg'

step transcriber-runtime
uv venv --python 3.11 .covers-venv --allow-existing
uv pip install --python .covers-venv/bin/python torch==2.8.0 torchaudio==2.8.0 transformers==4.45.2 huggingface-hub==0.36.0 safetensors==0.5.3 numpy==1.24.3 scipy==1.13.1 mir_eval==0.8.2 pretty_midi==0.2.10 mido==1.3.3 setuptools==78.1.1 soundfile==0.13.1

step transcriber
hf download m-a-p/SheetSage2 --revision 32c7c7473e7b59e1ed36bd8a8fefbd11ae8d468a --include '*.py' --include '*.json' --include '*.safetensors' --include 'LICENSE' --include 'THIRD_PARTY_NOTICES.md' --local-dir .models/SheetSage2 --max-workers 4
hf download m-a-p/MERT-v2-FullSong --revision d8ba1c745e733b3908ce6ad16ebeb17ac7600a42 --include '*.py' --include 'config.json' --include '*.safetensors' --include 'LICENSE' --include 'THIRD_PARTY_NOTICES.md' --local-dir .models/MERT-v2-FullSong --max-workers 4
print 'Transcription ready. It runs on the CPU and unloads before rendering.'
