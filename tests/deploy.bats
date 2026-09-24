#!/usr/bin/env bats
# Contract tests for deploy.sh (tech.md §7): flags and the --dry-run plan.

setup() {
  # bats 1.2 on Ubuntu 22.04 has no BATS_TEST_TMPDIR.
  TMP="$(mktemp -d)"
  # A copy gives each test its own .env state and shows that a dry run writes nothing.
  REPO="$TMP/repo"
  mkdir -p "$REPO" "$TMP/stubs"
  cp -R "$BATS_TEST_DIRNAME/../deploy.sh" "$BATS_TEST_DIRNAME/../lib" \
    "$BATS_TEST_DIRNAME/../.env.example" "$REPO/"
  # Stubs record any call to a command that changes the system.
  local cmd
  for cmd in apt-get dpkg certbot nginx systemctl sysctl docker curl ln; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\n' "$cmd" "$TMP" >"$TMP/stubs/$cmd"
    chmod +x "$TMP/stubs/$cmd"
  done
}

teardown() {
  rm -rf "${TMP:?}"
}

# Runs the copy on empty stdin with the stubs first in PATH. $output holds stdout only;
# stderr goes to $TMP/stderr.
deploy() {
  run bash -c 'PATH="$1:$PATH" "$2" "${@:4}" </dev/null 2>"$3"' _ \
    "$TMP/stubs" "$REPO/deploy.sh" "$TMP/stderr" "$@"
}

has_line() {
  printf '%s\n' "$output" | grep -Eq "$1" || {
    echo "no line matches: $1"
    return 1
  }
}

step_line() {
  printf '%s\n' "$output" | grep -E "^ +[0-9]+\. $1 "
}

@test "--dry-run prints the plan on empty input and exits 0" {
  local steps
  deploy --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == "cdn-deploy dry run: nothing is changed."* ]]
  steps="$(printf '%s\n' "$output" | sed -nE 's/^ +[0-9]+\. ([a-z-]+) .*/\1/p' | tr '\n' ' ')"
  [ "$steps" = "preflight input config packages sysctl certs renew-hook nginx remnawave validate " ]
}

@test "--dry-run on empty input shows the contract defaults and unset required values" {
  deploy --dry-run
  [ "$status" -eq 0 ]
  has_line '^Settings \(no \.env yet'
  has_line '^ +VLESS_DOMAIN +<unset>$'
  has_line '^ +XHTTP_PORT +4443$'
  has_line '^ +XHTTP_PATH +/api/v2\.jpg/$'
  has_line '^ +NGINX_TLS_PORT +8444$'
  has_line '^ +CERT_MODE +dns-cloudflare$'
  has_line 'nginx .*:8444 <CDN_DOMAIN> -> 127\.0\.0\.1:4443'
}

@test "--dry-run changes nothing" {
  local before after
  before="$(cd "$REPO" && find . -type f -exec cksum {} + | sort)"
  deploy --dry-run
  [ "$status" -eq 0 ]
  after="$(cd "$REPO" && find . -type f -exec cksum {} + | sort)"
  [ "$before" = "$after" ]
  [ ! -e "$REPO/.env" ]
  [ ! -e "$TMP/calls" ]
}

@test "--dry-run shows .env values and hides secrets" {
  cat >"$REPO/.env" <<'EOF'
VLESS_DOMAIN=vless.example.com
HY2_DOMAIN=hy2.example.com
CDN_DOMAIN=cdn.example.com
ORIGIN_IP=203.0.113.10
XHTTP_PORT=4450
UUID=3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f
CF_API_TOKEN=tok-7f3a9
EOF
  chmod 600 "$REPO/.env"
  deploy --dry-run
  [ "$status" -eq 0 ]
  has_line '^ +VLESS_DOMAIN +vless\.example\.com$'
  has_line '^ +UUID +<hidden>$'
  has_line '^ +CF_API_TOKEN +<hidden>$'
  has_line 'certs .*vless\.example\.com hy2\.example\.com cdn\.example\.com'
  has_line 'nginx .*:8444 cdn\.example\.com -> 127\.0\.0\.1:4450'
  [[ "$output $(cat "$TMP/stderr")" != *tok-7f3a9* ]]
  [[ "$output $(cat "$TMP/stderr")" != *3f1c2d4e* ]]
}

@test "--dry-run plans no CDN certificate under http-01 or ISSUE_CDN_ORIGIN_CERT=false" {
  local setting certs
  for setting in CERT_MODE=http-01 ISSUE_CDN_ORIGIN_CERT=false; do
    printf 'VLESS_DOMAIN=vless.example.com\nCDN_DOMAIN=cdn.example.com\n%s\n' "$setting" \
      >"$REPO/.env"
    deploy --dry-run
    [ "$status" -eq 0 ]
    certs="$(step_line certs)"
    [[ "$certs" == *"reuses the VLESS_DOMAIN certificate"* ]]
    [[ "$certs" != *cdn.example.com* ]] || {
      echo "$setting still plans a CDN certificate"
      return 1
    }
  done
}

@test "--dry-run exits 2 on a malformed .env" {
  printf 'VLESS_DOMAIN\n' >"$REPO/.env"
  deploy --dry-run
  [ "$status" -eq 2 ]
  [[ "$(cat "$TMP/stderr")" == *".env:1: expected KEY=VALUE"* ]]
}

@test "--dry-run warns about failing guards instead of stopping" {
  deploy --dry-run
  [ "$status" -eq 0 ]
  if ((EUID != 0)); then
    [[ "$(cat "$TMP/stderr")" == *"a real run stops here: root privileges required"* ]]
  fi
}

@test "--help prints usage and exits 0" {
  deploy --help
  [ "$status" -eq 0 ]
  [[ "$output" == Usage:* ]]
}

@test "an unknown option exits 2" {
  deploy --force
  [ "$status" -eq 2 ]
  [[ "$(cat "$TMP/stderr")" == *"unknown option: --force"* ]]
}

@test "a real run without root exits 4 and touches nothing" {
  ((EUID != 0)) || skip "running as root: a real run would change this system"
  deploy
  [ "$status" -eq 4 ]
  [ ! -e "$REPO/.env" ]
  [ ! -e "$TMP/calls" ]
}

@test "the input step is wired to prompt::collect" {
  deploy --dry-run
  [ "$status" -eq 0 ]
  [[ "$(step_line input)" != *"not implemented"* ]]
}
