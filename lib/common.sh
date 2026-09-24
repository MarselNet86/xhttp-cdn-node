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

# .env lives in the repository root next to deploy.sh.
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck disable=SC2034  # read by the scripts that source this file
readonly REPO_ROOT ENV_FILE="$REPO_ROOT/.env" ENV_EXAMPLE="$REPO_ROOT/.env.example"

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
  export OS_ID="$id" OS_VERSION_ID="$version"
  export PKG_INSTALL="env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends"
}
