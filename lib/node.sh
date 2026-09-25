# shellcheck shell=bash
# The Remnawave node on this server: the compose file from the SECRET_KEY and NODE_PORT
# that the panel gives when it creates the node, with the Hysteria2 certificate mounted,
# and the container started from it. The panel then pushes the xray config to the node.

set -euo pipefail

# Modules may source this file again; readonly constants must not be redefined.
if [[ -n "${_CDN_NODE_LOADED:-}" ]]; then
  return 0
fi
_CDN_NODE_LOADED=1

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

# The layout of the official node install: NODE_RELOAD_CMD restarts this container.
readonly NODE_DIR=/opt/remnanode NODE_CONTAINER=remnanode
readonly NODE_COMPOSE="$NODE_DIR/docker-compose.yml"
# The first line of the compose file this script writes.
readonly NODE_MARK="# Written by cdn-deploy from .env: rerun ./deploy.sh to change it."

# Writes the compose file and starts the node; installs Docker first when it is missing.
# docker compose up -d leaves a running container with the same file alone.
node::install() {
  local compose="$SYSROOT$NODE_COMPOSE"
  env::require NODE_SECRET_KEY NODE_PORT
  node::_docker
  mkdir -p "${compose%/*}"
  node::_keep_original "$compose"
  fs::write "$compose" 600 "$(node::_compose)"
  log::info "starting the node: docker compose up -d in $NODE_DIR"
  docker compose -f "$compose" up -d >&2 ||
    log::die "$EXIT_FAILURE" "docker compose up -d failed for $NODE_COMPOSE: see the output above"
}

# Prints the value of KEY (SECRET_KEY or NODE_PORT) from the compose file of a node set
# up by hand, in the list or the map form of environment; nothing without one.
node::compose_value() {
  local key="$1" line re
  re="^[[:space:]]*(-[[:space:]]*)?${key}[[:space:]]*[=:][[:space:]]*[\"']?([^\"'[:space:]]*)[\"']?[[:space:]]*$"
  if [[ ! -f "$SYSROOT$NODE_COMPOSE" ]]; then
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re ]]; then
      printf '%s' "${BASH_REMATCH[2]}"
      return 0
    fi
  done <"$SYSROOT$NODE_COMPOSE"
}

# The file the panel shows for a new node, plus the certificates for Hysteria2: its
# inbound reads /etc/letsencrypt/live/HY2_DOMAIN/ inside the container, and xray does not
# start without it. The quotes around SECRET_KEY are the panel's; the node decodes past
# them.
node::_compose() {
  cat <<EOF
$NODE_MARK
services:
  remnanode:
    container_name: $NODE_CONTAINER
    hostname: $NODE_CONTAINER
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=$NODE_PORT
      - SECRET_KEY="$NODE_SECRET_KEY"
EOF
  if [[ -n "${HY2_DOMAIN:-}" ]]; then
    cat <<'EOF'
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
EOF
  fi
}

# Docker comes from get.docker.com, as in the Remnawave docs for the node.
node::_docker() {
  local installer
  if command -v docker >/dev/null 2>&1; then
    docker compose version >/dev/null 2>&1 ||
      log::die "$EXIT_DEPS" "docker has no compose plugin: install docker-compose-plugin (docker-compose-v2 in the Ubuntu archive) and rerun"
    return 0
  fi
  log::info "installing Docker from get.docker.com, as the Remnawave docs do for the node"
  installer="$(mktemp)"
  if ! curl -fsSL --max-time 120 https://get.docker.com -o "$installer" || ! sh "$installer" >&2; then
    rm -f "$installer"
    log::die "$EXIT_DEPS" "cannot install Docker: see the output above, or install it by hand and rerun"
  fi
  rm -f "$installer"
  command -v docker >/dev/null 2>&1 ||
    log::die "$EXIT_DEPS" "get.docker.com finished, but there is no docker command: install Docker by hand and rerun"
}

# A compose file from another hand is kept once next to the new one, as nginx.conf is.
node::_keep_original() {
  local compose="$1"
  if [[ -f "$compose" && ! -e "$compose.cdn-deploy-orig" ]] && [[ "$(head -n 1 "$compose")" != "$NODE_MARK" ]]; then
    cp -p "$compose" "$compose.cdn-deploy-orig"
    chmod 600 "$compose.cdn-deploy-orig"
    log::info "kept the previous $NODE_COMPOSE as $NODE_COMPOSE.cdn-deploy-orig"
  fi
}
