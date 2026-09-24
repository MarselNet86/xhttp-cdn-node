#!/usr/bin/env bats
# Contract tests for lib/certs.sh (tech.md §5, §7): which certificates get issued, what is
# kept, how failures end, what the renewal hooks do. certbot, nginx, systemctl and docker
# are stubs; system files land under CDN_DEPLOY_SYSROOT.

setup() {
  # bats 1.2 on Ubuntu 22.04 has no BATS_TEST_TMPDIR.
  TMP="$(mktemp -d)"
  REPO="$TMP/repo"
  mkdir -p "$REPO" "$TMP/bin" "$TMP/root"
  cp -R "$BATS_TEST_DIRNAME/../lib" "$BATS_TEST_DIRNAME/../templates" \
    "$BATS_TEST_DIRNAME/../.env.example" "$REPO/"
  export CDN_DEPLOY_SYSROOT="$TMP/root" STUB_DIR="$TMP"
  stubs
  PATH="$TMP/bin:$PATH"
  # shellcheck source=../lib/certs.sh
  source "$REPO/lib/certs.sh"
  LE="$TMP/root/etc/letsencrypt"
  VLESS_DOMAIN=vless.example.com
  HY2_DOMAIN=hy2.example.com
  CDN_DOMAIN=cdn.example.com
  CERT_MODE=dns-cloudflare
  CF_API_TOKEN=tok-7f3a9
  LE_EMAIL=""
  NODE_RELOAD_CMD="docker restart remnawave-node"
  ISSUE_CDN_ORIGIN_CERT=true
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
  # fake-cert DOMAIN DAYS METHOD [SAN]: a self-signed stand-in for a certbot lineage.
  stub fake-cert <<'EOF'
set -e
le="$CDN_DEPLOY_SYSROOT/etc/letsencrypt"
mkdir -p "$le/live/$1" "$le/renewal"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days "$2" \
  -subj "/CN=$1" -addext "subjectAltName=DNS:${4:-$1}" \
  -keyout "$le/live/$1/privkey.pem" -out "$le/live/$1/fullchain.pem" 2>/dev/null
printf 'authenticator = %s\n' "$3" >"$le/renewal/$1.conf"
EOF
  stub certbot <<'EOF'
echo "certbot $*" >>"$STUB_DIR/calls"
name="" method=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cert-name) name="$2"; shift ;;
    --dns-cloudflare) method=dns-cloudflare ;;
    --webroot) method=webroot ;;
  esac
  shift
done
if grep -qx "$name" "$STUB_DIR/certbot-fail" 2>/dev/null; then
  echo "certbot stub: the challenge for $name failed" >&2
  exit 1
fi
exec fake-cert "$name" 90 "$method"
EOF
  # Like nginx, prints a notice on a successful reload.
  stub nginx <<'EOF'
echo "nginx $*" >>"$STUB_DIR/calls"
if [ "$1" = -t ] && [ -e "$STUB_DIR/nginx-t-fail" ]; then
  echo "nginx: [emerg] the stub rejects the config" >&2
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
  is-enabled) [ -e "$STUB_DIR/timer-enabled" ] ;;
esac
EOF
  # Serves the readiness probe the way nginx would, unless curl-silent is set.
  stub curl <<'EOF'
echo "curl $*" >>"$STUB_DIR/calls"
[ ! -e "$STUB_DIR/curl-silent" ] || exit 7
cat "$CDN_DEPLOY_SYSROOT/var/www/cdn-deploy-acme/.well-known/acme-challenge/cdn-deploy-probe" 2>/dev/null
EOF
  # Brackets keep argument boundaries visible in the log.
  stub docker <<'EOF'
{
  printf 'docker'
  printf ' [%s]' "$@"
  echo
} >>"$STUB_DIR/calls"
[ ! -e "$STUB_DIR/docker-fail" ]
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

# The link points at the host path of the site, which does not exist under SYSROOT: test
# the link itself, since -e is false for a dangling link.
acme_closed() {
  [ ! -L "$TMP/root/etc/nginx/sites-enabled/cdn-deploy-acme.conf" ]
}

snapshot() {
  find "$1" -type f -exec cksum {} + | sort
}

