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
  # /usr/bin/swift and /usr/bin/git always exist: they are stand-ins that ask Xcode for the tool.
  xcrun --find swift >/dev/null 2>&1 || fail "Swift is missing. Install Xcode 27.1 or later."

  if [ -d "$src/.git" ]; then
    # Forced, so a release tag that moved upstream cannot stop every later update.
    git -C "$src" fetch --quiet --force --tags --prune --prune-tags origin
  else
    mkdir -p "$(dirname "$src")"
    git clone --quiet "$repo" "$src"
  fi

  # The newest release, or the main branch before the first release. Only tags of the form
  # v1.2.3 are releases: any other tag, a release candidate included, is passed over.
  tag=$(git -C "$src" tag --list 'v*' --sort=-version:refname | grep -Ex 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
  target=$(git -C "$src" rev-parse "${tag:-origin/main}^{commit}")
  if [ -x "$bin/duorex" ] && [ "$(cat "$src/../installed" 2>/dev/null)" = "$target" ]; then
    install_rex_action
    install_skill
    echo "duorex $("$bin/duorex" version) is up to date.${rex_note:-}${skill_note:-}"
    return
  fi

  echo "Building duorex ${tag:-from the main branch}. This takes about a minute."
  # Forced, because the checkout is the installer's own: an edit in it must not block an update.
  git -C "$src" checkout --quiet --force --detach "$target"
  if ! output=$(swift build --package-path "$src" --configuration release 2>&1); then
    echo "$output" >&2
    fail "the build failed. duorex needs Xcode 27.1 or later."
  fi

  # Replace the binary in one step, so a duorex that is running keeps working.
  mkdir -p "$bin"
  cp "$src/.build/release/duorex" "$bin/duorex.new"
  mv -f "$bin/duorex.new" "$bin/duorex"
  echo "$target" > "$src/../installed"
  install_rex_action
  install_skill

  echo "Installed duorex $("$bin/duorex" version) to $bin/duorex.${rex_note:-}${skill_note:-}"
  case ":$PATH:" in
    *":$bin:"*) ;;
    *) echo "Add $bin to your PATH to run it as \`duorex\`." ;;
  esac
}

# Puts the Rex action where Rex looks for it, when Rex is set up. It runs on every install and
# update, so setting Rex up later and running the installer again is enough.
install_rex_action() {
  rex_note=
  [ -d "$HOME/.config/rex" ] || return 0
  if ! cmp -s "$src/rex/duorex.lua" "$HOME/.config/rex/duorex.lua"; then
    cp "$src/rex/duorex.lua" "$HOME/.config/rex/duorex.lua"
    rex_note="
Rex: the \"duorex\" action is in ~/.config/rex/duorex.lua. Load it from init.lua:
  require(\"duorex\")
  rex.bind(\"ctrl+p>i\", \"duorex\")"
  fi
}

# Gives each agent on this Mac the skill that tells it how to run an app on the Duo. An agent
# counts as present when its folder exists.
install_skill() {
  skill_note=
  for agent in "$HOME/.claude" "$HOME/.codex" "$HOME/.pi/agent"; do
    [ -d "$agent" ] || continue
    if ! cmp -s "$src/skills/duorex/SKILL.md" "$agent/skills/duorex/SKILL.md"; then
      mkdir -p "$agent/skills/duorex"
      cp "$src/skills/duorex/SKILL.md" "$agent/skills/duorex/SKILL.md"
      skill_note="$skill_note
Skill: $agent/skills/duorex"
    fi
  done
}

fail() {
  echo "duorex: $*" >&2
  exit 1
}

main "$@"
