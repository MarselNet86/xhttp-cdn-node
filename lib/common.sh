# shellcheck shell=bash
# Shared base of cdn-deploy: logger, guards, OS detection, validators, .env loading.
# Entry points source it first; it only defines constants and functions.

set -euo pipefail

# Modules may source this file again; readonly constants must not be redefined.
if [[ -n "${_CDN_COMMON_LOADED:-}" ]]; then
  return 0
fi
_CDN_COMMON_LOADED=1

# tech.md targets bash 4+. Fail with a clear message, not on the first bash 4
# construct: macOS still ships bash 3.2 as /bin/bash.
if ((BASH_VERSINFO[0] < 4)); then
  printf '[ERROR] bash 4+ required, found %s: run with a newer bash\n' "$BASH_VERSION" >&2
  exit 3
fi

# Exit codes are part of the contract (tech.md §5): change only with a version bump.
#   1 unexpected failure   2 invalid or missing input   3 missing command
#   4 not root             5 unsupported OS             6 certificate issuance
#   7 nginx -t failed      8 post-install validation
# shellcheck disable=SC2034  # read by the scripts that source this file
readonly EXIT_FAILURE=1 EXIT_INPUT=2 EXIT_DEPS=3 EXIT_ROOT=4 EXIT_DISTRO=5 \
  EXIT_CERTS=6 EXIT_NGINX=7 EXIT_VALIDATE=8

# .env lives in the repository root next to deploy.sh. Modules write system files under
# $SYSROOT: empty in production, a scratch directory when tests set CDN_DEPLOY_SYSROOT.
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck disable=SC2034  # read by the scripts that source this file
readonly REPO_ROOT ENV_FILE="$REPO_ROOT/.env" ENV_EXAMPLE="$REPO_ROOT/.env.example" \
  SYSROOT="${CDN_DEPLOY_SYSROOT:-}"

# --- logger: stderr only, stdout stays free for data meant for the user -------------

log::info() { printf '[INFO] %s\n' "$*" >&2; }
log::warn() { printf '[WARN] %s\n' "$*" >&2; }
log::error() { printf '[ERROR] %s\n' "$*" >&2; }

log::die() {
  local code="$1"
  shift
  log::error "$*"
  exit "$code"
}

# --- guards ---------------------------------------------------------------------------

require::root() {
  ((EUID == 0)) || log::die "$EXIT_ROOT" "root privileges required: rerun with sudo"
}

require::cmd() {
  local name
  for name in "$@"; do
    command -v "$name" >/dev/null 2>&1 ||
      log::die "$EXIT_DEPS" "command not found: $name. Install it and rerun"
  done
}

# Supported targets (tech.md §2): Ubuntu 22.04/24.04, Debian 12; all use apt.
# The optional argument replaces /etc/os-release for tests.
require::distro() {
  local file="${1:-/etc/os-release}" id="" version="" key value
  local need="need Ubuntu 22.04/24.04 or Debian 12"
  [[ -r "$file" ]] || log::die "$EXIT_DISTRO" "cannot read $file: unsupported OS, $need"
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    case "$key" in
      ID) id="$value" ;;
      VERSION_ID) version="$value" ;;
    esac
  done <"$file"
  case "$id $version" in
    "ubuntu 22.04" | "ubuntu 24.04" | "debian 12") ;;
    *) log::die "$EXIT_DISTRO" "unsupported OS: ${id:-unknown} ${version:-unknown}, $need" ;;
  esac
  # The stack needs none of the recommended extras (checked on all three targets);
  # DEBIAN_FRONTEND keeps debconf from blocking on a question.
  # The lock timeout waits out unattended-upgrades, busy on a freshly booted VPS.
  export OS_ID="$id" OS_VERSION_ID="$version"
  export PKG_INSTALL="env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=300"
}

# --- packages ---------------------------------------------------------------------------

