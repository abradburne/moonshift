# Shared by the setup scripts. Everything is installed into one folder: the
# checkout these scripts sit in, or MOONSHIFT_HOME when the app sets it.
export MOONSHIFT_HOME="${MOONSHIFT_HOME:-${scripts:h}}"
mkdir -p "$MOONSHIFT_HOME"
cd "$MOONSHIFT_HOME"
export UV_CACHE_DIR="$PWD/.cache/uv"
export UV_PYTHON_INSTALL_DIR="$PWD/.runtime/python"
export HF_HOME="$PWD/.cache/huggingface"
export HF_MODULES_CACHE="$HF_HOME/modules"
export XDG_CACHE_HOME="$PWD/.cache"
export TMPDIR="$PWD/.cache/tmp"
mkdir -p "$TMPDIR" .models .runtime data/exports

# The app follows these lines to show which part of setup is running.
step() { print -r -- "@@step $1" }

# The packaged app brings its own uv, so nothing needs installing first.
if [[ -n "${MOONSHIFT_UV:-}" ]]; then
  uv() { "$MOONSHIFT_UV" "$@" }
fi

# Stops with a sentence the app can show as the reason.
need() { (( $+commands[$1] || $+functions[$1] )) || { print -r -- "$2"; exit 1 } }

# The Hugging Face CLI, borrowed through uv when it is not installed.
hf() {
  if (( $+commands[hf] )) && [[ -z "${MOONSHIFT_UV:-}" ]]; then command hf "$@"
  else uv tool run --quiet --from huggingface_hub hf "$@"
  fi
}

# Stopping setup from the app also stops the download or build in progress.
trap 'pkill -TERM -P $$ 2>/dev/null; exit 143' TERM INT
