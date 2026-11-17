#!/bin/sh
# Installs or updates duorex. It builds the newest release from source and puts it on your PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/tornikegomareli/duorex/main/install.sh | sh
#
# Run it again, or run `duorex update`, to update.
set -eu

# The whole script is one function, so the shell reads it all before it runs any of it.
# That keeps a half-downloaded script, or one replaced by its own update, from running.
main() {
  repo="${DUOREX_REPO:-https://github.com/tornikegomareli/duorex.git}"
  src="${DUOREX_SRC:-$HOME/.local/share/duorex/src}"
  bin="${DUOREX_BIN:-$HOME/.local/bin}"

  [ "$(uname -s)" = Darwin ] || fail "duorex runs on macOS only."
  [ "$(uname -m)" = arm64 ] || fail "duorex needs a Mac with Apple silicon."
  command -v git >/dev/null 2>&1 || fail "git is missing. Install the Xcode command line tools."
  command -v swift >/dev/null 2>&1 || fail "Swift is missing. Install Xcode 27.1 or later."

  if [ -d "$src/.git" ]; then
    git -C "$src" fetch --quiet --tags origin
  else
    mkdir -p "$(dirname "$src")"
    git clone --quiet "$repo" "$src"
  fi

  # The newest release, or the main branch before the first release.
  tag=$(git -C "$src" tag --list 'v*' --sort=-version:refname | head -n 1)
  target=$(git -C "$src" rev-parse "${tag:-origin/main}^{commit}")
  if [ -x "$bin/duorex" ] && [ "$(cat "$src/../installed" 2>/dev/null)" = "$target" ]; then
    echo "duorex $("$bin/duorex" version) is up to date."
    return
  fi

  echo "Building duorex ${tag:-from the main branch}. This takes about a minute."
  git -C "$src" checkout --quiet --detach "$target"
  swift build --package-path "$src" --configuration release --quiet

  # Replace the binary in one step, so a duorex that is running keeps working.
  mkdir -p "$bin"
  cp "$src/.build/release/duorex" "$bin/duorex.new"
  mv -f "$bin/duorex.new" "$bin/duorex"
  echo "$target" > "$src/../installed"

  if [ -d "$HOME/.config/rex" ]; then
    cp "$src/rex/duorex.lua" "$HOME/.config/rex/duorex.lua"
    rex_note="
Rex: the \"duorex\" action is in ~/.config/rex/duorex.lua. Load it from init.lua:
  require(\"duorex\")
  rex.bind(\"ctrl+p>i\", \"duorex\")"
  fi

  echo "Installed duorex $("$bin/duorex" version) to $bin/duorex.${rex_note:-}"
  case ":$PATH:" in
    *":$bin:"*) ;;
    *) echo "Add $bin to your PATH to run it as \`duorex\`." ;;
  esac
}

fail() {
  echo "duorex: $*" >&2
  exit 1
}

main "$@"