# Installs the given apt packages that are missing, so a rerun changes nothing.
# Runs after require::distro, which sets PKG_INSTALL.
pkg::install() {
  local pkg cmd missing=()
  [[ -n "${PKG_INSTALL:-}" ]] || log::die "$EXIT_FAILURE" "pkg::install needs require::distro first"
  for pkg in "$@"; do
    # shellcheck disable=SC2016  # ${Status} is a dpkg-query field, not a shell variable
    if [[ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" != "install ok installed" ]]; then
      missing+=("$pkg")
    fi
  done
  if ((${#missing[@]} == 0)); then
    log::info "packages already installed: $*"
    return 0
  fi
  log::info "installing packages: ${missing[*]}"
  # A fresh cloud image ships a stale or empty package index.
  apt-get -o DPkg::Lock::Timeout=300 update -qq >&2 ||
    log::die "$EXIT_DEPS" "apt-get update failed: check the network and the apt sources"
  read -ra cmd <<<"$PKG_INSTALL"
  "${cmd[@]}" "${missing[@]}" >&2 ||
    log::die "$EXIT_DEPS" "cannot install ${missing[*]}: see the apt output above"
}

# --- files ------------------------------------------------------------------------------

# Writes CONTENT and a final newline to PATH with MODE, atomically. An identical file keeps
# its timestamp and only gets MODE. Sets FS_CHANGED to 1 when the content changed, else 0.
fs::write() {
  local path="$1" mode="$2" content="$3" tmp
  FS_CHANGED=0
  if [[ -f "$path" && "$(<"$path")" == "$content" ]]; then
    chmod "$mode" "$path"
    log::info "$path is up to date"
    return 0
  fi
  tmp="$(mktemp "$path.XXXXXX")" || log::die "$EXIT_FAILURE" "cannot create a file next to $path"
  if ! printf '%s\n' "$content" >"$tmp" || ! chmod "$mode" "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    log::die "$EXIT_FAILURE" "cannot write $path"
  fi
  # shellcheck disable=SC2034  # read by the callers
  FS_CHANGED=1
  log::info "wrote $path (mode $mode)"
}

# --- validators: return 0 or 1 and print nothing ----------------------------------------
# Each checks the shape with a regex before any (( )): arithmetic evaluates a variable's
# contents as code, so unchecked input there is an injection.

# A name usable for a certificate and nginx server_name: two or more labels, an
# alphabetic or punycode TLD, no trailing dot, wildcard or underscore.
is::fqdn() {
  local s="${1-}"
  local label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
  local re='^('"$label"'\.)+([A-Za-z]{2,63}|xn--[A-Za-z0-9-]{1,59})$'
  ((${#s} <= 253)) && [[ "$s" =~ $re ]]
}

# Dotted quad without leading zeros: some parsers read 010 as octal.
is::ipv4() {
  local s="${1-}" octet
  [[ "$s" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for octet in "${BASH_REMATCH[@]:1}"; do
    [[ "$octet" == 0 || "$octet" != 0* ]] || return 1
    ((octet <= 255)) || return 1
  done
}

is::port() {
  local s="${1-}"
  [[ "$s" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  ((s <= 65535))
}

# --- .env -----------------------------------------------------------------------------

# Contract keys (tech.md §4) in prompt order. env::load accepts no others.
readonly -a ENV_KEYS=(
  VLESS_DOMAIN HY2_DOMAIN CDN_DOMAIN ORIGIN_IP XHTTP_PORT XHTTP_PATH NGINX_TLS_PORT
  UUID CERT_MODE CF_API_TOKEN LE_EMAIL NODE_RELOAD_CMD ISSUE_CDN_ORIGIN_CERT
)
# Values that grant access to the DNS zone or the node: never print them.
readonly -a ENV_SECRET_KEYS=(CF_API_TOKEN UUID)

env::is_secret() { env::_contains "$1" "${ENV_SECRET_KEYS[@]}"; }

# CDN_DOMAIN gets its own origin certificate only under dns-cloudflare with
# ISSUE_CDN_ORIGIN_CERT=true: http-01 cannot validate a CNAME to the CDN.
env::cdn_has_cert() {
  [[ "${CERT_MODE:-}" == dns-cloudflare && "${ISSUE_CDN_ORIGIN_CERT:-true}" == true ]]
}

# Prints the domain whose certificate origin nginx serves: CDN_DOMAIN per
# env::cdn_has_cert, else VLESS_DOMAIN, a name of this server. Returns 1 when neither
# applies: a CDN-only setup under http-01 still needs a domain of this server.
env::origin_cert_domain() {
  if env::cdn_has_cert; then
    printf '%s' "${CDN_DOMAIN:-}"
  elif [[ -n "${VLESS_DOMAIN:-}" ]]; then
    printf '%s' "$VLESS_DOMAIN"
  else
    return 1
  fi
}

# Exits 2 when origin nginx would have no certificate to serve.
env::require_origin_cert() {
  env::origin_cert_domain >/dev/null ||
    log::die "$EXIT_INPUT" "origin nginx needs a certificate: set VLESS_DOMAIN to a domain of this server, or use CERT_MODE=dns-cloudflare with ISSUE_CDN_ORIGIN_CERT=true. Rerun ./deploy.sh"
}

# Loads KEY=VALUE lines into exported variables (envsubst reads the environment)
# without executing the file. Values are literal: one pair of matching quotes is
# stripped, and in an unquoted value a # at the start or after a space opens a comment.
# Unknown keys are skipped with a warning, so a stray PATH= or a typo takes no effect.
env::load() {
  local file="$1" line key value n=0 secrets=0
  local re_skip='^[[:space:]]*(#|$)'
  local re_pair='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$'
  [[ -f "$file" && -r "$file" ]] ||
    log::die "$EXIT_INPUT" "cannot read $file: run ./deploy.sh to create it"
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ "$line" =~ $re_skip ]] && continue
    # The line itself is never echoed: it may carry a secret.
    [[ "$line" =~ $re_pair ]] || log::die "$EXIT_INPUT" "$file:$n: expected KEY=VALUE"
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    if ! env::_contains "$key" "${ENV_KEYS[@]}"; then
      log::warn "$file:$n: unknown key $key ignored, see .env.example"
      continue
    fi
    value="$(env::_literal "$value")" ||
      log::die "$EXIT_INPUT" "$file:$n: unbalanced quotes in the value of $key"
    printf -v "$key" '%s' "$value"
    export "${key?}"
    if [[ -n "$value" ]] && env::is_secret "$key"; then
      secrets=1
    fi
  done <"$file"
  if ((secrets)) &&
    [[ -n "$(find "$file" -maxdepth 0 \( -perm -g=r -o -perm -o=r \) 2>/dev/null)" ]]; then
    log::warn "$file holds secrets and is readable by other users: run chmod 600 $file"
  fi
}

env::require() {
  local var missing=()
  for var in "$@"; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  ((${#missing[@]} == 0)) ||
    log::die "$EXIT_INPUT" "required settings are empty: ${missing[*]}. Rerun ./deploy.sh to set them"
}

# Prints the literal value of a raw .env value; fails on unbalanced quotes.
env::_literal() {
  local raw="$1"
  local dq='^"([^"]*)"[[:space:]]*(#.*)?$' sq="^'([^']*)'[[:space:]]*(#.*)?\$"
  if [[ "$raw" =~ $dq || "$raw" =~ $sq ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$raw" == [\"\']* ]]; then
    return 1
  else
    raw="${raw%%[[:space:]]#*}"
    [[ "$raw" == \#* ]] && raw=""
    printf '%s' "${raw%"${raw##*[![:space:]]}"}"
  fi
}

env::_contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# --- interaction ------------------------------------------------------------------------

# Asks a yes/no question on stderr and reads the answer from stdin. An empty answer or
# EOF takes the default: no, unless the second argument is y.
confirm() {
  local prompt="$1" answer default_rc=1 hint='[y/N]'
  if [[ "${2:-n}" == y ]]; then
    default_rc=0
    hint='[Y/n]'
  fi
  while true; do
    printf '%s %s ' "$prompt" "$hint" >&2
    if ! IFS= read -r answer && [[ -z "$answer" ]]; then
      printf '\n' >&2
      return "$default_rc"
    fi
    # Without a terminal the answer is not echoed; end the line for the next message.
    [[ -t 0 ]] || printf '\n' >&2
    answer="${answer//[[:space:]]/}"
    case "${answer,,}" in
      "") return "$default_rc" ;;
      y | yes) return 0 ;;
      n | no) return 1 ;;
      *) log::warn "answer y or n" ;;
    esac
  done
}
