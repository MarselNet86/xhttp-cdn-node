#!/usr/bin/env bats
# Contract tests for lib/common.sh (tech.md §5, §7). Run from the repo root: bats tests/

setup() {
  # shellcheck source=../lib/common.sh
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  # bats 1.2 on Ubuntu 22.04 has no BATS_TEST_TMPDIR.
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP:?}"
}

# bats reports only the failing line; these name the value that broke the loop.
accepts() {
  local fn="$1" value
  shift
  for value in "$@"; do
    "$fn" "$value" || {
      echo "$fn rejected '$value'"
      return 1
    }
  done
}

rejects() {
  local fn="$1" value
  shift
  for value in "$@"; do
    if "$fn" "$value"; then
      echo "$fn accepted '$value'"
      return 1
    fi
  done
}

# Real os-release files of the supported images, trimmed to the identity fields.
os_release() {
  case "$1" in
    ubuntu-22.04)
      printf '%s\n' 'PRETTY_NAME="Ubuntu 22.04.5 LTS"' 'NAME="Ubuntu"' 'VERSION_ID="22.04"' \
        'VERSION="22.04.5 LTS (Jammy Jellyfish)"' 'VERSION_CODENAME=jammy' 'ID=ubuntu' \
        'ID_LIKE=debian' 'UBUNTU_CODENAME=jammy'
      ;;
    ubuntu-24.04)
      printf '%s\n' 'PRETTY_NAME="Ubuntu 24.04.5 LTS"' 'NAME="Ubuntu"' 'VERSION_ID="24.04"' \
        'VERSION="24.04.5 LTS (Noble Numbat)"' 'VERSION_CODENAME=noble' 'ID=ubuntu' \
        'ID_LIKE=debian' 'UBUNTU_CODENAME=noble'
      ;;
    debian-12)
      printf '%s\n' 'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"' 'NAME="Debian GNU/Linux"' \
        'VERSION_ID="12"' 'VERSION="12 (bookworm)"' 'VERSION_CODENAME=bookworm' 'ID=debian'
      ;;
  esac >"$TMP/os-release"
}

@test "is::fqdn accepts names usable for a certificate" {
  accepts is::fqdn example.com vless.example.com a.b.example.co.uk my-node-1.example.org \
    1.example.com EXAMPLE.COM xn--80ak6aa92e.com cdn.xn--p1ai "$(printf 'a%.0s' {1..63}).com"
}

@test "is::fqdn rejects names certbot or nginx would not take" {
  local long
  long="$(printf 'a%.0s' {1..63})"
  rejects is::fqdn "" localhost com .example.com example.com. example..com -node.example.com \
    node-.example.com "no de.example.com" ex_ample.com "*.example.com" 1.2.3.4 example.c \
    example.123 "${long}a.com" "$long.$long.$long.$long.com" https://example.com \
    example.com/path example.com:443
}

@test "is::ipv4 accepts dotted quads" {
  accepts is::ipv4 0.0.0.0 1.2.3.4 10.0.0.1 203.0.113.10 255.255.255.255
}

@test "is::ipv4 rejects malformed addresses and leading zeros" {
  rejects is::ipv4 "" 1.2.3 1.2.3.4.5 256.1.1.1 1.2.3.256 1234.1.1.1 01.2.3.4 1.2.3.04 \
    00.1.1.1 " 1.2.3.4" "1.2.3.4 " a.b.c.d 1..2.3 1.2.3.4/24 -1.2.3.4 ::1
}

@test "is::port accepts 1-65535" {
  accepts is::port 1 22 80 443 4443 8444 65535
}

@test "is::port rejects zero, out-of-range and non-numeric values" {
  rejects is::port "" 0 00 08 65536 99999 100000 -1 +80 1.5 "80 " " 80" abc 0x50
}

@test "validators never evaluate input as code" {
  cd "$TMP"
  # shellcheck disable=SC2016  # literal on purpose: (( )) on unchecked input would run it
  local sub='$(touch pwned)'
  rejects is::port "x[$sub]" "a[$sub]+1"
  rejects is::ipv4 "1.2.3.x[$sub]"
  rejects is::fqdn "x[$sub].com"
  [ ! -e pwned ]
}