@test "dns-cloudflare issues VLESS, HY2 and CDN certificates with a private token file" {
  local domain
  run certs::issue
  [ "$status" -eq 0 ]
  [ "$(calls '^certbot certonly')" -eq 3 ]
  for domain in vless.example.com hy2.example.com cdn.example.com; do
    grep -qF -- "--cert-name $domain -d $domain --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cdn-deploy/cloudflare.ini" \
      "$TMP/calls" || {
      echo "no DNS-01 call for $domain"
      return 1
    }
    [ -s "$LE/live/$domain/fullchain.pem" ]
  done
  [ "$(sed -n 's/^dns_cloudflare_api_token = //p' "$LE/cdn-deploy/cloudflare.ini")" = tok-7f3a9 ]
  [ -n "$(find "$LE/cdn-deploy/cloudflare.ini" -perm 600)" ]
  [ -n "$(find "$LE/cdn-deploy" -maxdepth 0 -perm 700)" ]
  [[ "$output" != *tok-7f3a9* ]]
}

@test "ISSUE_CDN_ORIGIN_CERT=false leaves CDN_DOMAIN without a certificate" {
  ISSUE_CDN_ORIGIN_CERT=false
  run certs::issue
  [ "$status" -eq 0 ]
  [ "$(calls '^certbot certonly')" -eq 2 ]
  [ ! -e "$LE/live/cdn.example.com" ]
}

@test "a domain shared by VLESS and Hysteria2 gets one certificate" {
  HY2_DOMAIN=vless.example.com
  run certs::issue
  [ "$status" -eq 0 ]
  [ "$(calls '--cert-name vless.example.com ')" -eq 1 ]
}

@test "valid certificates are kept and a rerun changes nothing" {
  local before
  run certs::issue
  [ "$status" -eq 0 ]
  before="$(snapshot "$TMP/root")"
  : >"$TMP/calls"
  run certs::issue
  [ "$status" -eq 0 ]
  [ "$(calls .)" -eq 0 ]
  [ "$(snapshot "$TMP/root")" = "$before" ]
  [[ "$output" == *"certificate for vless.example.com is valid for more than 30 days, kept"* ]]
}

@test "a certificate with 31 days left is kept, one with 30 or less is issued again" {
  fake-cert vless.example.com 31 dns-cloudflare
  fake-cert hy2.example.com 30 dns-cloudflare
  run certs::issue
  [ "$status" -eq 0 ]
  [ "$(calls '--cert-name vless.example.com ')" -eq 0 ]
  [ "$(calls '--cert-name hy2.example.com ')" -eq 1 ]
}

@test "a certificate for another name or renewed by another method is issued again" {
  fake-cert vless.example.com 90 dns-cloudflare other.example.com
  fake-cert hy2.example.com 90 webroot
  fake-cert cdn.example.com 90 dns-cloudflare
  run certs::issue
  [ "$status" -eq 0 ]
  [ "$(calls '--cert-name vless.example.com ')" -eq 1 ]
  [ "$(calls '--cert-name hy2.example.com ')" -eq 1 ]
  [ "$(calls '--cert-name cdn.example.com ')" -eq 0 ]
  # Without --force-renewal certbot keeps a certificate that is not due yet.
  [ "$(calls '^certbot certonly .*--force-renewal .*--cert-name hy2.example.com ')" -eq 1 ]
}

@test "a certbot failure exits 6 after trying every domain" {
  echo hy2.example.com >"$TMP/certbot-fail"
  run certs::issue
  [ "$status" -eq 6 ]
  [ "$(calls '^certbot certonly')" -eq 3 ]
  [[ "$output" == *"no certificate for: hy2.example.com."* ]]
  [[ "$output" == *"Zone:DNS:Edit"* ]]
  [ -s "$LE/live/cdn.example.com/fullchain.pem" ]
}

@test "http-01 opens :80 only around certbot and never issues CDN_DOMAIN" {
  local site="$TMP/root/etc/nginx/sites-available/cdn-deploy-acme.conf" sequence
  CERT_MODE=http-01
  run certs::issue
  [ "$status" -eq 0 ]
  grep -qF 'server_name vless.example.com hy2.example.com;' "$site"
  grep -qF 'root /var/www/cdn-deploy-acme;' "$site"
  [ -d "$TMP/root/var/www/cdn-deploy-acme" ]
  acme_closed
  sequence="$(grep -E '^(nginx|certbot)' "$TMP/calls" |
    sed -E 's/^certbot certonly .*--cert-name ([^ ]+) .*--webroot -w ([^ ]+).*/certbot \1 \2/' |
    tr '\n' '|')"
  [ "$sequence" = "nginx -t|nginx -s reload|certbot vless.example.com /var/www/cdn-deploy-acme|certbot hy2.example.com /var/www/cdn-deploy-acme|nginx -s reload|" ]
}

