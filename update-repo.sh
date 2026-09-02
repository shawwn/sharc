#!/bin/bash
# Poll origin and only touch the working tree when main actually moves.
# Handles force pushes: we compare SHAs, not ancestry, and reset to whatever
# the remote says main is now -- forward, backward, or rewritten.

remote=${1:-origin}
branch=${2:-main}

want=$(git ls-remote --exit-code "$remote" "refs/heads/$branch" | cut -f1)
have=$(git rev-parse HEAD)
if [ -n "$want" ] && [ "$want" != "$have" ]; then
  if git fetch --quiet --prune "$remote" && git reset --hard --quiet "$want"; then
    echo "updated to $want"
  else
    echo "update to $want failed" >&2
  fi
fi
