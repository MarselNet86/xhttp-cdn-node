#!/usr/bin/env bats
# Contract tests for lib/node.sh: the compose file of the node from the SECRET_KEY and
# NODE_PORT that the panel gives, Docker when it is missing, and the start.

setup() {
  # bats 1.2 on Ubuntu 22.04 has no BATS_TEST_TMPDIR.
  TMP="$(mktemp -d)"
  export CDN_DEPLOY_SYSROOT="$TMP/root"
  mkdir -p "$TMP/stubs" "$CDN_DEPLOY_SYSROOT"
  # docker records its calls. "compose version" fails while $TMP/no-compose exists, and
  # "compose ... up" while $TMP/up-fails does.
  cat >"$TMP/docker.stub" <<EOF
#!/bin/sh
echo "docker \$*" >>"$TMP/calls"
if [ "\$1 \$2" = "compose version" ] && [ -e "$TMP/no-compose" ]; then exit 1; fi
case " \$* " in *" up -d "*) [ -e "$TMP/up-fails" ] && exit 1 ;; esac
exit 0
EOF
  cp "$TMP/docker.stub" "$TMP/stubs/docker"
  # curl hands out an installer that puts docker in place, and fails while $TMP/offline
  # exists.
  cat >"$TMP/stubs/curl" <<EOF
#!/bin/sh
echo "curl \$*" >>"$TMP/calls"
[ -e "$TMP/offline" ] && exit 7
while [ \$# -gt 0 ]; do
  if [ "\$1" = -o ]; then printf 'cp "%s" "%s"\n' "$TMP/docker.stub" "$TMP/stubs/docker" >"\$2"; fi
  shift
done
EOF
  chmod +x "$TMP/docker.stub" "$TMP/stubs/docker" "$TMP/stubs/curl"
  PATH="$TMP/stubs:$PATH"
  # shellcheck source=../lib/node.sh
  source "$BATS_TEST_DIRNAME/../lib/node.sh"
  COMPOSE="$CDN_DEPLOY_SYSROOT/opt/remnanode/docker-compose.yml"
  KEY="$(node_key)"
  export NODE_PORT=2222 NODE_SECRET_KEY="$KEY"
}

teardown() {
  rm -rf "${TMP:?}"
}

# A SECRET_KEY of the shape the node checks, with stand-in certificates.
node_key() {
  printf '{"caCertPem":"ca","jwtPublicKey":"jwt","nodeCertPem":"cert","nodeKeyPem":"key"}' |
    base64 | tr -d '\n'
}

calls() {
  grep -c -- "$1" "$TMP/calls" || true
}

@test "the compose file is the one the panel shows, with SECRET_KEY and NODE_PORT, mode 600" {
  run node::install
  [ "$status" -eq 0 ]
  [ -n "$(find "$COMPOSE" -perm 600)" ]
  [ "$(head -n 1 "$COMPOSE")" = "# Written by cdn-deploy from .env: rerun ./deploy.sh to change it." ]
  grep -qx '    container_name: remnanode' "$COMPOSE"
  grep -qx '    image: remnawave/node:latest' "$COMPOSE"
  grep -qx '    network_mode: host' "$COMPOSE"
  grep -qx '      - NODE_PORT=2222' "$COMPOSE"
  grep -qxF "      - SECRET_KEY=\"$KEY\"" "$COMPOSE"
  run grep -c volumes "$COMPOSE"
  [ "$output" -eq 0 ]
  [ "$(calls "docker compose -f $COMPOSE up -d")" -eq 1 ]
  [[ "$(cat "$TMP/calls")" != *curl* ]]
}

@test "with HY2_DOMAIN the node sees /etc/letsencrypt, read-only, for the Hysteria2 certificate" {
  HY2_DOMAIN=hy2.example.com run node::install
  [ "$status" -eq 0 ]
  [ "$(tail -n 2 "$COMPOSE")" = "$(printf '    volumes:\n      - /etc/letsencrypt:/etc/letsencrypt:ro')" ]
}

@test "the secret stays out of the output" {
  run node::install
  [ "$status" -eq 0 ]
  [[ "$output" != *"$KEY"* ]]
}

@test "a rerun leaves the file alone, and compose leaves the running node alone" {
  node::install 2>/dev/null
  run node::install
  [ "$status" -eq 0 ]
  [[ "$output" == *"is up to date"* ]]
  [ "$(calls " up -d")" -eq 2 ]
  [ ! -e "$COMPOSE.cdn-deploy-orig" ]
}

@test "a compose file set up by hand is kept once next to the new one" {
  mkdir -p "${COMPOSE%/*}"
  printf 'services:\n  remnanode:\n    image: remnawave/node:2.7.0\n' >"$COMPOSE"
  run node::install
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept the previous /opt/remnanode/docker-compose.yml as /opt/remnanode/docker-compose.yml.cdn-deploy-orig"* ]]
  grep -q 'remnawave/node:2.7.0' "$COMPOSE.cdn-deploy-orig"
  [ -n "$(find "$COMPOSE.cdn-deploy-orig" -perm 600)" ]
  NODE_PORT=3333 node::install 2>/dev/null
  grep -q 'remnawave/node:2.7.0' "$COMPOSE.cdn-deploy-orig"
}

@test "node::compose_value reads SECRET_KEY and NODE_PORT in the list and the map form" {
  [ -z "$(node::compose_value SECRET_KEY)" ]
  mkdir -p "${COMPOSE%/*}"
  printf '    environment:\n      - NODE_PORT=2233\n      - SECRET_KEY="%s"\n' "$KEY" >"$COMPOSE"
  [ "$(node::compose_value SECRET_KEY)" = "$KEY" ]
  [ "$(node::compose_value NODE_PORT)" = 2233 ]
  printf '    environment:\n      NODE_PORT: "3344"\n      SECRET_KEY: %s\n' "$KEY" >"$COMPOSE"
  [ "$(node::compose_value SECRET_KEY)" = "$KEY" ]
  [ "$(node::compose_value NODE_PORT)" = 3344 ]
}

@test "Docker comes from get.docker.com when it is missing" {
  rm "$TMP/stubs/docker"
  run node::install
  [ "$status" -eq 0 ]
  [[ "$output" == *"installing Docker from get.docker.com"* ]]
  [ "$(calls 'curl -fsSL --max-time 120 https://get.docker.com -o ')" -eq 1 ]
  [ "$(calls " up -d")" -eq 1 ]
}

@test "without Docker or its compose plugin the install stops with exit 3" {
  touch "$TMP/no-compose"
  run node::install
  [ "$status" -eq 3 ]
  [[ "$output" == *"docker has no compose plugin: install docker-compose-plugin"* ]]
  rm "$TMP/no-compose" "$TMP/stubs/docker"
  touch "$TMP/offline"
  run node::install
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot install Docker"* ]]
  [ "$(calls " up -d")" -eq 0 ]
}

@test "a failing docker compose up exits 1" {
  touch "$TMP/up-fails"
  run node::install
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker compose up -d failed for /opt/remnanode/docker-compose.yml"* ]]
}
