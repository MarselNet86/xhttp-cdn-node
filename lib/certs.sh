# shellcheck shell=bash
# Let's Encrypt certificates of the origin (tech.md §5): issues them per CERT_MODE, skips
# the ones valid for more than 30 days, installs the renewal hooks.

set -euo pipefail

# deploy.sh may source this module more than once; readonly constants must not be redefined.
if [[ -n "${_CDN_CERTS_LOADED:-}" ]]; then
  return 0
fi
_CDN_CERTS_LOADED=1

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=nginx.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/nginx.sh"

# Paths as the host sees them; files are created under $SYSROOT, which only tests set.
readonly CERTS_LE_DIR=/etc/letsencrypt
readonly CERTS_CF_INI=/etc/letsencrypt/cdn-deploy/cloudflare.ini
readonly CERTS_HOOKS=/etc/letsencrypt/renewal-hooks
readonly CERTS_WEBROOT=/var/www/cdn-deploy-acme
readonly CERTS_ACME_SITE=/etc/nginx/sites-available/cdn-deploy-acme.conf
readonly CERTS_ACME_LINK=/etc/nginx/sites-enabled/cdn-deploy-acme.conf
readonly CERTS_PROBE=/.well-known/acme-challenge/cdn-deploy-probe
# certbot renews 30 days before expiry, so anything closer is due now.
readonly CERTS_MIN_DAYS=30

