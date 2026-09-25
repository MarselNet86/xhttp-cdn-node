#!/usr/bin/env bash
# Entry point: sets up the origin side of CDN fronting on a Remnawave node.
# Thin orchestrator (tech.md §3): guards, step order and --dry-run. Domain logic lives in lib/.
set -Eeuo pipefail

# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/prompt.sh
source "$REPO_ROOT/lib/prompt.sh"
# shellcheck source=lib/certs.sh
source "$REPO_ROOT/lib/certs.sh"
# shellcheck source=lib/nginx.sh
source "$REPO_ROOT/lib/nginx.sh"
# shellcheck source=lib/sysctl.sh
source "$REPO_ROOT/lib/sysctl.sh"
# shellcheck source=lib/remnawave.sh
source "$REPO_ROOT/lib/remnawave.sh"
# shellcheck source=lib/validate.sh
source "$REPO_ROOT/lib/validate.sh"

# set -e alone exits without a word; name the command that failed.
trap 'log::error "unexpected failure (exit $?) at ${BASH_SOURCE[0]##*/}:$LINENO: $BASH_COMMAND"' ERR

# System packages the stack runs on (tech.md §2). procps brings sysctl: minimal Debian
# images lack it.
readonly -a PACKAGES=(nginx certbot python3-certbot-dns-cloudflare curl jq openssl coreutils
  gettext-base procps)

# Steps in execution order: "<id> <function> [<module function it needs>]".
# A step whose function does not exist yet is marked in the plan and stops a real run.
# Certificates come before nginx, whose site loads them; sysctl comes before nginx too,
# because somaxconn caps the listen backlog at the moment nginx opens its port.
readonly -a STEPS=(
  "preflight deploy::preflight"
  "input prompt::collect"
  "config deploy::load_config"
  "packages deploy::packages pkg::install"
  "certs certs::issue"
  "renew-hook certs::install_renew_hook"
  "sysctl sysctl::apply"
  "nginx nginx::render"
  "remnawave remnawave::emit"
  "validate validate::layers"
)

deploy::usage() {
  cat <<'EOF'
Usage: ./deploy.sh [--dry-run]

Sets up the origin side of CDN fronting on a Remnawave node: nginx on the CDN-facing
port in front of the local xray xhttp inbound, Let's Encrypt certificates with renewal,
kernel network tuning. Asks for the settings and keeps them in .env.

Options:
  --dry-run   print the settings and the planned steps, change nothing
  -h, --help  show this help
EOF
}

# --- steps ------------------------------------------------------------------------------

deploy::preflight() {
  require::root
  require::distro /etc/os-release
  log::info "OS: $OS_ID $OS_VERSION_ID"
  if [[ -n "$SYSROOT" ]]; then
    log::warn "CDN_DEPLOY_SYSROOT=$SYSROOT: system files go under it, meant for tests only"
  fi
}

# .env.example supplies defaults for keys that a hand-edited .env lacks.
deploy::load_config() {
  env::load "$ENV_EXAMPLE"
  env::load "$ENV_FILE"
  env::require CDN_DOMAIN ORIGIN_IP
  if [[ "${CERT_MODE:-}" == dns-cloudflare ]]; then
    env::require CF_API_TOKEN
  fi
  env::require_origin_cert
}

deploy::packages() { pkg::install "${PACKAGES[@]}"; }

deploy::run() {
  local entry id fn needs n=0
  for entry in "${STEPS[@]}"; do
    read -r id fn needs <<<"$entry"
    n=$((n + 1))
    declare -F "${needs:-$fn}" >/dev/null ||
      log::die "$EXIT_FAILURE" "step $id: ${needs:-$fn} is not implemented yet"
    log::info "step $n/${#STEPS[@]}: $id"
    "$fn"
  done
  log::info "deploy finished"
}

# --- dry run ----------------------------------------------------------------------------

deploy::dry_run() {
  deploy::advise require::root
  deploy::advise require::distro /etc/os-release
  deploy::plan
}

# Reports a failing guard as a warning, so the plan prints on any machine.
deploy::advise() {
  local err
  if ! err="$("$@" 2>&1)"; then
    log::warn "dry run goes on, a real run stops here: ${err#\[ERROR\] }"
  fi
}

# Prints the plan to stdout: settings, then steps with their targets.
deploy::plan() {
  local settings_from="$ENV_FILE" key entry id fn needs n=0 mark
  env::load "$ENV_EXAMPLE"
  if [[ -f "$ENV_FILE" ]]; then
    env::load "$ENV_FILE"
  else
    settings_from="no .env yet: .env.example defaults, step 2 asks for every value"
  fi
  deploy::advise env::require_origin_cert
  printf 'cdn-deploy dry run: nothing is changed.\n\nSettings (%s):\n' "$settings_from"
  for key in "${ENV_KEYS[@]}"; do
    printf '  %-22s %s\n' "$key" "$(deploy::show "$key" '<unset>')"
  done
  printf '\nSteps:\n'
  for entry in "${STEPS[@]}"; do
    read -r id fn needs <<<"$entry"
    n=$((n + 1))
    mark=""
    declare -F "${needs:-$fn}" >/dev/null || mark=" [not implemented yet]"
    printf '  %2d. %-10s %s%s\n' "$n" "$id" "$(deploy::describe "$id")" "$mark"
  done
}

