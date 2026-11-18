#!/bin/sh
# Releases the version that Sources/duorex/Release.swift names. It checks that the repository
# is ready, tags the commit, and publishes the release with its notes from CHANGELOG.md.
#
#   scripts/release.sh --dry-run   # only check, and show what a release would do
#   scripts/release.sh             # release
#
# To make a new version: change the version in Release.swift, add its notes to CHANGELOG.md,
# and merge that as a pull request. Then run this script on the main branch.
set -eu

# The whole script is one function, so the shell reads it all before it runs any of it.
main() {
  dry=
  case "${1:-}" in
    --dry-run) dry=1 ;;
    "") ;;
    *) fail "usage: scripts/release.sh [--dry-run]" ;;
  esac
  cd "$(dirname "$0")/.."

  version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/duorex/Release.swift)
  echo "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || fail "Release.swift has no version of the form 1.2.3."
  tag="v$version"

  [ "$(git branch --show-current)" = main ] || fail "release from the main branch."
  [ -z "$(git status --porcelain)" ] || fail "the working tree is not clean. Commit or remove your changes first."
  git fetch --quiet --tags origin
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main here is not main on GitHub. Pull or push first."
  if git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null; then
    fail "$tag exists. Change the version in Release.swift."
  fi

  # Only tags of the form v1.2.3 are releases, as in install.sh. The new one must be the newest.
  newest=$(git tag --list 'v*' --sort=-version:refname | grep -Ex 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
  if [ -n "$newest" ] && [ "$(printf '%s\n%s\n' "$newest" "$tag" | sort -V | tail -n 1)" != "$tag" ]; then
    fail "$tag is not newer than $newest, the newest release."
  fi

  # The notes are the part of CHANGELOG.md under the version's heading, up to the next heading.
  notes=$(awk -v heading="## $version" '$0 == heading { found = 1; next } found && /^## / { exit } found { print }' CHANGELOG.md)
  [ -n "$(printf '%s' "$notes" | tr -d '[:space:]')" ] || fail "CHANGELOG.md has no notes under \"## $version\"."

  echo "Testing duorex $version."
  swift test >/dev/null 2>&1 || fail "the tests fail. Run swift test."
  swift build --configuration release >/dev/null 2>&1 || fail "the release build fails. Run swift build --configuration release."
  built=$(.build/release/duorex version)
  [ "$built" = "$version" ] || fail "the build says it is $built, not $version."

  if [ -n "$dry" ]; then
    echo "Ready. A release would tag $(git rev-parse --short HEAD) as $tag, push the tag, and publish these notes:"
    printf '%s\n' "$notes"
    return
  fi

  git tag --annotate "$tag" --message "duorex $version"
  git push --quiet origin "$tag"
  # --verify-tag: publish for the tag that was just pushed, or not at all.
  printf '%s\n' "$notes" | gh release create "$tag" --verify-tag --title "duorex $version" --notes-file -
  echo "Released duorex $version. \`duorex update\` now installs it."
}

fail() {
  echo "release: $*" >&2
  exit 1
}

main "$@"
