#!/usr/bin/env bash
# Entry point: sets up the origin side of CDN fronting on a Remnawave node.
# Thin orchestrator (tech.md §3): guards, step order and --dry-run. Domain logic lives in lib/.
set -Eeuo pipefail

# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/prompt.sh
source "$REPO_ROOT/lib/prompt.sh"

# set -e alone exits without a word; name the command that failed.
trap 'log::error "unexpected failure (exit $?) at ${BASH_SOURCE[0]##*/}:$LINENO: $BASH_COMMAND"' ERR

# System packages the stack runs on (tech.md §2).
readonly -a PACKAGES=(nginx certbot python3-certbot-dns-cloudflare curl jq openssl coreutils
  gettext-base)

# Steps in execution order: "<id> <function> [<module function it needs>]".
# A step whose function does not exist yet is marked in the plan and stops a real run.
readonly -a STEPS=(
  "preflight deploy::preflight"
  "input prompt::collect"
  "config deploy::load_config"
  "packages deploy::packages pkg::install"
  "sysctl sysctl::apply"
  "certs certs::issue"
  "renew-hook certs::install_renew_hook"
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
}

# .env.example supplies defaults for keys that a hand-edited .env lacks.
deploy::load_config() {
  env::load "$ENV_EXAMPLE"
  env::load "$ENV_FILE"
  env::require VLESS_DOMAIN HY2_DOMAIN CDN_DOMAIN ORIGIN_IP
  if [[ "${CERT_MODE:-}" == dns-cloudflare ]]; then
    env::require CF_API_TOKEN
  fi
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
    sysctl) printf 'network tuning into /etc/sysctl.d/, sysctl --system, nofile limits' ;;
    certs)
      printf "Let's Encrypt via %s: %s; skip certificates valid 30+ days" \
        "$(deploy::show CERT_MODE)" "$(deploy::cert_domains)"
      ;;
    renew-hook)
      printf 'write /etc/letsencrypt/renewal-hooks/deploy/cdn-deploy.sh: nginx reload, "%s"' \
        "$(deploy::show NODE_RELOAD_CMD)"
      ;;
    nginx)
      printf 'templates/ into /etc/nginx/: :%s %s -> 127.0.0.1:%s; drop %s; nginx -t; reload' \
        "$tls_port" "$cdn" "$xhttp_port" "sites-enabled/default"
      ;;
    remnawave) printf 'render out/remnawave/ (xhttp inbound, host extra) to paste into the panel' ;;
    validate)
      printf 'xray 127.0.0.1:%s; origin :%s /cdn-check and %s; CDN %s /cdn-check' \
        "$xhttp_port" "$tls_port" "$(deploy::show XHTTP_PATH)" "$cdn"
      ;;
  esac
}

# http-01 cannot validate CDN_DOMAIN (a CNAME to the CDN), so that mode forces
# ISSUE_CDN_ORIGIN_CERT=false and origin nginx reuses the VLESS certificate (tech.md §4).
deploy::cert_domains() {
  printf '%s %s' "$(deploy::show VLESS_DOMAIN)" "$(deploy::show HY2_DOMAIN)"
  if [[ "${CERT_MODE:-}" != http-01 && "${ISSUE_CDN_ORIGIN_CERT:-}" == true ]]; then
    printf ' %s' "$(deploy::show CDN_DOMAIN)"
  else
    printf ' (origin :%s reuses the VLESS_DOMAIN certificate)' "$(deploy::show NGINX_TLS_PORT)"
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