@test "log functions write prefixed lines to stderr and nothing to stdout" {
  local out
  out="$({
    log::info one
    log::warn two
    log::error three
  } 2>"$TMP/err")"
  [ -z "$out" ]
  [ "$(cat "$TMP/err")" = "$(printf '[INFO] one\n[WARN] two\n[ERROR] three')" ]
}

@test "log::die logs an error and exits with the given code" {
  run log::die 7 "nginx -t failed"
  [ "$status" -eq 7 ]
  [ "$output" = "[ERROR] nginx -t failed" ]
}

@test "require::cmd passes for present commands and exits 3 naming a missing one" {
  run require::cmd bash printf
  [ "$status" -eq 0 ]
  run require::cmd bash cdn-deploy-no-such-command
  [ "$status" -eq 3 ]
  [[ "$output" == *cdn-deploy-no-such-command* ]]
}

@test "require::root exits 4 unless running as root" {
  run require::root
  if ((EUID == 0)); then
    [ "$status" -eq 0 ]
  else
    [ "$status" -eq 4 ]
  fi
}

@test "require::distro accepts Ubuntu 22.04, 24.04, Debian 12 and exports PKG_INSTALL" {
  local os
  for os in ubuntu-22.04 ubuntu-24.04 debian-12; do
    os_release "$os"
    run require::distro "$TMP/os-release"
    [ "$status" -eq 0 ] || {
      echo "$os rejected: $output"
      return 1
    }
    unset PKG_INSTALL
    require::distro "$TMP/os-release"
    [[ "$PKG_INSTALL" == *"apt-get install -y"* ]]
    [ "$(bash -c 'printf %s "$PKG_INSTALL"')" = "$PKG_INSTALL" ]
  done
}

@test "require::distro exits 5 on other systems or without os-release" {
  local spec
  for spec in "ubuntu 20.04" "ubuntu 24.10" "debian 11" "debian 13" "fedora 40" \
    "linuxmint 21.3"; do
    printf 'ID=%s\nVERSION_ID="%s"\n' "${spec% *}" "${spec#* }" >"$TMP/os-release"
    run require::distro "$TMP/os-release"
    [ "$status" -eq 5 ] || {
      echo "accepted $spec"
      return 1
    }
  done
  run require::distro "$TMP/missing"
  [ "$status" -eq 5 ]
  : >"$TMP/os-release"
  run require::distro "$TMP/os-release"
  [ "$status" -eq 5 ]
}

@test "env::load sets and exports literal values" {
  cat >"$TMP/env" <<'EOF'
# comment

VLESS_DOMAIN=vless.example.com
export HY2_DOMAIN=hy2.example.com
CDN_DOMAIN = cdn.example.com
NODE_RELOAD_CMD="docker restart remnawave-node"
XHTTP_PATH='/api/v2.jpg/'
LE_EMAIL=
EOF
  env::load "$TMP/env"
  [ "$VLESS_DOMAIN" = vless.example.com ]
  [ "$HY2_DOMAIN" = hy2.example.com ]
  [ "$CDN_DOMAIN" = cdn.example.com ]
  [ "$NODE_RELOAD_CMD" = "docker restart remnawave-node" ]
  [ "$XHTTP_PATH" = /api/v2.jpg/ ]
  [ -z "$LE_EMAIL" ]
  [ "$(bash -c 'printf %s "$NODE_RELOAD_CMD"')" = "docker restart remnawave-node" ]
}

@test "env::load strips comments and CRLF line endings" {
  printf '%s\r\n' 'XHTTP_PORT=4443   # local port' 'CERT_MODE="http-01"  # quoted' \
    'UUID=# nothing yet' 'LE_EMAIL=ops#1@example.com' >"$TMP/env"
  env::load "$TMP/env"
  [ "$XHTTP_PORT" = 4443 ]
  [ "$CERT_MODE" = http-01 ]
  [ -z "$UUID" ]
  [ "$LE_EMAIL" = 'ops#1@example.com' ]
}

