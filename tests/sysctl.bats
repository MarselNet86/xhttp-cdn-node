#!/usr/bin/env bats
# Contract tests for lib/sysctl.sh (tech.md §5, §6): the installed tuning, its check against
# the kernel, reruns, nofile limits. sysctl and systemctl are stubs; the stub kernel keeps
# its settings in $TMP/kernel and applies /etc/sysctl.d under CDN_DEPLOY_SYSROOT.

setup() {
  # bats 1.2 on Ubuntu 22.04 has no BATS_TEST_TMPDIR.
  TMP="$(mktemp -d)"
  REPO="$TMP/repo"
  ROOT="$TMP/root"
  mkdir -p "$REPO" "$TMP/bin" "$TMP/kernel" "$ROOT/etc/sysctl.d"
  cp -R "$BATS_TEST_DIRNAME/../lib" "$BATS_TEST_DIRNAME/../templates" \
    "$BATS_TEST_DIRNAME/../.env.example" "$REPO/"
  export CDN_DEPLOY_SYSROOT="$ROOT" STUB_DIR="$TMP"
  stubs
  PATH="$TMP/bin:$PATH"
  # shellcheck source=../lib/sysctl.sh
  source "$REPO/lib/sysctl.sh"
  # Stock Ubuntu values, as the kernel prints them.
  kernel net.core.somaxconn 4096
  kernel net.core.netdev_max_backlog 1000
  kernel net.ipv4.tcp_max_syn_backlog 512
  kernel net.ipv4.ip_local_port_range "$(printf '32768\t60999')"
  kernel net.ipv4.tcp_tw_reuse 2
  kernel net.ipv4.tcp_fin_timeout 60
  kernel net.core.default_qdisc fq_codel
  kernel net.ipv4.tcp_congestion_control cubic
  kernel net.ipv4.ip_local_reserved_ports ""
  XHTTP_PORT=4443
  NGINX_TLS_PORT=8444
  CONF="$ROOT/etc/sysctl.d/99-cdn.conf"
}

teardown() {
  rm -rf "${TMP:?}"
}

kernel() {
  printf '%s\n' "$2" >"$TMP/kernel/$1"
}

# stub NAME: installs stdin as the script $TMP/bin/NAME.
stub() {
  {
    echo '#!/bin/sh'
    cat
  } >"$TMP/bin/$1"
  chmod +x "$TMP/bin/$1"
}

