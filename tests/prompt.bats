#!/usr/bin/env bats
# Contract tests for lib/prompt.sh (tech.md §4, §7): questions, validation, .env writing.

setup() {
  # bats 1.2 on Ubuntu 22.04 has no BATS_TEST_TMPDIR.
  TMP="$(mktemp -d)"
  # Sourcing a copy points ENV_FILE at $TMP/repo/.env, away from the real checkout.
  REPO="$TMP/repo"
  mkdir -p "$REPO" "$TMP/bin"
  cp -R "$BATS_TEST_DIRNAME/../lib" "$BATS_TEST_DIRNAME/../.env.example" "$REPO/"
  # shellcheck source=../lib/prompt.sh
  source "$REPO/lib/prompt.sh"
  # No network in tests: the curl stub prints $TMP/ip when it exists and fails otherwise.
  printf '#!/bin/sh\n[ -f "%s/ip" ] && exec cat "%s/ip"\nexit 7\n' "$TMP" "$TMP" >"$TMP/bin/curl"
  chmod +x "$TMP/bin/curl"
  PATH="$TMP/bin:$PATH"
  UUID_V4='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
}

teardown() {
  rm -rf "${TMP:?}"
}

# Runs prompt::collect with one answer per line on stdin; "" presses Enter.
collect() {
  printf '%s\n' "$@" >"$TMP/answers"
  run prompt::collect <"$TMP/answers"
}

# Answers for a fresh .env in dns-cloudflare mode. The curl stub finds no address, so
# ORIGIN_IP is typed; Enter takes the defaults, a random UUID and the CDN certificate.
fresh() {
  collect vless.example.com hy2.example.com cdn.example.com 203.0.113.10 \
    "" "" "" "" "" tok-7f3a9 "" "" ""
}

# Enter for each of the 13 questions a rerun over a complete dns-cloudflare .env asks.
rerun_enter() {
  collect "" "" "" "" "" "" "" "" "" "" "" "" ""
}

mode_600() {
  [ -n "$(find "$ENV_FILE" -perm 600)" ]
}

valid() {
  local key="$1" value
  shift
  for value in "$@"; do
    prompt::validate "$key" "$value" >/dev/null || {
      echo "$key rejected '$value'"
      return 1
    }
  done
}

invalid() {
  local key="$1" value
  shift
  for value in "$@"; do
    if prompt::validate "$key" "$value" >/dev/null; then
      echo "$key accepted '$value'"
      return 1
    fi
  done
}

@test "collect writes every contract key in table order with mode 600" {
  local keys siblings
  fresh
  [ "$status" -eq 0 ]
  keys="$(sed -nE 's/^([A-Z0-9_]+)=.*/\1/p' "$ENV_FILE" | tr '\n' ' ')"
  [ "$keys" = "${ENV_KEYS[*]} " ]
  mode_600
  # The atomic write leaves no temporary .env.XXXXXX behind.
  siblings=("$REPO"/.env.*)
  [ "${siblings[*]}" = "$REPO/.env.example" ]
  env::load "$ENV_FILE"
  [ "$VLESS_DOMAIN" = vless.example.com ]
  [ "$HY2_DOMAIN" = hy2.example.com ]
  [ "$CDN_DOMAIN" = cdn.example.com ]
  [ "$ORIGIN_IP" = 203.0.113.10 ]
  [ "$CF_API_TOKEN" = tok-7f3a9 ]
}

