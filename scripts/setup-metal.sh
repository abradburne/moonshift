#!/bin/zsh
# Downloads the quantized music model and, in a checkout, builds the Metal music
# engine. The packaged app ships that engine prebuilt.
set -euo pipefail
scripts="${0:A:h}"
source "$scripts/setup-common.sh"
runtime_commit=73c5554950896ce36864b6da2fb3e129c429a8a7
model_revision=cca74d8980c00f30ab8d52248a367c01ad633ec2
precision=${1:-both}
case "$precision" in
  q4) weights=('yue2-3b-q4_0.gguf');;
  q8) weights=('yue2-3b-q8_0.gguf');;
  both) weights=('yue2-3b-q8_0.gguf' 'yue2-3b-q4_0.gguf');;
  *) print 'Usage: setup-metal.sh [q4|q8|both]'; exit 1;;
esac
if [[ -z "${MOONSHIFT_PACKAGED:-}" ]]; then
need cmake 'CMake is missing. Install it with: brew install cmake'
need git "Apple's developer tools are missing. Install them with: xcode-select --install"
step engine
if [[ ! -d .runtime/audio.cpp/.git ]]; then
  git clone https://github.com/0xShug0/audio.cpp.git .runtime/audio.cpp
fi
if [[ "$(git -C .runtime/audio.cpp rev-parse HEAD)" != "$runtime_commit" ]]; then
  git -C .runtime/audio.cpp fetch origin "$runtime_commit" --depth 1
  git -C .runtime/audio.cpp checkout --detach "$runtime_commit"
fi
.venv/bin/python "$scripts/patch-metal-progress.py"
(cd .runtime/audio.cpp && scripts/build_metal.sh --build-type Release --model-set custom --models yue2 --target audiocpp_cli --deployment-target 14.0 --jobs "$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || print 4)")
fi

step music
mkdir -p .models/YuE2-GGUF
hf download audio-cpp/Yue2-3B-GGUF --revision "$model_revision" \
  --include "${weights[@]}" --include 'yue2-vae-f16.gguf' \
  --include 'sidecars/*' --include 'README.md' --local-dir .models/YuE2-GGUF --max-workers 2
print "Music engine ($precision) ready."