# Every stub appends its call to $STUB_DIR/calls. Keys listed in $STUB_DIR/readonly behave
# like a container kernel that refuses them.
stubs() {
  stub sysctl <<'EOF'
echo "sysctl $*" >>"$STUB_DIR/calls"
if [ "$1" = -n ]; then
  [ -f "$STUB_DIR/kernel/$2" ] || { echo "sysctl: cannot stat /proc/sys/$2" >&2; exit 255; }
  cat "$STUB_DIR/kernel/$2"
  exit 0
fi
rc=0
for f in "$CDN_DEPLOY_SYSROOT"/etc/sysctl.d/*.conf; do
  sed -E '/^[[:space:]]*(#|$)/d; s/[[:space:]]*=[[:space:]]*/=/' "$f" | while IFS='=' read -r key value; do
    if grep -qx "$key" "$STUB_DIR/readonly" 2>/dev/null; then
      echo "sysctl: setting key \"$key\", ignoring: Read-only file system" >&2
      continue
    fi
    [ "$key" = net.ipv4.ip_local_port_range ] && value="$(echo "$value" | tr ' ' '\t')"
    printf '%s\n' "$value" >"$STUB_DIR/kernel/$key"
  done
done
exit "$rc"
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

@test "the template goes to /etc/sysctl.d/99-cdn.conf with the frozen values of tech.md §6" {
  local line
  run sysctl::apply
  [ "$status" -eq 0 ]
  cmp "$CONF" "$REPO/templates/sysctl-99-cdn.conf"
  for line in 'net.core.somaxconn = 8192' 'net.core.netdev_max_backlog = 16384' \
    'net.ipv4.tcp_max_syn_backlog = 8192' 'net.ipv4.ip_local_port_range = 1024 65535' \
    'net.ipv4.tcp_tw_reuse = 1' 'net.ipv4.tcp_fin_timeout = 15' 'net.core.default_qdisc = fq' \
    'net.ipv4.tcp_congestion_control = bbr'; do
    grep -qxF "$line" "$CONF" || {
      echo "missing: $line"
      return 1
    }
  done
}

@test "apply runs sysctl --system and the kernel ends up with every value" {
  run sysctl::apply
  [ "$status" -eq 0 ]
  [ "$(calls '^sysctl --system')" -eq 1 ]
  [ "$(cat "$TMP/kernel/net.core.somaxconn")" = 8192 ]
  [ "$(cat "$TMP/kernel/net.ipv4.tcp_congestion_control")" = bbr ]
  [ "$(cat "$TMP/kernel/net.ipv4.ip_local_port_range")" = "$(printf '1024\t65535')" ]
  [[ "$output" != *WARN* ]]
}

@test "XHTTP_PORT and NGINX_TLS_PORT are kept out of the ephemeral range" {
  run sysctl::apply
  [ "$status" -eq 0 ]
  grep -qxF 'net.ipv4.ip_local_reserved_ports = 4443,8444' "$ROOT/etc/sysctl.d/99-cdn-reserved-ports.conf"
  [ "$(cat "$TMP/kernel/net.ipv4.ip_local_reserved_ports")" = 4443,8444 ]
}

@test "a rerun with the settings in effect changes nothing" {
  local before
  run sysctl::apply
  [ "$status" -eq 0 ]
  before="$(find "$ROOT" -type f -exec cksum {} + | sort)"
  : >"$TMP/calls"
  run sysctl::apply
  [ "$status" -eq 0 ]
  [ "$(find "$ROOT" -type f -exec cksum {} + | sort)" = "$before" ]
  [[ "$output" == *"kernel settings are in effect"* ]]
  [ "$(calls '^sysctl --system')" -eq 0 ]
  [ "$(calls '^systemctl daemon-reload')" -eq 0 ]
  [ "$(calls '^systemctl restart')" -eq 0 ]
}

@test "a setting that drifted in the kernel is applied again" {
  run sysctl::apply
  [ "$status" -eq 0 ]
  kernel net.core.somaxconn 4096
  : >"$TMP/calls"
  run sysctl::apply
  [ "$status" -eq 0 ]
  [ "$(calls '^sysctl --system')" -eq 1 ]
  [ "$(cat "$TMP/kernel/net.core.somaxconn")" = 8192 ]
}

@test "reserved ports printed as a range or next to others are not drift" {
  XHTTP_PORT=4443
  NGINX_TLS_PORT=4444
  run sysctl::apply
  [ "$status" -eq 0 ]
  kernel net.ipv4.ip_local_reserved_ports 2222,4443-4444
  : >"$TMP/calls"
  run sysctl::apply
  [ "$status" -eq 0 ]
  [ "$(calls '^sysctl --system')" -eq 0 ]
}

@test "a setting the kernel refuses is reported with a hint, not fatal" {
  echo net.ipv4.tcp_congestion_control >"$TMP/readonly"
  run sysctl::apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"net.ipv4.tcp_congestion_control is cubic, not bbr: the kernel has no tcp_bbr module"* ]]
  [ "$(cat "$TMP/kernel/net.core.somaxconn")" = 8192 ]
}

@test "a missing key is reported as missing" {
  rm "$TMP/kernel/net.core.netdev_max_backlog"
  echo net.core.netdev_max_backlog >"$TMP/readonly"
  run sysctl::apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"net.core.netdev_max_backlog is <missing>, not 16384"* ]]
}

@test "nginx gets a LimitNOFILE drop-in, a daemon-reload and a restart" {
  local dropin="$ROOT/etc/systemd/system/nginx.service.d/cdn-deploy-nofile.conf"
  run sysctl::apply
  [ "$status" -eq 0 ]
  grep -qxF '[Service]' "$dropin"
  grep -qxF 'LimitNOFILE=65535' "$dropin"
  [ "$(calls '^systemctl daemon-reload')" -eq 1 ]
  [ "$(calls '^systemctl restart nginx')" -eq 1 ]
}

@test "a stopped nginx stays stopped" {
  touch "$TMP/nginx-down"
  run sysctl::apply
  [ "$status" -eq 0 ]
  [ "$(calls '^systemctl restart')" -eq 0 ]
}

@test "login sessions get the nofile limit, root included" {
  local limits="$ROOT/etc/security/limits.d/99-cdn-nofile.conf" line
  run sysctl::apply
  [ "$status" -eq 0 ]
  for line in '*    soft nofile 65535' '*    hard nofile 65535' 'root soft nofile 65535' \
    'root hard nofile 65535'; do
    grep -qxF "$line" "$limits" || {
      echo "missing: $line"
      return 1
    }
  done
}