@test "Enter takes the contract defaults and a random UUIDv4 that is never shown" {
  local shown
  fresh
  [ "$status" -eq 0 ]
  shown="$output"
  env::load "$ENV_FILE"
  [ "$XHTTP_PORT" = 4443 ]
  [ "$XHTTP_PATH" = /api/v2.jpg/ ]
  [ "$NGINX_TLS_PORT" = 8444 ]
  [ "$CERT_MODE" = dns-cloudflare ]
  [ -z "$LE_EMAIL" ]
  [ "$NODE_RELOAD_CMD" = "docker restart remnanode" ]
  [ "$ISSUE_CDN_ORIGIN_CERT" = true ]
  [[ "$UUID" =~ $UUID_V4 ]]
  [[ "$shown" != *"$UUID"* ]]
  [[ "$shown" != *tok-7f3a9* ]]
  [ "$REALITY_SNI" = www.swiss.com ]
  [[ "$REALITY_PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]]
  [[ "$REALITY_SHORT_ID" =~ ^[0-9a-f]{16}$ ]]
  [[ "$shown" != *"$REALITY_PRIVATE_KEY"* ]]
}

@test "the Reality keys stay across reruns, and - for REALITY_SNI skips them" {
  local key sid
  fresh
  env::load "$ENV_FILE"
  key="$REALITY_PRIVATE_KEY"
  sid="$REALITY_SHORT_ID"
  run prompt::collect </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"REALITY_PRIVATE_KEY [keep current]:"* ]]
  env::load "$ENV_FILE"
  [ "$REALITY_PRIVATE_KEY" = "$key" ]
  [ "$REALITY_SHORT_ID" = "$sid" ]
  rm "$ENV_FILE"
  collect vless.example.com hy2.example.com cdn.example.com 203.0.113.10 \
    "" "" "" "" "" tok-7f3a9 "" "" "" -
  [ "$status" -eq 0 ]
  [[ "$output" != *"REALITY_PRIVATE_KEY"* ]]
  env::load "$ENV_FILE"
  [ -z "$REALITY_SNI" ]
}

@test "empty input repeats the question for CDN_DOMAIN, the only domain always required" {
  collect vless.example.com hy2.example.com "" cdn.example.com 203.0.113.10 \
    "" "" "" "" "" tok-7f3a9 "" "" ""
  [ "$status" -eq 0 ]
  [ "$(grep -c 'WARN.*_DOMAIN: expected a domain name' <<<"$output")" -eq 1 ]
  [[ "$output" == *"CDN_DOMAIN: expected a domain name"* ]]
  env::load "$ENV_FILE"
  [ "$CDN_DOMAIN" = cdn.example.com ]
}

@test "a server that already runs VLESS and Hysteria2 skips both and gets the CDN only" {
  collect "" - cdn.example.com 203.0.113.10 "" "" "" "" "" tok-7f3a9 "" ""
  [ "$status" -eq 0 ]
  [ "$(grep -c -E 'WARN.*_DOMAIN|needs a certificate' <<<"$output")" -eq 0 ]
  # No Hysteria2 certificate to renew, so no node restart command to ask for.
  [[ "$output" != *"Command that restarts the node"* ]]
  env::load "$ENV_FILE"
  [ -z "$VLESS_DOMAIN" ]
  [ -z "$HY2_DOMAIN" ]
  [ "$CDN_DOMAIN" = cdn.example.com ]
  [ "$ISSUE_CDN_ORIGIN_CERT" = true ]
}

@test "http-01 without a domain of this server asks for VLESS_DOMAIN again" {
  collect "" "" cdn.example.com 203.0.113.10 "" "" "" "" http-01 "" "" "" "" vless.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"origin nginx needs a certificate: under http-01 or ISSUE_CDN_ORIGIN_CERT=false it comes from VLESS_DOMAIN"* ]]
  env::load "$ENV_FILE"
  [ "$VLESS_DOMAIN" = vless.example.com ]
  [ -z "$HY2_DOMAIN" ]
  rm "$ENV_FILE"
  collect "" "" cdn.example.com 203.0.113.10 "" "" "" "" http-01 ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"VLESS_DOMAIN: origin nginx needs a certificate for a domain of this server"* ]]
}

@test "- clears VLESS_DOMAIN and HY2_DOMAIN kept in .env" {
  collect vless.example.com hy2.example.com cdn.example.com 203.0.113.10 \
    "" "" "" "" "" tok-7f3a9 "" "" ""
  [ "$status" -eq 0 ]
  collect - - "" "" "" "" "" "" "" "" "" ""
  [ "$status" -eq 0 ]
  env::load "$ENV_FILE"
  [ -z "$VLESS_DOMAIN" ]
  [ -z "$HY2_DOMAIN" ]
  [ "$CDN_DOMAIN" = cdn.example.com ]
}

