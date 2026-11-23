#!/usr/bin/env bash
# Service host: bring this repo up to date with `origin/main`, keep the images
# now in use under a `prev-<stamp>` tag, pull the new app images, restart the
# app services, wait until they report healthy, and reload the edge nginx.
#
#   scripts/deploy.sh                # videonizer (+ migrate, loadfiller) and vision
#   scripts/deploy.sh vision         # vision only
#
# Uses this repo's .env and the prod override. Registry login already done.
# REMOTE overrides the remote this repo is updated from (default origin).
set -euo pipefail

HEALTH_TIMEOUT_S=240

main() {
  local root remote stamp
  root="$(cd "$(dirname "$0")/.." && pwd)"
  remote="${REMOTE:-origin}"
  stamp="$(date +%Y%m%d-%H%M)"
  cd "$root"
  [ -f .env ] || { echo "no .env in $root" >&2; return 1; }

  step "vision-infra: check out $remote/main"
  if ! git diff --quiet || ! git diff --cached --quiet; then
    git status -s
    echo "local changes in vision-infra — stopping" >&2
    return 1
  fi
  local before
  before="$(git rev-parse --short HEAD)"
  git fetch "$remote" main
  git checkout --detach "$remote/main"
  echo "vision-infra: $before -> $(git rev-parse --short HEAD)"

  local dc=(docker compose --env-file "$root/.env" -f docker-compose.yml -f docker-compose.prod.yml)
  local apps=("$@") up=() pull=()
  [ ${#apps[@]} -gt 0 ] || apps=(videonizer vision)
  for a in "${apps[@]}"; do
    case "$a" in
      videonizer) up+=(videonizer videonizer-loadfiller); pull+=(videonizer videonizer-migrate videonizer-loadfiller) ;;
      vision) up+=(vision); pull+=(vision) ;;
      *) echo "unknown app: $a (videonizer | vision)" >&2; return 1 ;;
    esac
  done

  step "keep current images as :prev-$stamp"
  local kept=()
  # `config --images` also lists the services these depend on; keep the apps'.
  for img in $("${dc[@]}" config --images "${pull[@]}" | grep -E '/(videonizer|vision):' | sort -u); do
    if docker image inspect "$img" >/dev/null 2>&1; then
      docker tag "$img" "${img%:*}:prev-$stamp"
      kept+=("$img")
      echo "$img -> ${img%:*}:prev-$stamp"
    fi
  done

  step "pull: ${pull[*]}"
  "${dc[@]}" pull "${pull[@]}"

  step "up: ${up[*]}"
  "${dc[@]}" up -d "${up[@]}"

  step "wait for healthy (up to ${HEALTH_TIMEOUT_S}s)"
  local deadline=$((SECONDS + HEALTH_TIMEOUT_S)) pending
  while :; do
    pending=()
    for svc in "${up[@]}"; do
      local id state
      id="$("${dc[@]}" ps -q "$svc")"
      state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || echo missing)"
      case "$state" in healthy|running) ;; *) pending+=("$svc=$state") ;; esac
    done
    [ ${#pending[@]} -eq 0 ] && break
    if [ $SECONDS -ge $deadline ]; then
      echo "not healthy: ${pending[*]}" >&2
      rollback_hint "$stamp" "${up[*]}" "${kept[@]}"
      return 1
    fi
    sleep 3
  done
  # nginx resolved the app containers' addresses when it started; the ones
  # just recreated have new addresses, so it would answer 502 until reloaded.
  step "reload edge nginx"
  "${dc[@]}" exec -T nginx nginx -s reload
  "${dc[@]}" ps "${pull[@]}"
  step "done"
  rollback_hint "$stamp" "${up[*]}" "${kept[@]}"
}

step() { printf '\n== %s\n' "$*"; }

rollback_hint() {
  local stamp="$1" services="$2"; shift 2
  [ $# -gt 0 ] || return 0
  echo
  echo "to roll back (database migrations are not undone):"
  for img in "$@"; do echo "  docker tag ${img%:*}:prev-$stamp $img"; done
  echo "  docker compose --env-file $PWD/.env -f docker-compose.yml -f docker-compose.prod.yml up -d $services"
  echo "  docker compose --env-file $PWD/.env -f docker-compose.yml -f docker-compose.prod.yml exec nginx nginx -s reload"
}

# Kept on one line: the checkout above can rewrite this very file, and bash
# reads a script as it runs — nothing after main is read from the new file.
main "$@"; exit $?
