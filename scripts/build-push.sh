#!/usr/bin/env bash
# Build host: bring the sibling app repos up to date with `origin/main`, build
# the production images, and push them to the registry.
#
#   scripts/build-push.sh            # videonizer + vision
#   scripts/build-push.sh vision     # one image only
#
# Layout: ../videonizer, ../vision next to this repo; registry login and
# .env (REGISTRY_URL, IMAGE_PREFIX, *_TAG, PIP_*/NPM_*) already in place.
# REMOTE overrides the remote the app repos are updated from (default origin).
set -euo pipefail

main() {
  local infra apps remote
  infra="$(cd "$(dirname "$0")/.." && pwd)"
  remote="${REMOTE:-origin}"
  if [ $# -gt 0 ]; then apps=("$@"); else apps=(videonizer vision); fi

  for app in "${apps[@]}"; do
    sync "$infra/../$app" "$remote"
  done

  cd "$infra"
  [ -f .env ] || { echo "no .env in $infra" >&2; return 1; }
  local dc=(docker compose --env-file .env -f docker-compose.yml -f docker-compose.build.yml)

  step "build: ${apps[*]}"
  "${dc[@]}" build "${apps[@]}"
  for app in "${apps[@]}"; do
    local img
    img=$("${dc[@]}" config --images | grep "/$app:" | head -1)
    echo "$img  built $(docker image inspect "$img" --format '{{.Created}}')"
  done

  step "push: ${apps[*]}"
  "${dc[@]}" push "${apps[@]}"
  step "done — on the service host run scripts/deploy.sh"
}

step() { printf '\n== %s\n' "$*"; }

# Merge <remote>/main into the checked-out branch. Stops on uncommitted
# changes or a conflict instead of building something half-merged.
sync() {
  local dir="$1" remote="$2" name
  name="$(basename "$dir")"
  step "$name: merge $remote/main"
  [ -d "$dir/.git" ] || { echo "$dir is not a git checkout" >&2; return 1; }
  if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
    git -C "$dir" status -s
    echo "$name: uncommitted changes — stopping" >&2
    return 1
  fi
  git -C "$dir" fetch "$remote" main
  if git -C "$dir" merge-base --is-ancestor "$remote/main" HEAD; then
    echo "$name: already up to date"
  elif ! git -C "$dir" merge --no-edit -m "Merge external changes" "$remote/main"; then
    git -C "$dir" merge --abort
    echo "$name: merge conflict — merge aborted, resolve it by hand" >&2
    return 1
  fi
  git -C "$dir" log --oneline -1
}

# Kept on one line: bash reads a script as it runs, and this guarantees nothing
# after main is read from a file a merge may have changed meanwhile.
main "$@"; exit $?