@test "invalid answers are rejected with a reason and asked again" {
  local key
  collect vless_example.com vless.example.com hy2.example.com \
    vless.example.com cdn.example.com \
    300.1.1.1 203.0.113.10 \
    443 4450 \
    api/ /cdn/v1.bin/ \
    4450 8450 \
    not-a-uuid "" \
    dns "" \
    "tok en" tok-7f3a9 \
    ops@localhost ops@example.com \
    "a 'b' \"c\"" "" \
    maybe n
  [ "$status" -eq 0 ]
  for key in VLESS_DOMAIN CDN_DOMAIN ORIGIN_IP XHTTP_PORT XHTTP_PATH NGINX_TLS_PORT UUID \
    CERT_MODE CF_API_TOKEN LE_EMAIL NODE_RELOAD_CMD; do
    grep -qF "[WARN] $key: " <<<"$output" || {
      echo "no warning for $key"
      return 1
    }
  done
  [[ "$output" == *"answer y or n"* ]]
  env::load "$ENV_FILE"
  [ "$CDN_DOMAIN" = cdn.example.com ]
  [ "$XHTTP_PORT" = 4450 ]
  [ "$XHTTP_PATH" = /cdn/v1.bin/ ]
  [ "$NGINX_TLS_PORT" = 8450 ]
  [ "$LE_EMAIL" = ops@example.com ]
  [ "$ISSUE_CDN_ORIGIN_CERT" = false ]
}

@test "input that ends before a required answer exits 2 and writes nothing" {
  collect vless.example.com hy2.example.com
  [ "$status" -eq 2 ]
  [[ "$output" == *"CDN_DOMAIN: expected a domain name"* ]]
  [ ! -e "$ENV_FILE" ]
  collect vless.example.com hy2.example.com cdn.example.com 203.0.113.10 "" "" "" "" ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"CF_API_TOKEN: expected a Cloudflare API token"* ]]
  [ ! -e "$ENV_FILE" ]
}

@test "a detected IPv4 is offered and used on confirmation" {
  echo 198.51.100.7 >"$TMP/ip"
  collect vless.example.com hy2.example.com cdn.example.com "" \
    "" "" "" "" "" tok-7f3a9 "" "" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"Detected public IPv4 198.51.100.7"* ]]
  env::load "$ENV_FILE"
  [ "$ORIGIN_IP" = 198.51.100.7 ]
}

@test "declining the detected IPv4 asks for it by hand" {
  echo 198.51.100.7 >"$TMP/ip"
  collect vless.example.com hy2.example.com cdn.example.com n 203.0.113.10 \
    "" "" "" "" "" tok-7f3a9 "" "" ""
  [ "$status" -eq 0 ]
  env::load "$ENV_FILE"
  [ "$ORIGIN_IP" = 203.0.113.10 ]
}

@test "a garbled detection falls back to typing the IPv4" {
  echo '<html>blocked</html>' >"$TMP/ip"
  fresh
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot detect the public IPv4"* ]]
  env::load "$ENV_FILE"
  [ "$ORIGIN_IP" = 203.0.113.10 ]
}

@test "http-01 skips the token and forces ISSUE_CDN_ORIGIN_CERT=false" {
  collect vless.example.com hy2.example.com cdn.example.com 203.0.113.10 \
    "" "" "" "" http-01 "" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"CF_API_TOKEN:"* ]]
  [[ "$output" == *"ISSUE_CDN_ORIGIN_CERT=false: http-01 cannot validate CDN_DOMAIN"* ]]
  env::load "$ENV_FILE"
  [ "$CERT_MODE" = http-01 ]
  [ "$ISSUE_CDN_ORIGIN_CERT" = false ]
  [ -z "$CF_API_TOKEN" ]
}

@test "a rerun keeps .env byte for byte and restores mode 600" {
  fresh
  cp "$ENV_FILE" "$TMP/first"
  chmod 644 "$ENV_FILE"
  rerun_enter
  [ "$status" -eq 0 ]
  cmp "$ENV_FILE" "$TMP/first"
  mode_600
  [[ "$output" == *"is up to date"* ]]
  # Without a terminal a complete .env passes as is, so deploy.sh can run unattended.
  run prompt::collect </dev/null
  [ "$status" -eq 0 ]
  cmp "$ENV_FILE" "$TMP/first"
}

