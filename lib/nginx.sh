# shellcheck shell=bash
# Origin nginx for the CDN edge (tech.md §5, §6): renders templates/ into /etc/nginx/,
# enables the site, drops the stock default site, applies the result only after nginx -t.

set -euo pipefail

# certs.sh sources this module too; readonly constants must not be redefined.
if [[ -n "${_CDN_NGINX_LOADED:-}" ]]; then
  return 0
fi
_CDN_NGINX_LOADED=1

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

# Paths as the host sees them; files are created under $SYSROOT, which only tests set.
readonly NGINX_CONF=/etc/nginx/nginx.conf
readonly NGINX_STOCK_CONF=/etc/nginx/nginx.conf.cdn-deploy-orig
readonly NGINX_SITE=/etc/nginx/sites-available/cdn-deploy.conf
readonly NGINX_SITE_LINK=/etc/nginx/sites-enabled/cdn-deploy.conf
readonly NGINX_DEFAULT_LINK=/etc/nginx/sites-enabled/default

# Renders both templates and applies them. A config that nginx -t rejects is rolled back
# before any reload, so the running nginx keeps the previous one (exit 7).
nginx::render() {
  local cert_dir main site saved changed=0
  require::cmd nginx envsubst
  env::require VLESS_DOMAIN CDN_DOMAIN XHTTP_PORT XHTTP_PATH NGINX_TLS_PORT CERT_MODE
  cert_dir="$(nginx::_cert_dir)"
  if [[ ! -r "$SYSROOT$cert_dir/fullchain.pem" || ! -r "$SYSROOT$cert_dir/privkey.pem" ]]; then
    log::die "$EXIT_NGINX" "no certificate in $cert_dir: the certs step issues it, rerun ./deploy.sh"
  fi
  main="$(nginx::_template nginx.conf.tmpl "$cert_dir")" || log::die "$EXIT_NGINX" "cannot render templates/nginx.conf.tmpl"
  site="$(nginx::_template site-8444.conf.tmpl "$cert_dir")" || log::die "$EXIT_NGINX" "cannot render templates/site-8444.conf.tmpl"

  mkdir -p "$SYSROOT${NGINX_SITE%/*}" "$SYSROOT${NGINX_SITE_LINK%/*}"
  saved="$(mktemp -d)"
  nginx::_save "$saved"
  nginx::_keep_stock_conf
  fs::write "$SYSROOT$NGINX_CONF" 644 "$main"
  changed=$((changed | FS_CHANGED))
  fs::write "$SYSROOT$NGINX_SITE" 644 "$site"
  changed=$((changed | FS_CHANGED))
  if [[ "$(readlink "$SYSROOT$NGINX_SITE_LINK" || true)" != "$NGINX_SITE" ]]; then
    ln -sfn "$NGINX_SITE" "$SYSROOT$NGINX_SITE_LINK"
    changed=1
  fi
  if [[ -e "$SYSROOT$NGINX_DEFAULT_LINK" || -L "$SYSROOT$NGINX_DEFAULT_LINK" ]]; then
    rm -f "$SYSROOT$NGINX_DEFAULT_LINK"
    log::info "removed $NGINX_DEFAULT_LINK: the stock site answers any host; sites-available/default stays"
    changed=1
  fi

  if ((changed == 0)) && systemctl is-active --quiet nginx; then
    rm -rf "$saved"
    log::info "nginx config is up to date"
    return 0
  fi
  if ! nginx -t >&2; then
    nginx::_restore "$saved"
    rm -rf "$saved"
    log::die "$EXIT_NGINX" "nginx -t rejects the rendered config, the previous one stays: see the errors above"
  fi
  rm -rf "$saved"
  nginx::reload || log::die "$EXIT_NGINX" "nginx did not take the new config"
}

# Reloads nginx, or starts it when it is down. nginx -s reload prints a notice even on
# success, so its output shows only on failure, and the function returns 1.
nginx::reload() {
  local out
  if ! systemctl is-active --quiet nginx; then
    log::info "nginx is not running: starting it"
    if systemctl start nginx >&2; then
      return 0
    fi
    log::error "cannot start nginx: see systemctl status nginx"
    return 1
  fi
  if ! out="$(nginx -s reload 2>&1)"; then
    log::error "nginx -s reload failed: $out"
    return 1
  fi
}

# --- rendering --------------------------------------------------------------------------

nginx::_cert_dir() {
  if env::cdn_has_cert; then
    echo "/etc/letsencrypt/live/$CDN_DOMAIN"
  else
    echo "/etc/letsencrypt/live/$VLESS_DOMAIN"
  fi
}

# Renders templates/NAME with the cert directory CERT_DIR. Only the listed placeholders
# change, so nginx variables such as $request_method stay as they are.
nginx::_template() {
  local name="$1" out
  # shellcheck disable=SC2016  # envsubst takes the placeholder list literally
  out="$(XHTTP_PORT="$XHTTP_PORT" XHTTP_PATH="$XHTTP_PATH" NGINX_TLS_PORT="$NGINX_TLS_PORT" \
    CDN_DOMAIN="$CDN_DOMAIN" VLESS_DOMAIN="$VLESS_DOMAIN" ORIGIN_CERT_DIR="$2" \
    envsubst '${XHTTP_PORT} ${XHTTP_PATH} ${NGINX_TLS_PORT} ${CDN_DOMAIN} ${VLESS_DOMAIN} ${ORIGIN_CERT_DIR}' \
    <"$REPO_ROOT/templates/$name")"
  if [[ "$out" == *"\${"* ]]; then
    log::error "templates/$name has a placeholder that nginx::render does not fill"
    return 1
  fi
  printf '%s' "$out"
}

# --- rollback ---------------------------------------------------------------------------

# Files and links that nginx::render may change, as the host sees them.
nginx::_managed() {
  printf '%s\n' "$NGINX_CONF" "$NGINX_SITE" "$NGINX_SITE_LINK" "$NGINX_DEFAULT_LINK"
}

nginx::_save() {
  local dir="$1" path i=0
  while IFS= read -r path; do
    if [[ -e "$SYSROOT$path" || -L "$SYSROOT$path" ]]; then
      cp -a "$SYSROOT$path" "$dir/$i"
    fi
    i=$((i + 1))
  done < <(nginx::_managed)
}

nginx::_restore() {
  local dir="$1" path i=0
  while IFS= read -r path; do
    rm -f "$SYSROOT$path"
    if [[ -e "$dir/$i" || -L "$dir/$i" ]]; then
      cp -a "$dir/$i" "$SYSROOT$path"
    fi
    i=$((i + 1))
  done < <(nginx::_managed)
  log::warn "restored the previous nginx config"
}

# Keeps the distro's nginx.conf once, before the first overwrite, for a manual revert.
nginx::_keep_stock_conf() {
  if [[ -f "$SYSROOT$NGINX_CONF" && ! -e "$SYSROOT$NGINX_STOCK_CONF" ]]; then
    cp -p "$SYSROOT$NGINX_CONF" "$SYSROOT$NGINX_STOCK_CONF"
    log::info "kept the stock nginx.conf as $NGINX_STOCK_CONF"
  fi
}