# Issues the certificates that are missing, expiring, or renewed by another method than
# CERT_MODE. Tries every domain before it fails with exit 6.
certs::issue() {
  local domain hy2_issued=0 due=() failed=()
  require::cmd certbot openssl
  env::require VLESS_DOMAIN HY2_DOMAIN CDN_DOMAIN CERT_MODE NODE_RELOAD_CMD
  case "$CERT_MODE" in
    dns-cloudflare)
      env::require CF_API_TOKEN
      certs::_write_cf_credentials
      certs::_remove_acme_site
      ;;
    http-01)
      require::cmd nginx envsubst curl
      certs::_render_acme_site
      ;;
    *) log::die "$EXIT_INPUT" "CERT_MODE=$CERT_MODE: expected dns-cloudflare or http-01, rerun ./deploy.sh" ;;
  esac
  while IFS= read -r domain; do
    if certs::_is_current "$domain"; then
      log::info "certificate for $domain is valid for more than $CERTS_MIN_DAYS days, kept"
    else
      due+=("$domain")
    fi
  done < <(certs::_domains)
  if ((${#due[@]} == 0)); then
    return 0
  fi
  if [[ "$CERT_MODE" == http-01 ]]; then
    certs::_acme_on
  fi
  for domain in "${due[@]}"; do
    if certs::_certbot "$domain"; then
      if [[ "$domain" == "$HY2_DOMAIN" ]]; then
        hy2_issued=1
      fi
    else
      failed+=("$domain")
    fi
  done
  if [[ "$CERT_MODE" == http-01 ]]; then
    certs::_acme_off
  fi
  if ((hy2_issued)); then
    certs::_restart_node
  fi
  if ((${#failed[@]} > 0)); then
    log::die "$EXIT_CERTS" "no certificate for: ${failed[*]}. $(certs::_hint) Details: /var/log/letsencrypt/letsencrypt.log"
  fi
}

# Writes the certbot deploy hook, plus the :80 pre/post hooks under http-01, and makes
# sure certbot.timer runs the renewals (tech.md §8).
certs::install_renew_hook() {
  local pre="$SYSROOT$CERTS_HOOKS/pre/cdn-deploy-acme.sh" post="$SYSROOT$CERTS_HOOKS/post/cdn-deploy-acme.sh"
  env::require VLESS_DOMAIN HY2_DOMAIN NODE_RELOAD_CMD CERT_MODE
  mkdir -p "$SYSROOT$CERTS_HOOKS/deploy" "$SYSROOT$CERTS_HOOKS/pre" "$SYSROOT$CERTS_HOOKS/post"
  fs::write "$SYSROOT$CERTS_HOOKS/deploy/cdn-deploy.sh" 755 "$(certs::_deploy_hook)"
  if [[ "$CERT_MODE" == http-01 ]]; then
    fs::write "$pre" 755 "$(certs::_pre_hook)"
    fs::write "$post" 755 "$(certs::_post_hook)"
  else
    certs::_remove "$pre" "$post"
  fi
  if ! systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
    systemctl enable --now certbot.timer >&2 ||
      log::warn "cannot enable certbot.timer: certificates will not renew until it runs"
  fi
}

# --- issuance ---------------------------------------------------------------------------

# VLESS and Hysteria2 always get a certificate, CDN_DOMAIN only per env::cdn_has_cert.
certs::_domains() {
  printf '%s\n' "$VLESS_DOMAIN"
  if [[ "$HY2_DOMAIN" != "$VLESS_DOMAIN" ]]; then
    printf '%s\n' "$HY2_DOMAIN"
  fi
  if env::cdn_has_cert; then
    printf '%s\n' "$CDN_DOMAIN"
  fi
}

# 0 when DOMAIN has a certificate that names it, stays valid for more than
# CERTS_MIN_DAYS, and renews by the method CERT_MODE asks for.
certs::_is_current() {
  local domain="$1" san method
  local cert="$SYSROOT$CERTS_LE_DIR/live/$domain/fullchain.pem"
  local conf="$SYSROOT$CERTS_LE_DIR/renewal/$domain.conf"
  [[ -r "$cert" && -r "$conf" ]] || return 1
  openssl x509 -checkend $((CERTS_MIN_DAYS * 86400)) -noout -in "$cert" >/dev/null 2>&1 || return 1
  san="$(openssl x509 -noout -ext subjectAltName -in "$cert" 2>/dev/null)" || return 1
  [[ "$san" =~ DNS:"$domain"(,|$) ]] || return 1
  method="$(sed -nE 's/^authenticator[[:space:]]*=[[:space:]]*//p' "$conf")"
  [[ "$method" == "$(certs::_authenticator)" ]]
}

certs::_authenticator() {
  if [[ "$CERT_MODE" == dns-cloudflare ]]; then
    echo dns-cloudflare
  else
    echo webroot
  fi
}

# One lineage per domain keeps the paths at /etc/letsencrypt/live/<DOMAIN>/ (tech.md §8).
# --force-renewal because this runs only for a certificate that has to change now.
certs::_certbot() {
  local domain="$1" args
  args=(certonly --non-interactive --agree-tos --force-renewal --cert-name "$domain" -d "$domain")
  if [[ "$CERT_MODE" == dns-cloudflare ]]; then
    # certbot's default of 10 s races the Cloudflare API on busy days.
    args+=(--dns-cloudflare --dns-cloudflare-credentials "$CERTS_CF_INI"
      --dns-cloudflare-propagation-seconds 30)
  else
    args+=(--webroot -w "$CERTS_WEBROOT")
  fi
  if [[ -n "${LE_EMAIL:-}" ]]; then
    args+=(--email "$LE_EMAIL" --no-eff-email)
  else
    args+=(--register-unsafely-without-email)
  fi
  log::info "issuing a certificate for $domain via $CERT_MODE"
  certbot "${args[@]}" >&2
}

certs::_hint() {
  if [[ "$CERT_MODE" == dns-cloudflare ]]; then
    echo "Check that CF_API_TOKEN has Zone:DNS:Edit on the zone of each domain."
  else
    echo "Check that each domain has an A record to ORIGIN_IP and that port 80 is open."
  fi
}

certs::_write_cf_credentials() {
  local dir="$SYSROOT${CERTS_CF_INI%/*}"
  mkdir -p "$dir"
  chmod 700 "$dir"
  fs::write "$SYSROOT$CERTS_CF_INI" 600 \
    "# cdn-deploy: Cloudflare API token for certbot DNS-01, taken from .env
dns_cloudflare_api_token = $CF_API_TOKEN"
}

# The Hysteria2 inbound loads its certificate when the node starts.
certs::_restart_node() {
  log::info "restarting the node for the new Hysteria2 certificate: $NODE_RELOAD_CMD"
  if ! sh -c "$NODE_RELOAD_CMD" >&2; then
    log::warn "node restart failed: run '$NODE_RELOAD_CMD' once the node is up"
  fi
}

# --- http-01 challenge server -----------------------------------------------------------

certs::_render_acme_site() {
  local domains
  domains="$(certs::_domains | tr '\n' ' ')"
  mkdir -p "$SYSROOT$CERTS_WEBROOT" "$SYSROOT${CERTS_ACME_SITE%/*}"
  # shellcheck disable=SC2016  # envsubst takes the list of variables to replace literally
  fs::write "$SYSROOT$CERTS_ACME_SITE" 644 "$(ACME_DOMAINS="${domains% }" \
    ACME_WEBROOT="$CERTS_WEBROOT" envsubst '${ACME_DOMAINS} ${ACME_WEBROOT}' \
    <"$REPO_ROOT/templates/acme-http.conf.tmpl")"
}

# Opens :80 for the challenges. A config that nginx rejects is taken out before any
# reload, so the running nginx keeps serving (tech.md §7).
certs::_acme_on() {
  mkdir -p "$SYSROOT${CERTS_ACME_LINK%/*}"
  ln -sfn "$CERTS_ACME_SITE" "$SYSROOT$CERTS_ACME_LINK"
  if ! nginx -t >&2; then
    rm -f "$SYSROOT$CERTS_ACME_LINK"
    log::die "$EXIT_CERTS" "nginx rejects the config with the ACME server: see nginx -t above"
  fi
  if ! nginx::reload; then
    rm -f "$SYSROOT$CERTS_ACME_LINK"
    log::die "$EXIT_CERTS" "nginx did not take the ACME server; :80 stays closed"
  fi
  if ! certs::_wait_for_acme; then
    certs::_acme_off
    log::die "$EXIT_CERTS" "the ACME server does not answer on 127.0.0.1:80: check that nothing else holds port 80"
  fi
}

# nginx -s reload returns before the new config takes requests, and old workers accept
# connections with the old config for a moment longer, while the CA checks a challenge
# within milliseconds. One good answer proves little: waits for ten probes in a row,
# each on a new connection, for up to 10 s.
certs::_wait_for_acme() {
  local token="probe-$$-$RANDOM" file="$SYSROOT$CERTS_WEBROOT$CERTS_PROBE" tries streak=0
  mkdir -p "${file%/*}"
  printf '%s' "$token" >"$file"
  for ((tries = 0; tries < 100 && streak < 10; tries++)); do
    if [[ "$(curl -s --max-time 2 -H "Host: $VLESS_DOMAIN" "http://127.0.0.1$CERTS_PROBE" || true)" == "$token" ]]; then
      streak=$((streak + 1))
    else
      streak=0
    fi
    sleep 0.1
  done
  rm -f "$file"
  ((streak >= 10))
}

certs::_acme_off() {
  rm -f "$SYSROOT$CERTS_ACME_LINK"
  nginx::reload || log::die "$EXIT_CERTS" "nginx still serves the ACME server on :80: fix nginx and reload it"
}

certs::_remove_acme_site() {
  local was_enabled=0
  if [[ -L "$SYSROOT$CERTS_ACME_LINK" ]]; then
    was_enabled=1
  fi
  certs::_remove "$SYSROOT$CERTS_ACME_LINK" "$SYSROOT$CERTS_ACME_SITE"
  if ((was_enabled)); then
    nginx::reload || log::die "$EXIT_CERTS" "nginx still serves the ACME server on :80: fix nginx and reload it"
  fi
}

# --- renewal hooks ----------------------------------------------------------------------

# certbot sets RENEWED_DOMAINS for deploy hooks. Only the Hysteria2 certificate lives in
# the node, so other renewals skip the restart and keep client sessions alive.
certs::_deploy_hook() {
  cat <<EOF
#!/bin/sh
# cdn-deploy deploy hook (tech.md §5): certbot runs it after each renewed certificate.
# Written by ./deploy.sh from .env: rerun it after changing HY2_DOMAIN or NODE_RELOAD_CMD.
node_reload=$(certs::_sh_quote "$NODE_RELOAD_CMD")
$(certs::_sh_reload)
rc=0
reload || rc=1
case " \${RENEWED_DOMAINS:-} " in
*" $HY2_DOMAIN "*) sh -c "\$node_reload" || rc=1 ;;
esac
exit "\$rc"
EOF
}

# Same steps as certs::_acme_on, including the wait for the reload to take effect.
certs::_pre_hook() {
  cat <<EOF
#!/bin/sh
# cdn-deploy, CERT_MODE=http-01: opens :80 for the challenges before certbot renews.
$(certs::_sh_reload)
close() {
  rm -f $CERTS_ACME_LINK
  reload
  exit 1
}
ln -sfn $CERTS_ACME_SITE $CERTS_ACME_LINK
if ! nginx -t -q; then
  rm -f $CERTS_ACME_LINK
  exit 1
fi
reload || close
# Old workers keep the old config for a moment after the reload: wait for ten probes in
# a row, each on a new connection, for up to 10 s.
probe=$CERTS_WEBROOT$CERTS_PROBE
token="probe-\$\$"
mkdir -p "\${probe%/*}"
printf '%s' "\$token" >"\$probe"
tries=0
streak=0
while [ "\$streak" -lt 10 ]; do
  if [ "\$(curl -s --max-time 2 -H 'Host: $VLESS_DOMAIN' http://127.0.0.1$CERTS_PROBE)" = "\$token" ]; then
    streak=\$((streak + 1))
  else
    streak=0
  fi
  tries=\$((tries + 1))
  if [ "\$tries" -ge 100 ]; then
    rm -f "\$probe"
    close
  fi
  sleep 0.1
done
rm -f "\$probe"
EOF
}

certs::_post_hook() {
  cat <<EOF
#!/bin/sh
# cdn-deploy, CERT_MODE=http-01: closes :80 again after certbot renews.
$(certs::_sh_reload)
rm -f $CERTS_ACME_LINK
reload
EOF
}

# A reload() for the hook scripts. certbot logs any stderr of a hook as error output, and
# nginx -s reload prints a notice even on success, so the output shows only on failure.
certs::_sh_reload() {
  cat <<'EOF'
reload() {
  out=$(nginx -s reload 2>&1) || {
    printf '%s\n' "$out" >&2
    return 1
  }
}
EOF
}

# Single-quotes a string for sh: each ' becomes '\''.
certs::_sh_quote() {
  local s="$1" q="'\\''"
  printf "'%s'" "${s//\'/$q}"
}

certs::_remove() {
  local path
  for path in "$@"; do
    if [[ -e "$path" || -L "$path" ]]; then
      rm -f "$path"
      log::info "removed $path: CERT_MODE=$CERT_MODE does not use it"
    fi
  done
}
