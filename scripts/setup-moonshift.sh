#!/bin/zsh
# Installs what Moonshift needs to make covers: the music engine and model,
# and the transcription models. Safe to run again; finished
# downloads are reused. The app runs this from its setup screen.
#
#   setup-moonshift.sh [q4|q8|lookup]    q4: 4-bit music model (default)
#                                        q8: 8-bit music model
#                                        lookup: only optional song identification
set -euo pipefail
scripts="${0:A:h}"
source "$scripts/setup-common.sh"
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
  "$scripts/setup-metal.sh" "$precision"
  "$scripts/setup-covers.sh"
fi

step lookup
uv venv --python 3.12 .lookup-venv --allow-existing
uv pip install --python .lookup-venv/bin/python shazamio==0.8.1
print 'Moonshift is ready.'