@test "http-01 leaves nginx as it was when nginx rejects the ACME server" {
  CERT_MODE=http-01
  touch "$TMP/nginx-t-fail"
  run certs::issue
  [ "$status" -eq 6 ]
  acme_closed
  [ "$(calls 'nginx -s reload')" -eq 0 ]
  [ "$(calls '^certbot')" -eq 0 ]
}

@test "http-01 waits for the ACME server to answer after the reload" {
  CERT_MODE=http-01
  run certs::issue
  [ "$status" -eq 0 ]
  [ "$(calls "^curl .*-H Host: vless.example.com http://127.0.0.1/.well-known/acme-challenge/cdn-deploy-probe")" -eq 1 ]
  [ ! -e "$TMP/root/var/www/cdn-deploy-acme/.well-known/acme-challenge/cdn-deploy-probe" ]
}

@test "http-01 gives up and closes :80 when the ACME server never answers" {
  CERT_MODE=http-01
  touch "$TMP/curl-silent"
  run certs::issue
  [ "$status" -eq 6 ]
  [[ "$output" == *"does not answer on 127.0.0.1:80"* ]]
  acme_closed
  [ "$(calls '^certbot')" -eq 0 ]
}

@test "http-01 keeps :80 closed when nginx fails to reload" {
  CERT_MODE=http-01
  touch "$TMP/nginx-reload-fail"
  run certs::issue
  [ "$status" -eq 6 ]
  [[ "$output" == *"nginx -s reload failed: nginx: [error] invalid PID number"* ]]
  acme_closed
  [ "$(calls '^certbot')" -eq 0 ]
}

@test "http-01 closes :80 again when certbot fails" {
  CERT_MODE=http-01
  echo vless.example.com >"$TMP/certbot-fail"
  run certs::issue
  [ "$status" -eq 6 ]
  acme_closed
  [ "$(calls 'nginx -s reload')" -eq 2 ]
  [[ "$output" == *"port 80 is open"* ]]
}

@test "http-01 starts nginx when it is down instead of reloading it" {
  CERT_MODE=http-01
  touch "$TMP/nginx-down"
  run certs::issue
  [ "$status" -eq 0 ]
  [ "$(calls '^systemctl start nginx')" -eq 2 ]
  [ "$(calls 'nginx -s reload')" -eq 0 ]
}

@test "switching to dns-cloudflare reissues and removes the ACME server" {
  CERT_MODE=http-01
  run certs::issue
  [ "$status" -eq 0 ]
  [ -e "$TMP/root/etc/nginx/sites-available/cdn-deploy-acme.conf" ]
  : >"$TMP/calls"
  CERT_MODE=dns-cloudflare
  run certs::issue
  [ "$status" -eq 0 ]
  [ "$(calls '^certbot certonly .*--dns-cloudflare ')" -eq 3 ]
  [ ! -e "$TMP/root/etc/nginx/sites-available/cdn-deploy-acme.conf" ]
}

@test "a new Hysteria2 certificate restarts the node, a kept one does not" {
  run certs::issue
  [ "$status" -eq 0 ]
  [ "$(calls '^docker \[restart\] \[remnawave-node\]$')" -eq 1 ]
  : >"$TMP/calls"
  fake-cert vless.example.com 10 dns-cloudflare
  run certs::issue
  [ "$status" -eq 0 ]
  [ "$(calls '^certbot certonly')" -eq 1 ]
  [ "$(calls '^docker')" -eq 0 ]
}

@test "a failing node restart only warns" {
  touch "$TMP/docker-fail"
  run certs::issue
  [ "$status" -eq 0 ]
  [[ "$output" == *"node restart failed"* ]]
}

@test "LE_EMAIL goes to certbot, an empty one registers without email" {
  HY2_DOMAIN=vless.example.com
  ISSUE_CDN_ORIGIN_CERT=false
  LE_EMAIL=ops@example.com
  run certs::issue
  [ "$status" -eq 0 ]
  [ "$(calls '--email ops@example.com --no-eff-email$')" -eq 1 ]
  rm -rf "$LE/live"
  LE_EMAIL=""
  run certs::issue
  [ "$status" -eq 0 ]
  [ "$(calls '--register-unsafely-without-email$')" -eq 1 ]
}

@test "an unknown CERT_MODE exits 2" {
  CERT_MODE=manual
  run certs::issue
  [ "$status" -eq 2 ]
  [ "$(calls .)" -eq 0 ]
}

@test "install_renew_hook writes an executable deploy hook and turns certbot.timer on" {
  local hook="$LE/renewal-hooks/deploy/cdn-deploy.sh"
  run certs::install_renew_hook
  [ "$status" -eq 0 ]
  [ -n "$(find "$hook" -perm 755)" ]
  sh -n "$hook"
  [ "$(calls '^systemctl enable --now certbot.timer')" -eq 1 ]
}

@test "the deploy hook reloads nginx and restarts the node only for HY2_DOMAIN" {
  local hook="$LE/renewal-hooks/deploy/cdn-deploy.sh"
  certs::install_renew_hook 2>/dev/null
  : >"$TMP/calls"
  run env RENEWED_DOMAINS=vless.example.com "$hook"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/calls")" = "nginx -s reload" ]
  : >"$TMP/calls"
  run env RENEWED_DOMAINS=hy2.example.com "$hook"
  [ "$status" -eq 0 ]
  [ "$(tr '\n' '|' <"$TMP/calls")" = "nginx -s reload|docker [restart] [remnawave-node]|" ]
  touch "$TMP/docker-fail"
  run env RENEWED_DOMAINS=hy2.example.com "$hook"
  [ "$status" -eq 1 ]
}

