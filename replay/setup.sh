#!/usr/bin/env bash
# Clone the two replay targets at the commits the survey read, into
# replay/<name>/target (gitignored), and install their dependencies.
# The targets are never modified; the tests drive their public interfaces.
set -euo pipefail
cd "$(dirname "$0")"

fetch_pinned() {
  local name="$1" url="$2" sha="$3" dir="$1/target"
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ]; then
    echo "$name: already at $sha"
    return
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url"
  git -C "$dir" fetch -q --depth 1 origin "$sha"
  git -C "$dir" checkout -q FETCH_HEAD
  echo "$name: checked out $sha"
}

fetch_pinned construct-auto-classifier https://github.com/godspede/construct-auto-classifier \
  "${CONSTRUCT_AUTO_CLASSIFIER_SHA:-9062b340f5b57e917245431dd7189b626c44c869}"
fetch_pinned jev-engineering https://github.com/eugeniughelbur/jev-engineering \
  "${JEV_ENGINEERING_SHA:-3161dbfb44f21bafa2ec7940ec18cfb090c7b43d}"

(cd construct-auto-classifier/target && bun install --silent)
echo "setup complete"