@test "env::load never executes the file" {
  cd "$TMP"
  cat >"$TMP/env" <<'EOF'
UUID=$(touch pwned-subst)
LE_EMAIL=`touch pwned-backtick`
NODE_RELOAD_CMD="$(touch pwned-quoted)"
EOF
  chmod 600 "$TMP/env"
  # shellcheck disable=SC2016  # literal on purpose: the loader must keep it as text
  local subst='$(touch pwned-subst)' quoted='$(touch pwned-quoted)'
  env::load "$TMP/env"
  [ "$UUID" = "$subst" ]
  [ "$NODE_RELOAD_CMD" = "$quoted" ]
  [ ! -e pwned-subst ]
  [ ! -e pwned-backtick ]
  [ ! -e pwned-quoted ]
}

@test "env::load skips unknown keys with a warning" {
  local path_before="$PATH"
  printf 'PATH=/nowhere\nVLESS_DOMIAN=typo.example.com\n' >"$TMP/env"
  run env::load "$TMP/env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown key PATH"* ]]
  [[ "$output" == *"unknown key VLESS_DOMIAN"* ]]
  env::load "$TMP/env" 2>/dev/null
  [ "$PATH" = "$path_before" ]
  [ -z "${VLESS_DOMIAN:-}" ]
}

@test "env::load exits 2 on a malformed line without echoing it" {
  printf 'VLESS_DOMAIN=ok.example.com\ntok-7f3a9 without a key\n' >"$TMP/env"
  run env::load "$TMP/env"
  [ "$status" -eq 2 ]
  [[ "$output" == *"$TMP/env:2:"* ]]
  [[ "$output" != *tok-7f3a9* ]]
  printf 'NODE_RELOAD_CMD="docker restart\n' >"$TMP/env"
  run env::load "$TMP/env"
  [ "$status" -eq 2 ]
  printf "CF_API_TOKEN='tok-7f3a9' tail\n" >"$TMP/env"
  run env::load "$TMP/env"
  [ "$status" -eq 2 ]
  [[ "$output" != *tok-7f3a9* ]]
}

@test "env::load exits 2 when the file is missing" {
  run env::load "$TMP/missing"
  [ "$status" -eq 2 ]
}

@test "env::load warns about a readable file with secrets and never prints them" {
  printf 'CF_API_TOKEN=tok-7f3a9\n' >"$TMP/env"
  chmod 644 "$TMP/env"
  run env::load "$TMP/env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"chmod 600"* ]]
  [[ "$output" != *tok-7f3a9* ]]
  chmod 600 "$TMP/env"
  run env::load "$TMP/env"
  [ -z "$output" ]
}

@test "env::require exits 2 naming every empty setting" {
  VLESS_DOMAIN=vless.example.com
  HY2_DOMAIN=""
  unset CDN_DOMAIN
  run env::require VLESS_DOMAIN HY2_DOMAIN CDN_DOMAIN
  [ "$status" -eq 2 ]
  [[ "$output" == *"HY2_DOMAIN CDN_DOMAIN"* ]]
  run env::require VLESS_DOMAIN
  [ "$status" -eq 0 ]
}

@test "confirm returns 0 for yes and 1 for no" {
  local answer
  for answer in y Y yes YES " y "; do
    run confirm "Proceed?" <<<"$answer"
    [ "$status" -eq 0 ] || {
      echo "'$answer' did not count as yes"
      return 1
    }
  done
  for answer in n N no; do
    run confirm "Proceed?" y <<<"$answer"
    [ "$status" -eq 1 ] || {
      echo "'$answer' did not count as no"
      return 1
    }
  done
}

@test "confirm takes the default on an empty answer or EOF" {
  run confirm "Proceed?" <<<""
  [ "$status" -eq 1 ]
  run confirm "Proceed?" y <<<""
  [ "$status" -eq 0 ]
  run confirm "Proceed?" </dev/null
  [ "$status" -eq 1 ]
  run confirm "Proceed?" y </dev/null
  [ "$status" -eq 0 ]
}

@test "confirm asks again after an unclear answer" {
  run confirm "Proceed?" <<<$'maybe\ny'
  [ "$status" -eq 0 ]
  [[ "$output" == *"answer y or n"* ]]
}