# Only the deploy hook runs here: the pre and post hooks edit the real /etc/nginx.
@test "the deploy hook stays silent while nginx reloads fine and reports a failure" {
  local hook="$LE/renewal-hooks/deploy/cdn-deploy.sh"
  certs::install_renew_hook 2>/dev/null
  run env RENEWED_DOMAINS=vless.example.com "$hook"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  touch "$TMP/nginx-reload-fail"
  run env RENEWED_DOMAINS=vless.example.com "$hook"
  [ "$status" -eq 1 ]
  [ "$output" = "nginx: [error] invalid PID number" ]
}

@test "the deploy hook runs a command with quotes, # and spaces as written" {
  NODE_RELOAD_CMD="docker compose -f \"/opt/remna node/c.yml\" restart # it's"
  certs::install_renew_hook 2>/dev/null
  : >"$TMP/calls"
  run env RENEWED_DOMAINS=hy2.example.com "$LE/renewal-hooks/deploy/cdn-deploy.sh"
  [ "$status" -eq 0 ]
  grep -qxF 'docker [compose] [-f] [/opt/remna node/c.yml] [restart]' "$TMP/calls"
}

@test "install_renew_hook changes nothing on a rerun" {
  local before
  certs::install_renew_hook 2>/dev/null
  touch "$TMP/timer-enabled"
  before="$(snapshot "$LE/renewal-hooks")"
  : >"$TMP/calls"
  run certs::install_renew_hook
  [ "$status" -eq 0 ]
  [ "$(snapshot "$LE/renewal-hooks")" = "$before" ]
  [[ "$output" == *"cdn-deploy.sh is up to date"* ]]
  [ "$(calls '^systemctl enable')" -eq 0 ]
}

@test "http-01 adds the :80 pre and post hooks, dns-cloudflare removes them" {
  local pre="$LE/renewal-hooks/pre/cdn-deploy-acme.sh" post="$LE/renewal-hooks/post/cdn-deploy-acme.sh"
  CERT_MODE=http-01
  run certs::install_renew_hook
  [ "$status" -eq 0 ]
  sh -n "$pre"
  sh -n "$post"
  [ -n "$(find "$pre" "$post" -perm 755 | sed -n 2p)" ]
  grep -qF 'ln -sfn /etc/nginx/sites-available/cdn-deploy-acme.conf /etc/nginx/sites-enabled/cdn-deploy-acme.conf' "$pre"
  grep -qF "curl -s --max-time 2 -H 'Host: vless.example.com' http://127.0.0.1/.well-known/acme-challenge/cdn-deploy-probe" "$pre"
  grep -qF 'rm -f /etc/nginx/sites-enabled/cdn-deploy-acme.conf' "$post"
  CERT_MODE=dns-cloudflare
  run certs::install_renew_hook
  [ "$status" -eq 0 ]
  [ ! -e "$pre" ]
  [ ! -e "$post" ]
}
