#!/usr/bin/env bats
# Contract tests for lib/nginx.sh (tech.md §5, §6, §7): the rendered config, rollback on a
# failed nginx -t, idempotent reruns. nginx and systemctl are stubs; /etc/nginx lives under
# CDN_DEPLOY_SYSROOT and starts as a stock Debian layout.

setup() {
  # bats 1.2 on Ubuntu 22.04 has no BATS_TEST_TMPDIR.
  TMP="$(mktemp -d)"
  REPO="$TMP/repo"
  ROOT="$TMP/root"
  mkdir -p "$REPO" "$TMP/bin" "$ROOT/etc/nginx/sites-available" "$ROOT/etc/nginx/sites-enabled"
  cp -R "$BATS_TEST_DIRNAME/../lib" "$BATS_TEST_DIRNAME/../templates" \
    "$BATS_TEST_DIRNAME/../.env.example" "$REPO/"
  export CDN_DEPLOY_SYSROOT="$ROOT" STUB_DIR="$TMP"
  stubs
  PATH="$TMP/bin:$PATH"
  # shellcheck source=../lib/nginx.sh
  source "$REPO/lib/nginx.sh"
  echo stock >"$ROOT/etc/nginx/nginx.conf"
  echo "server { listen 80 default_server; }" >"$ROOT/etc/nginx/sites-available/default"
  ln -s /etc/nginx/sites-available/default "$ROOT/etc/nginx/sites-enabled/default"
  local domain
  for domain in cdn.example.com vless.example.com; do
    mkdir -p "$ROOT/etc/letsencrypt/live/$domain"
    echo cert >"$ROOT/etc/letsencrypt/live/$domain/fullchain.pem"
    echo key >"$ROOT/etc/letsencrypt/live/$domain/privkey.pem"
  done
  VLESS_DOMAIN=vless.example.com
  CDN_DOMAIN=cdn.example.com
  XHTTP_PORT=4443
  XHTTP_PATH=/api/v2.jpg/
  NGINX_TLS_PORT=8444
  CERT_MODE=dns-cloudflare
  ISSUE_CDN_ORIGIN_CERT=true
  CONF="$ROOT/etc/nginx/nginx.conf"
  SITE="$ROOT/etc/nginx/sites-available/cdn-deploy.conf"
}

teardown() {
  rm -rf "${TMP:?}"
}

# stub NAME: installs stdin as the script $TMP/bin/NAME.
stub() {
  {
    echo '#!/bin/sh'
    cat
  } >"$TMP/bin/$1"
  chmod +x "$TMP/bin/$1"
}

# Every stub appends its call to $STUB_DIR/calls; marker files in $STUB_DIR make them fail.
stubs() {
  # Like nginx, prints a notice on a successful reload.
  stub nginx <<'EOF'
echo "nginx $*" >>"$STUB_DIR/calls"
if [ "$1" = -t ] && [ -e "$STUB_DIR/nginx-t-fail" ]; then
  echo "nginx: [emerg] unknown directive in /etc/nginx/sites-enabled/cdn-deploy.conf" >&2
  exit 1
fi
if [ "$1" = -s ]; then
  if [ -e "$STUB_DIR/nginx-reload-fail" ]; then
    echo "nginx: [error] invalid PID number" >&2
    exit 1
  fi
  echo "nginx: [notice] signal process started" >&2
fi
EOF
  stub systemctl <<'EOF'
echo "systemctl $*" >>"$STUB_DIR/calls"
case "$1" in
  is-active) [ ! -e "$STUB_DIR/nginx-down" ] ;;
esac
EOF
}

# Counts logged calls that match the pattern; 0 when nothing ran at all.
calls() {
  if [[ -f "$TMP/calls" ]]; then
    grep -c -- "$1" "$TMP/calls" || true
  else
    echo 0
  fi
}

# Contents of every file and the target of every link under DIR.
snapshot() {
  find "$1" -type f -exec cksum {} + | sort
  find "$1" -type l -exec sh -c 'for l; do printf "%s -> %s\n" "$l" "$(readlink "$l")"; done' _ {} + | sort
}

has() {
  grep -qF -- "$2" "$1" || {
    echo "${1##*/} lacks: $2"
    return 1
  }
}

@test "the main config carries the frozen values of tech.md §6" {
  local line
  run nginx::render
  [ "$status" -eq 0 ]
  for line in 'worker_processes auto;' 'worker_rlimit_nofile 65535;' 'worker_connections 16384;' \
    'multi_accept on;' 'pid /run/nginx.pid;' 'include /etc/nginx/sites-enabled/*;'; do
    has "$CONF" "$line"
  done
}

@test "the origin site carries the frozen upstream and server values" {
  local line
  run nginx::render
  [ "$status" -eq 0 ]
  for line in 'server 127.0.0.1:4443;' 'keepalive 512;' 'keepalive_requests 100000;' \
    'keepalive_timeout 300s;' 'listen 8444 ssl backlog=4096;' 'location = /cdn-check {' \
    'add_header X-CDN-Origin ok always;' 'return 204;' 'location ^~ /api/v2.jpg/ {' \
    'proxy_pass http://xray_xhttp;' 'proxy_set_header Connection "";' 'proxy_buffering off;' \
    'proxy_read_timeout 3600s;' 'proxy_send_timeout 3600s;' 'return 403;'; do
    has "$SITE" "$line"
  done
}