@test ".env.example lists the contract keys in order with the contract defaults" {
  local example="$BATS_TEST_DIRNAME/../.env.example" keys key
  keys="$(sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$example" | tr '\n' ' ')"
  [ "$keys" = "${ENV_KEYS[*]} " ]
  run env::load "$example"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  env::load "$example"
  [ "$XHTTP_PORT" = 4443 ]
  [ "$XHTTP_PATH" = /api/v2.jpg/ ]
  [ "$NGINX_TLS_PORT" = 8444 ]
  [ "$CERT_MODE" = dns-cloudflare ]
  [ "$NODE_RELOAD_CMD" = "docker restart remnawave-node" ]
  [ "$ISSUE_CDN_ORIGIN_CERT" = true ]
  for key in VLESS_DOMAIN HY2_DOMAIN CDN_DOMAIN ORIGIN_IP UUID CF_API_TOKEN LE_EMAIL; do
    [ -z "${!key}" ] || {
      echo "$key must have no default"
      return 1
    }
  done
}

# dpkg-query and apt-get stubs: $TMP/installed lists the installed packages.
pkg_stubs() {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/dpkg-query" <<STUB
#!/bin/sh
for last; do :; done
if grep -qx "\$last" "$TMP/installed" 2>/dev/null; then
  printf 'install ok installed'
fi
STUB
  cat >"$TMP/bin/apt-get" <<STUB
#!/bin/sh
echo "apt-get \$*" >>"$TMP/calls"
[ ! -e "$TMP/apt-fail" ]
STUB
  chmod +x "$TMP/bin/dpkg-query" "$TMP/bin/apt-get"
  PATH="$TMP/bin:$PATH"
}

@test "pkg::install refreshes the index once and installs only the missing packages" {
  pkg_stubs
  printf '%s\n' curl jq >"$TMP/installed"
  PKG_INSTALL="env DEBIAN_FRONTEND=noninteractive apt-get install -y"
  run pkg::install curl nginx jq certbot
  [ "$status" -eq 0 ]
  [ "$(tr '\n' '|' <"$TMP/calls")" = "apt-get -o DPkg::Lock::Timeout=300 update -qq|apt-get install -y nginx certbot|" ]
}

@test "pkg::install touches nothing when every package is installed" {
  pkg_stubs
  printf '%s\n' curl jq >"$TMP/installed"
  PKG_INSTALL="apt-get install -y"
  run pkg::install curl jq
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/calls" ]
  [[ "$output" == *"packages already installed: curl jq"* ]]
}

@test "pkg::install exits 3 when apt fails and 1 before require::distro" {
  pkg_stubs
  touch "$TMP/apt-fail"
  PKG_INSTALL="apt-get install -y"
  run pkg::install nginx
  [ "$status" -eq 3 ]
  unset PKG_INSTALL
  run pkg::install nginx
  [ "$status" -eq 1 ]
}

@test "fs::write writes the content, a final newline and the mode atomically" {
  local leftovers
  fs::write "$TMP/f" 640 hello 2>/dev/null
  [ "$FS_CHANGED" -eq 1 ]
  [ "$(cat "$TMP/f")" = hello ]
  [ "$(wc -c <"$TMP/f")" -eq 6 ]
  [ -n "$(find "$TMP/f" -perm 640)" ]
  leftovers=("$TMP"/f.*)
  [ "${leftovers[*]}" = "$TMP/f.*" ]
}

@test "fs::write leaves an identical file alone apart from its mode" {
  fs::write "$TMP/f" 600 hello 2>/dev/null
  touch -d 2020-01-01 "$TMP/f"
  chmod 644 "$TMP/f"
  fs::write "$TMP/f" 600 hello 2>/dev/null
  [ "$FS_CHANGED" -eq 0 ]
  [ -n "$(find "$TMP/f" -perm 600)" ]
  [ "$(date -r "$TMP/f" +%Y)" = 2020 ]
  fs::write "$TMP/f" 600 bye 2>/dev/null
  [ "$FS_CHANGED" -eq 1 ]
  [ "$(cat "$TMP/f")" = bye ]
}

@test "fs::write exits 1 when the directory is missing" {
  run fs::write "$TMP/missing/f" 644 x
  [ "$status" -eq 1 ]
}

@test "SYSROOT follows CDN_DEPLOY_SYSROOT and stays empty without it" {
  local lib="$BATS_TEST_DIRNAME/../lib/common.sh"
  [ -z "$SYSROOT" ]
  run env CDN_DEPLOY_SYSROOT=/scratch bash -c "source \"$lib\" && printf %s \"\$SYSROOT\""
  [ "$output" = /scratch ]
}