@test "a rerun offers current values as defaults and never prints secrets" {
  local uuid
  fresh
  env::load "$ENV_FILE"
  uuid="$UUID"
  run prompt::collect </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"VLESS_DOMAIN [vless.example.com]:"* ]]
  [[ "$output" == *"XHTTP_PATH [/api/v2.jpg/]:"* ]]
  [[ "$output" == *"UUID [keep current]:"* ]]
  [[ "$output" == *"CF_API_TOKEN [keep current]:"* ]]
  [[ "$output" != *tok-7f3a9* ]]
  [[ "$output" != *"$uuid"* ]]
}

@test "a rerun rejects an invalid value from .env instead of keeping it" {
  cat >"$ENV_FILE" <<'EOF'
VLESS_DOMAIN=vless.example.com
HY2_DOMAIN=hy2.example.com
CDN_DOMAIN=cdn.example.com
ORIGIN_IP=203.0.113.10
XHTTP_PORT=99999
UUID=3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f
CF_API_TOKEN=tok-7f3a9
EOF
  chmod 600 "$ENV_FILE"
  run prompt::collect </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"XHTTP_PORT: expected a port"* ]]
  collect "" "" "" "" "" 4450 "" "" "" "" "" "" "" ""
  [ "$status" -eq 0 ]
  env::load "$ENV_FILE"
  [ "$XHTTP_PORT" = 4450 ]
}

@test "commands with quotes, # and spaces survive the .env round trip" {
  local cmd
  for cmd in 'docker compose -f "/opt/remna node/compose.yml" restart # node' \
    "sh -c 'docker restart remnawave-node'"; do
    rm -f "$ENV_FILE"
    collect vless.example.com hy2.example.com cdn.example.com 203.0.113.10 \
      "" "" "" "" "" tok-7f3a9 "" "$cmd" ""
    [ "$status" -eq 0 ]
    env::load "$ENV_FILE"
    [ "$NODE_RELOAD_CMD" = "$cmd" ] || {
      echo "stored as: $NODE_RELOAD_CMD"
      return 1
    }
  done
}

@test "domains and the UUID are stored in lowercase and - clears LE_EMAIL" {
  collect VLESS.Example.COM HY2.EXAMPLE.COM Cdn.Example.Com 203.0.113.10 "" "" "" \
    3F1C2D4E-5A6B-4C7D-8E9F-0A1B2C3D4E5F "" tok-7f3a9 ops@example.com "" ""
  [ "$status" -eq 0 ]
  env::load "$ENV_FILE"
  [ "$VLESS_DOMAIN" = vless.example.com ]
  [ "$HY2_DOMAIN" = hy2.example.com ]
  [ "$CDN_DOMAIN" = cdn.example.com ]
  [ "$UUID" = 3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f ]
  [ "$LE_EMAIL" = ops@example.com ]
  collect "" "" "" "" "" "" "" "" "" "" - "" ""
  [ "$status" -eq 0 ]
  env::load "$ENV_FILE"
  [ -z "$LE_EMAIL" ]
}

@test "a paste loses the invisible characters it carries, no-break spaces at the ends too" {
  local zwsp=$'\xe2\x80\x8b' nbsp=$'\xc2\xa0' bom=$'\xef\xbb\xbf' shy=$'\xc2\xad'
  collect "${bom}vless.exa${zwsp}mple.com${nbsp}" "${nbsp}hy2.example.com" "cdn.ex${shy}ample.com" \
    203.0.113.10 "" "" "" "" "" tok-7f3a9 "" "" ""
  [ "$status" -eq 0 ]
  run grep -E '^\[WARN\] [A-Z0-9]+_DOMAIN:' <<<"$output"
  [ "$status" -eq 1 ]
  env::load "$ENV_FILE"
  [ "$VLESS_DOMAIN" = vless.example.com ]
  [ "$HY2_DOMAIN" = hy2.example.com ]
  [ "$CDN_DOMAIN" = cdn.example.com ]
}

