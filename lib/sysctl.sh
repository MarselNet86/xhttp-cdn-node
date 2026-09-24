# shellcheck shell=bash
# Kernel network tuning and open-file limits (tech.md §5, §6): installs
# templates/sysctl-99-cdn.conf into /etc/sysctl.d/, applies it, raises nofile for nginx
# and for login sessions. Checks the values the kernel ends up with.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

# Paths as the host sees them; files are created under $SYSROOT, which only tests set.
readonly SYSCTL_CONF=/etc/sysctl.d/99-cdn.conf
readonly SYSCTL_RESERVED=/etc/sysctl.d/99-cdn-reserved-ports.conf
readonly SYSCTL_NGINX_DROPIN=/etc/systemd/system/nginx.service.d/cdn-deploy-nofile.conf
readonly SYSCTL_LIMITS=/etc/security/limits.d/99-cdn-nofile.conf
# Matches worker_rlimit_nofile in templates/nginx.conf.tmpl.
readonly SYSCTL_NOFILE=65535

sysctl::apply() {
  local changed=0 restart=0 backlog
  require::cmd sysctl systemctl
  env::require XHTTP_PORT NGINX_TLS_PORT
  mkdir -p "$SYSROOT${SYSCTL_CONF%/*}" "$SYSROOT${SYSCTL_NGINX_DROPIN%/*}" "$SYSROOT${SYSCTL_LIMITS%/*}"
  fs::write "$SYSROOT$SYSCTL_CONF" 644 "$(<"$REPO_ROOT/templates/sysctl-99-cdn.conf")"
  changed=$((changed | FS_CHANGED))
  fs::write "$SYSROOT$SYSCTL_RESERVED" 644 "$(sysctl::_reserved_ports)"
  changed=$((changed | FS_CHANGED))

  if ((changed)) || ! sysctl::_in_effect quiet; then
    log::info "applying kernel settings: sysctl --system"
    backlog="$(sysctl -n net.core.somaxconn 2>/dev/null || true)"
    # Another file failing to apply is not ours to fix; the check below covers ours.
    sysctl --system >&2 || log::warn "sysctl --system reported errors, see above"
    # somaxconn caps the backlog when nginx opens a port, so only a changed one needs a
    # restart. A kernel that refuses it would otherwise restart nginx on every run.
    if [[ "$(sysctl -n net.core.somaxconn 2>/dev/null || true)" != "$backlog" ]]; then
      restart=1
    fi
    sysctl::_in_effect warn || true
  else
    log::info "kernel settings are in effect"
  fi

  fs::write "$SYSROOT$SYSCTL_NGINX_DROPIN" 644 "$(sysctl::_nginx_dropin)"
  if ((FS_CHANGED)); then
    systemctl daemon-reload >&2
    restart=1
  fi
  fs::write "$SYSROOT$SYSCTL_LIMITS" 644 "$(sysctl::_limits)"
  if ((restart)) && systemctl is-active --quiet nginx; then
    log::info "restarting nginx for the new backlog and open-file limits"
    systemctl restart nginx >&2 || log::die "$EXIT_FAILURE" "nginx did not restart: see systemctl status nginx"
  fi
}

# ip_local_port_range 1024-65535 covers the ports of xray and nginx: an outgoing connection
# holding one of them would stop the service from binding it after a restart, such as the
# node restart after a certificate renewal.
sysctl::_reserved_ports() {
  cat <<EOF
# cdn-deploy: keeps XHTTP_PORT and NGINX_TLS_PORT out of the ephemeral range (tech.md §6
# sets ip_local_port_range = 1024 65535). Written by ./deploy.sh from .env.
net.ipv4.ip_local_reserved_ports = $(printf '%s\n' "$XHTTP_PORT" "$NGINX_TLS_PORT" | sort -nu | paste -sd,)
EOF
}

sysctl::_nginx_dropin() {
  cat <<EOF
# cdn-deploy: open-file limit of the nginx master; workers get worker_rlimit_nofile.
[Service]
LimitNOFILE=$SYSCTL_NOFILE
EOF
}

# pam_limits leaves root out of "*", so root gets its own lines.
sysctl::_limits() {
  cat <<EOF
# cdn-deploy: open-file limit for login sessions and the programs they start.
*    soft nofile $SYSCTL_NOFILE
*    hard nofile $SYSCTL_NOFILE
root soft nofile $SYSCTL_NOFILE
root hard nofile $SYSCTL_NOFILE
EOF
}

# 0 when every setting of our files is what the kernel reports. With "warn", names each
# setting that differs and why that usually happens.
sysctl::_in_effect() {
  local mode="$1" key want have ok=0
  while IFS='=' read -r key want; do
    key="${key//[[:space:]]/}"
    want="$(sysctl::_norm "$key" "$want")"
    have="$(sysctl::_norm "$key" "$(sysctl -n "$key" 2>/dev/null || echo '<missing>')")"
    if ! sysctl::_holds "$key" "$want" "$have"; then
      ok=1
      if [[ "$mode" == warn ]]; then
        log::warn "$key is ${have:-<empty>}, not $want: $(sysctl::_hint "$key")"
      fi
    fi
  done < <(sed -E '/^[[:space:]]*(#|$)/d' "$SYSROOT$SYSCTL_CONF" "$SYSROOT$SYSCTL_RESERVED")
  return "$ok"
}

# Reserved ports only need ours among them: other software may reserve more.
sysctl::_holds() {
  local key="$1" want="$2" have="$3" port
  if [[ "$key" != net.ipv4.ip_local_reserved_ports ]]; then
    [[ "$have" == "$want" ]]
    return
  fi
  for port in ${want//,/ }; do
    [[ ",$have," == *",$port,"* ]] || return 1
  done
}

# Compares values the way the kernel prints them: tabs for spaces, ranges spelled out.
sysctl::_norm() {
  local key="$1" value
  value="$(printf '%s' "$2" | tr -s '[:space:]' ' ' | sed -E 's/^ //; s/ $//')"
  if [[ "$key" == net.ipv4.ip_local_reserved_ports ]]; then
    value="$(printf '%s' "$value" | tr ',' '\n' |
      awk -F- 'NF == 2 { for (p = $1; p <= $2; p++) print p; next } NF { print }' |
      sort -nu | paste -sd,)"
  fi
  printf '%s' "$value"
}

sysctl::_hint() {
  case "$1" in
    net.ipv4.tcp_congestion_control)
      echo "the kernel has no tcp_bbr module (OpenVZ/LXC containers lack it), see tcp_available_congestion_control"
      ;;
    *) echo "a later file in /etc/sysctl.d or /etc/sysctl.conf overrides it, or a container kernel forbids it" ;;
  esac
}
