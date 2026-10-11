#!/bin/zsh
# Installs what Moonshift needs to make covers: the service, the music engine
# and model, and the transcription models. Safe to run again; finished
# downloads are reused. The app runs this from its setup screen.
#
#   setup-moonshift.sh [q4|q8|lookup]    q4: 4-bit music model (default)
#                                        q8: 8-bit music model
#                                        lookup: only optional song identification
set -euo pipefail
cd "${0:A:h:h}"
source scripts/setup-common.sh
precision=${1:-q4}
case "$precision" in q4|q8|lookup) ;; *) print 'Usage: setup-moonshift.sh [q4|q8|lookup]'; exit 1;; esac

if [[ -n "${MOONSHIFT_INSTALL_TOOLS:-}" ]]; then
  step tools
  need brew 'Homebrew is needed to install the missing tools. See https://brew.sh'
  brew install ${=MOONSHIFT_INSTALL_TOOLS}
  rehash
fi
need uv 'uv is missing. Install it with: brew install uv'

if [[ "$precision" != lookup ]]; then
  need ffmpeg 'FFmpeg is missing. Install it with: brew install ffmpeg'
  need cmake 'CMake is missing. Install it with: brew install cmake'
  need git "Apple's developer tools are missing. Install them with: xcode-select --install"
  step service
  [[ -x .venv/bin/python ]] || uv venv --python 3.12 .venv
  uv pip install --python .venv/bin/python fastapi==0.143.0 uvicorn==0.54.0 httpx==0.28.1 psutil==7.2.2 numpy==2.2.6 soundfile==0.13.1
  ./scripts/setup-metal.sh "$precision"
  ./scripts/setup-covers.sh
fi

step lookup
uv venv --python 3.12 .lookup-venv --allow-existing
uv pip install --python .lookup-venv/bin/python shazamio==0.8.1
print 'Moonshift is ready.'