@test "ports, path and names come from .env and nginx variables stay" {
  XHTTP_PORT=4450
  NGINX_TLS_PORT=9443
  XHTTP_PATH=/cdn/v1.bin/
  run nginx::render
  [ "$status" -eq 0 ]
  has "$SITE" 'server 127.0.0.1:4450;'
  has "$SITE" 'listen 9443 ssl backlog=4096;'
  has "$SITE" 'location ^~ /cdn/v1.bin/ {'
  has "$SITE" 'server_name cdn.example.com vless.example.com;'
  has "$SITE" 'proxy_set_header Host cdn.example.com;'
  has "$SITE" "add_header X-Origin-Method \$request_method always;"
  has "$SITE" "proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
  run grep -F "\${" "$SITE" "$CONF"
  [ "$status" -eq 1 ]
}

@test "the origin serves the CDN certificate when one is issued, the VLESS one otherwise" {
  run nginx::render
  [ "$status" -eq 0 ]
  has "$SITE" 'ssl_certificate /etc/letsencrypt/live/cdn.example.com/fullchain.pem;'
  has "$SITE" 'ssl_certificate_key /etc/letsencrypt/live/cdn.example.com/privkey.pem;'
  ISSUE_CDN_ORIGIN_CERT=false
  run nginx::render
  [ "$status" -eq 0 ]
  has "$SITE" 'ssl_certificate /etc/letsencrypt/live/vless.example.com/fullchain.pem;'
  ISSUE_CDN_ORIGIN_CERT=true
  CERT_MODE=http-01
  run nginx::render
  [ "$status" -eq 0 ]
  has "$SITE" 'ssl_certificate /etc/letsencrypt/live/vless.example.com/fullchain.pem;'
}

@test "a missing certificate exits 7 and changes nothing" {
  local before
  rm "$ROOT/etc/letsencrypt/live/cdn.example.com/privkey.pem"
  before="$(snapshot "$ROOT")"
  run nginx::render
  [ "$status" -eq 7 ]
  [[ "$output" == *"no certificate in /etc/letsencrypt/live/cdn.example.com"* ]]
  [ "$(snapshot "$ROOT")" = "$before" ]
  [ "$(calls .)" -eq 0 ]
}

@test "render enables the site and removes only the enabled default site" {
  run nginx::render
  [ "$status" -eq 0 ]
  [ "$(readlink "$ROOT/etc/nginx/sites-enabled/cdn-deploy.conf")" = /etc/nginx/sites-available/cdn-deploy.conf ]
  [ ! -L "$ROOT/etc/nginx/sites-enabled/default" ]
  [ -f "$ROOT/etc/nginx/sites-available/default" ]
  [[ "$output" == *"removed /etc/nginx/sites-enabled/default"* ]]
}

@test "the stock nginx.conf is kept once, before the first overwrite" {
  run nginx::render
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/etc/nginx/nginx.conf.cdn-deploy-orig")" = stock ]
  XHTTP_PORT=4450
  run nginx::render
  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/etc/nginx/nginx.conf.cdn-deploy-orig")" = stock ]
}

@test "a config that nginx -t rejects is rolled back and exits 7" {
  local before
  touch "$TMP/nginx-t-fail"
  before="$(snapshot "$ROOT/etc/nginx" | grep -v cdn-deploy-orig)"
  run nginx::render
  [ "$status" -eq 7 ]
  [[ "$output" == *"restored the previous nginx config"* ]]
  [ "$(snapshot "$ROOT/etc/nginx" | grep -v cdn-deploy-orig)" = "$before" ]
  [ "$(cat "$CONF")" = stock ]
  [ "$(readlink "$ROOT/etc/nginx/sites-enabled/default")" = /etc/nginx/sites-available/default ]
  [ "$(calls 'nginx -s reload')" -eq 0 ]
}

@test "a rerun with the same settings changes nothing and does not reload" {
  local before
  run nginx::render
  [ "$status" -eq 0 ]
  before="$(snapshot "$ROOT")"
  : >"$TMP/calls"
  run nginx::render
  [ "$status" -eq 0 ]
  [ "$(snapshot "$ROOT")" = "$before" ]
  [[ "$output" == *"nginx config is up to date"* ]]
  [ "$(calls '^nginx')" -eq 0 ]
}

@test "a changed setting goes through nginx -t and one reload" {
  run nginx::render
  [ "$status" -eq 0 ]
  : >"$TMP/calls"
  XHTTP_PORT=4450
  run nginx::render
  [ "$status" -eq 0 ]
  [ "$(tr '\n' '|' <"$TMP/calls")" = "nginx -t|systemctl is-active --quiet nginx|nginx -s reload|" ]
  has "$SITE" 'server 127.0.0.1:4450;'
  [[ "$output" != *"signal process started"* ]]
}

@test "a stopped nginx is started, even when the config is up to date" {
  run nginx::render
  [ "$status" -eq 0 ]
  touch "$TMP/nginx-down"
  : >"$TMP/calls"
  run nginx::render
  [ "$status" -eq 0 ]
  [ "$(calls '^nginx -t')" -eq 1 ]
  [ "$(calls '^systemctl start nginx')" -eq 1 ]
  [ "$(calls 'nginx -s reload')" -eq 0 ]
}

@test "a failed reload exits 7 with nginx's message" {
  touch "$TMP/nginx-reload-fail"
  run nginx::render
  [ "$status" -eq 7 ]
  [[ "$output" == *"nginx -s reload failed: nginx: [error] invalid PID number"* ]]
}

@test "a placeholder without a value fails before nginx sees the config" {
  local before
  printf '    # %s\n' "\${UNKNOWN_SETTING}" >>"$REPO/templates/site-8444.conf.tmpl"
  before="$(snapshot "$ROOT")"
  run nginx::render
  [ "$status" -eq 7 ]
  [[ "$output" == *"placeholder that nginx::render does not fill"* ]]
  [ "$(snapshot "$ROOT")" = "$before" ]
  [ "$(calls .)" -eq 0 ]
}
