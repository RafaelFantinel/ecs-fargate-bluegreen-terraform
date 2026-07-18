#!/usr/bin/env bash
# Local blue/green deploy simulating the CodeDeploy ECS flow — no AWS account.
#
# Flow per deploy (same shape as CodeDeploy blue/green):
#   1. Build the new image version.
#   2. Start it as the INACTIVE color (green if blue is live, and vice versa).
#   3. Validate it through the TEST listener (:9001) health check.
#   4. Shift production traffic (:8081) to the new color (nginx reload).
#   5. Keep the old color running for instant rollback.
#
# Usage:
#   ./deploy/local-deploy.sh [version]   build+deploy (version defaults to git sha or timestamp)
#   ./deploy/local-deploy.sh status      show active color, versions and listeners
#   ./deploy/local-deploy.sh rollback    shift prod traffic back to the previous color
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/local/state.env"
NGINX_TEMPLATE="$ROOT/local/nginx/default.conf.template"
NGINX_CONF="$ROOT/local/nginx/default.conf"
IMAGE=ecs-demo-app
PROD_URL=http://localhost:8081
TEST_URL=http://localhost:9001

ACTIVE_COLOR=blue
BLUE_TAG=""
GREEN_TAG=""
# shellcheck disable=SC1090
[ -f "$STATE" ] && source "$STATE"

other_color() { [ "$1" = blue ] && echo green || echo blue; }

save_state() {
  printf 'ACTIVE_COLOR=%s\nBLUE_TAG=%s\nGREEN_TAG=%s\n' \
    "$ACTIVE_COLOR" "$BLUE_TAG" "$GREEN_TAG" > "$STATE"
}

render_nginx() {
  local active=$1
  local inactive
  inactive=$(other_color "$active")
  # Atomic replace (new inode) so the change propagates through the bind mount.
  sed -e "s/__ACTIVE__/$active/" -e "s/__INACTIVE__/$inactive/" \
    "$NGINX_TEMPLATE" > "$NGINX_CONF.tmp"
  mv "$NGINX_CONF.tmp" "$NGINX_CONF"
}

compose() {
  BLUE_TAG="${BLUE_TAG:-bootstrap}" GREEN_TAG="${GREEN_TAG:-bootstrap}" \
    docker compose -f "$ROOT/docker-compose.yml" "$@"
}

reload_lb() {
  compose exec lb nginx -s reload > /dev/null
}

# nginx reload is graceful: new workers take over shortly after the signal.
# Poll prod until the expected version is live instead of racing the reload.
wait_traffic_shift() {
  local expected=$1 deadline=$((SECONDS + 15))
  until curl -sf "$PROD_URL/" 2>/dev/null | grep -q "\"$expected\""; do
    if [ $SECONDS -ge $deadline ]; then
      echo "WARNING: prod not serving version $expected after 15s" >&2
      return 1
    fi
    sleep 1
  done
}

wait_healthy() {
  local url=$1 deadline=$((SECONDS + 60))
  until curl -sf "$url/actuator/health" 2>/dev/null | grep -q '"UP"'; do
    if [ $SECONDS -ge $deadline ]; then
      return 1
    fi
    sleep 2
  done
}

cmd_status() {
  echo "Active color : ${ACTIVE_COLOR}"
  echo "Blue version : ${BLUE_TAG:-<none>}"
  echo "Green version: ${GREEN_TAG:-<none>}"
  echo "Prod  ($PROD_URL): $(curl -sf "$PROD_URL/" || echo unreachable)"
  echo "Test  ($TEST_URL): $(curl -sf "$TEST_URL/" || echo unreachable)"
}

cmd_rollback() {
  local previous
  previous=$(other_color "$ACTIVE_COLOR")
  echo "Shifting production traffic back: ${ACTIVE_COLOR} -> ${previous}"
  ACTIVE_COLOR=$previous
  render_nginx "$ACTIVE_COLOR"
  reload_lb
  save_state
  local expected_tag
  [ "$ACTIVE_COLOR" = blue ] && expected_tag=$BLUE_TAG || expected_tag=$GREEN_TAG
  wait_traffic_shift "$expected_tag" || true
  echo "Rollback done. Prod now serves: $(curl -sf "$PROD_URL/")"
}

cmd_deploy() {
  local version=$1

  echo "==> Building ${IMAGE}:${version}"
  docker build -q -t "${IMAGE}:${version}" "$ROOT/app" > /dev/null

  if [ -z "$BLUE_TAG" ] && [ -z "$GREEN_TAG" ]; then
    # First run: both colors start on the same version, prod -> blue.
    echo "==> First deploy: bootstrapping blue and green with ${version}"
    BLUE_TAG=$version
    GREEN_TAG=$version
    ACTIVE_COLOR=blue
    render_nginx "$ACTIVE_COLOR"
    compose up -d
    wait_healthy "$PROD_URL" || { echo "ERROR: app did not become healthy" >&2; exit 1; }
    save_state
    echo "==> Environment up. Prod: $(curl -sf "$PROD_URL/")"
    return
  fi

  local target
  target=$(other_color "$ACTIVE_COLOR")
  echo "==> Active color is ${ACTIVE_COLOR}; deploying ${version} to ${target}"

  if [ "$target" = blue ]; then BLUE_TAG=$version; else GREEN_TAG=$version; fi
  compose up -d --no-deps "app-${target}"

  echo "==> Validating ${target} on test listener ${TEST_URL}"
  if ! wait_healthy "$TEST_URL"; then
    echo "ERROR: ${target} failed health check. Production traffic untouched (still on ${ACTIVE_COLOR})." >&2
    exit 1
  fi
  echo "    Test listener serves: $(curl -sf "$TEST_URL/")"

  echo "==> Shifting production traffic: ${ACTIVE_COLOR} -> ${target}"
  ACTIVE_COLOR=$target
  render_nginx "$ACTIVE_COLOR"
  reload_lb
  save_state
  wait_traffic_shift "$version" || true

  echo "==> Deploy complete."
  echo "    Prod ($PROD_URL): $(curl -sf "$PROD_URL/")"
  echo "    Previous color kept running for rollback: ./deploy/local-deploy.sh rollback"
}

case "${1:-}" in
  status)   cmd_status ;;
  rollback) cmd_rollback ;;
  *)
    version=${1:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date +v%H%M%S)}
    cmd_deploy "$version"
    ;;
esac
