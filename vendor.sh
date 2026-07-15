#!/usr/bin/env bash
set -euo pipefail

vendor () {
  local name=$1 url=$2 ref=$3
  rm -rf "lib/$name"
  git clone --quiet --depth 1 --branch "$ref" "$url" "lib/$name"
  local sha; sha=$(git -C "lib/$name" rev-parse HEAD)
  rm -rf "lib/$name/.git"
  printf '%s\t%s\t%s\t%s\n' "$name" "$url" "$ref" "$sha"
}

mkdir -p lib
{
  printf '# vendored %s by %s\n' "$(date -u +%FT%TZ)" "${USER}"
  printf '# name\turl\tref\tcommit\n'
  vendor ironclad         https://github.com/sharplispers/ironclad     v0.61
  vendor bordeaux-threads https://github.com/sionescu/bordeaux-threads master
  vendor alexandria       https://gitlab.common-lisp.net/alexandria/alexandria.git master
  vendor global-vars      https://github.com/lmj/global-vars           master
  vendor trivial-features https://github.com/trivial-features/trivial-features master
  vendor trivial-garbage  https://github.com/trivial-garbage/trivial-garbage master
} > lib/MANIFEST

if find lib -type f -print0 | xargs -0 git check-ignore -q; then
  echo "ERROR: gitignore rules exclude vendored files:" >&2
  find lib -type f -print0 | xargs -0 git check-ignore -v >&2
  exit 1
fi
