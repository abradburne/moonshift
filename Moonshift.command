#!/bin/zsh
# Double-click to open Moonshift, building it first if needed.
# The app installs its own models on first launch.
set -euo pipefail
cd "${0:A:h}"
[[ -d build/Moonshift.app ]] || ./scripts/build-moonshift.sh
open build/Moonshift.app
