#!/usr/bin/env bash
# Build host: build the production images from `origin/main` of the sibling app
# repos and push them to the registry.
#
#   scripts/build-push.sh            # videonizer + vision
#   scripts/build-push.sh vision     # one image only
#
# Each app repo's working tree is switched to `origin/main` (detached) for the
# build and put back on the branch it was on afterwards, success or not —
# nothing is merged into that branch, so a local mirror branch with its own
# history is left as it was.
#
# Layout: ../videonizer, ../vision next to this repo; registry login and
# .env (REGISTRY_URL, IMAGE_PREFIX, *_TAG, PIP_*/NPM_*) already in place.
# REMOTE overrides the remote the app repos are built from (default origin).
set -euo pipefail

# "<dir>|<branch or commit>" per repo switched to origin/main.
RESTORE=()

main() {
  local infra apps remote
  infra="$(cd "$(dirname "$0")/.." && pwd)"
  remote="${REMOTE:-origin}"
  if [ $# -gt 0 ]; then apps=("$@"); else apps=(videonizer vision); fi
  [ -f "$infra/.env" ] || { echo "no .env in $infra" >&2; return 1; }

  trap restore EXIT
  for app in "${apps[@]}"; do
    checkout_main "$(cd "$infra/../$app" && pwd)" "$remote"
  done

  cd "$infra"
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

# Switch <dir> to <remote>/main without touching its branch. Stops on
# uncommitted changes, which the switch would carry into the build.
checkout_main() {
  local dir="$1" remote="$2" name ref
  name="$(basename "$dir")"
  step "$name: check out $remote/main"
  [ -d "$dir/.git" ] || { echo "$dir is not a git checkout" >&2; return 1; }
  if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
    git -C "$dir" status -s
    echo "$name: uncommitted changes — stopping" >&2
    return 1
  fi
  git -C "$dir" fetch "$remote" main
  ref="$(git -C "$dir" symbolic-ref -q --short HEAD || git -C "$dir" rev-parse HEAD)"
  RESTORE+=("$dir|$ref")
  git -C "$dir" -c advice.detachedHead=false checkout -q --detach "$remote/main"
  git -C "$dir" log --oneline -1
}

restore() {
  local entry
  for entry in "${RESTORE[@]}"; do
    git -C "${entry%%|*}" checkout -q "${entry#*|}" \
      && echo "$(basename "${entry%%|*}"): back on ${entry#*|}"
  done
}

main "$@"; exit $?