deploy::describe() {
  local tls_port xhttp_port cdn
  tls_port="$(deploy::show NGINX_TLS_PORT)"
  xhttp_port="$(deploy::show XHTTP_PORT)"
  cdn="$(deploy::show CDN_DOMAIN)"
  case "$1" in
    preflight) printf 'check root, bash 4+, OS: Ubuntu 22.04/24.04 or Debian 12' ;;
    input) printf 'ask for settings (defaults from an existing .env), write .env (mode 600)' ;;
    config) printf 'load .env over the .env.example defaults, check required settings' ;;
    packages) printf 'install missing: %s' "${PACKAGES[*]}" ;;
    sysctl)
      printf '/etc/sysctl.d/99-cdn.conf, reserve ports %s,%s, apply and check; nofile 65535 for nginx and logins' \
        "$xhttp_port" "$tls_port"
      ;;
    certs)
      printf "Let's Encrypt via %s: %s; skip certificates valid 30+ days" \
        "$(deploy::show CERT_MODE)" "$(deploy::cert_domains)"
      ;;
    renew-hook)
      printf 'certbot deploy hook: nginx reload%s%s; certbot.timer on' \
        "$(deploy::node_reload_plan)" \
        "$([[ "${CERT_MODE:-}" == http-01 ]] && printf '; pre/post hooks open :80 for HTTP-01')"
      ;;
    nginx)
      printf 'templates/ into /etc/nginx/: :%s %s (certificate of %s) -> 127.0.0.1:%s; drop %s; nginx -t; reload' \
        "$tls_port" "$cdn" "$(deploy::origin_cert_domain)" "$xhttp_port" "sites-enabled/default"
      ;;
    remnawave)
      printf 'render out/remnawave/: config profile, host extra, Xray JSON template, xhttp inbound; walk through the panel and the CDN resource'
      ;;
    validate)
      printf 'layers: xray 127.0.0.1:%s; origin :%s /cdn-check 204; %stest 400 with padding; CDN %s /cdn-check 204' \
        "$xhttp_port" "$tls_port" "$(deploy::show XHTTP_PATH)" "$cdn"
      ;;
  esac
}

# Empty VLESS_DOMAIN and HY2_DOMAIN mean a server that already runs them: no certificate.
deploy::cert_domains() {
  local domains=()
  if [[ -n "${VLESS_DOMAIN:-}" ]]; then
    domains+=("$VLESS_DOMAIN")
  fi
  if [[ -n "${HY2_DOMAIN:-}" && "$HY2_DOMAIN" != "${VLESS_DOMAIN:-}" ]]; then
    domains+=("$HY2_DOMAIN")
  fi
  if env::cdn_has_cert; then
    domains+=("$(deploy::show CDN_DOMAIN)")
  fi
  if ((${#domains[@]} == 0)); then
    domains=("<VLESS_DOMAIN>")
  fi
  printf '%s' "${domains[*]}"
  if ! env::cdn_has_cert; then
    printf ' (origin :%s serves the VLESS_DOMAIN certificate)' "$(deploy::show NGINX_TLS_PORT)"
  fi
}

deploy::origin_cert_domain() {
  local domain
  if domain="$(env::origin_cert_domain)" && [[ -n "$domain" ]]; then
    printf '%s' "$domain"
  elif env::cdn_has_cert; then
    printf '<CDN_DOMAIN>'
  else
    printf '<VLESS_DOMAIN>'
  fi
}

deploy::node_reload_plan() {
  if [[ -n "${HY2_DOMAIN:-}" ]]; then
    printf ', "%s" when %s renews' "$(deploy::show NODE_RELOAD_CMD)" "$HY2_DOMAIN"
  else
    printf ', no node restart: HY2_DOMAIN is not set'
  fi
}

# A setting as the plan shows it: the value, <hidden> for secrets, and <KEY> (or the
# given placeholder) while unset.
deploy::show() {
  local key="$1"
  if [[ -z "${!key:-}" ]]; then
    printf '%s' "${2:-<$key>}"
  elif env::is_secret "$key"; then
    printf '<hidden>'
  else
    printf '%s' "${!key}"
  fi
}

# --- main -------------------------------------------------------------------------------

deploy::main() {
  local arg dry_run=0
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=1 ;;
      -h | --help)
        deploy::usage
        return 0
        ;;
      *) log::die "$EXIT_INPUT" "unknown option: $arg. See ./deploy.sh --help" ;;
    esac
  done
  if ((dry_run)); then
    deploy::dry_run
  else
    deploy::run
  fi
}

deploy::main "$@"