@test "prompt::validate: domains, with CDN_DOMAIN apart from the others" {
  VLESS_DOMAIN=vless.example.com
  HY2_DOMAIN=hy2.example.com
  valid VLESS_DOMAIN vless.example.com
  valid HY2_DOMAIN vless.example.com hy2.example.com
  invalid VLESS_DOMAIN localhost vless_example.com
  valid CDN_DOMAIN cdn.example.com
  invalid CDN_DOMAIN "" vless.example.com hy2.example.com
  CDN_DOMAIN=cdn.example.com
  invalid VLESS_DOMAIN cdn.example.com
  invalid HY2_DOMAIN cdn.example.com
}

@test "prompt::validate: VLESS_DOMAIN and HY2_DOMAIN may stay empty unless origin needs VLESS_DOMAIN" {
  CERT_MODE=dns-cloudflare
  ISSUE_CDN_ORIGIN_CERT=true
  valid VLESS_DOMAIN ""
  valid HY2_DOMAIN ""
  CERT_MODE=http-01
  invalid VLESS_DOMAIN ""
  valid HY2_DOMAIN ""
  CERT_MODE=dns-cloudflare
  ISSUE_CDN_ORIGIN_CERT=false
  invalid VLESS_DOMAIN ""
}

@test "prompt::validate: ports stay off 443 and off each other" {
  XHTTP_PORT=4443
  valid XHTTP_PORT 1 4443 8080 65535
  invalid XHTTP_PORT "" 0 443 65536 abc
  valid NGINX_TLS_PORT 8444 8443
  invalid NGINX_TLS_PORT 443 4443
}

@test "prompt::validate: XHTTP_PATH is /segments/ of URL-safe characters" {
  valid XHTTP_PATH /api/v2.jpg/ /a/ /A-b_c~d.e/f/
  invalid XHTTP_PATH "" / // api/ /api /api/v2.jpg "/a b/" '/a"b/' "/a'b/" /a/../b/ /./ \
    '/a;b/' /a%20b/ '/a{b}/' "/a\$b/"
}

@test "prompt::validate: the remaining keys follow the contract table" {
  valid UUID 3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f "$(</proc/sys/kernel/random/uuid)"
  invalid UUID "" not-a-uuid 3f1c2d4e-5a6b-1c7d-8e9f-0a1b2c3d4e5f \
    3f1c2d4e-5a6b-4c7d-7e9f-0a1b2c3d4e5f 3f1c2d4e5a6b4c7d8e9f0a1b2c3d4e5f
  valid CERT_MODE dns-cloudflare http-01
  invalid CERT_MODE "" dns http http-01x
  valid CF_API_TOKEN tok-7f3a9 AbC_123-xyz
  invalid CF_API_TOKEN "" "tok en" 'tok"en' "tok'en" tok/en
  valid LE_EMAIL "" ops@example.com a.b+c@mail.example.co.uk
  invalid LE_EMAIL ops ops@ @example.com ops@localhost "o ps@example.com" ops@@example.com
  valid NODE_RELOAD_CMD "docker restart remnawave-node" "sh -c 'docker restart x'" \
    'docker compose -f "/a b/c.yml" restart'
  invalid NODE_RELOAD_CMD "" "a 'b' \"c\""
  valid ISSUE_CDN_ORIGIN_CERT true false
  invalid ISSUE_CDN_ORIGIN_CERT "" yes TRUE 1
}

@test "prompt::validate: the Reality site, key and short id" {
  valid REALITY_SNI www.swiss.com ""
  invalid REALITY_SNI localhost "www.swiss.com:443"
  valid REALITY_PRIVATE_KEY c3ludGhldGljLXJlYWxpdHkta2V5LWZvci10ZXN0cyE
  invalid REALITY_PRIVATE_KEY "" short "c3ludGhldGljLXJlYWxpdHkta2V5LWZvci10ZXN0c+E"
  valid REALITY_SHORT_ID 1a2b3c4d5e6f7a8b ab
  invalid REALITY_SHORT_ID "" abc 1a2b3c4d5e6f7a8baa xyz0
}

@test "prompt::validate prints the reason and rejects keys outside the contract" {
  run prompt::validate XHTTP_PORT 443
  [ "$status" -eq 1 ]
  [ "$output" = "443 belongs to xray: Reality over TCP, Hysteria2 over UDP" ]
  run prompt::validate PATH /usr/bin
  [ "$status" -eq 1 ]
}
