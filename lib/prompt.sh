# shellcheck shell=bash
# Collects the .env contract (tech.md §4) interactively: asks in table order, checks
# every answer, writes .env with mode 600. Values of an existing .env are the defaults.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

prompt::collect() {
  local key
  env::load "$ENV_EXAMPLE"
  if [[ -f "$ENV_FILE" ]]; then
    env::load "$ENV_FILE"
    log::info "current values from $ENV_FILE are the defaults"
  fi
  log::info "Enter keeps the value in [brackets]"
  for key in "${ENV_KEYS[@]}"; do
    case "$key" in
      ORIGIN_IP) prompt::_ask_origin_ip ;;
      UUID) prompt::_ask_uuid ;;
      CF_API_TOKEN) prompt::_ask_cf_token ;;
      ISSUE_CDN_ORIGIN_CERT) prompt::_ask_issue_cdn_cert ;;
      *) prompt::_ask "$key" ;;
    esac
  done
  prompt::_write_env
}

# Checks VALUE for KEY against the contract (tech.md §4) and the answers given before
# it in table order. Prints the reason and returns 1 when the value is rejected.
prompt::validate() {
  local key="$1" value="$2" reason="" sample
  case "$key" in
    VLESS_DOMAIN | HY2_DOMAIN | CDN_DOMAIN)
      sample="${key%%_*}"
      if ! is::fqdn "$value"; then
        reason="expected a domain name like ${sample,,}.example.com"
      elif [[ "$key" == CDN_DOMAIN &&
        ("$value" == "${VLESS_DOMAIN:-}" || "$value" == "${HY2_DOMAIN:-}") ]]; then
        reason="must differ from VLESS_DOMAIN and HY2_DOMAIN: it resolves to the CDN, they resolve to this server"
      fi
      ;;
    ORIGIN_IP)
      is::ipv4 "$value" || reason="expected an IPv4 address like 203.0.113.10"
      ;;
    XHTTP_PORT | NGINX_TLS_PORT)
      if ! is::port "$value"; then
        reason="expected a port from 1 to 65535"
      elif ((value == 443)); then
        reason="443 belongs to xray: Reality over TCP, Hysteria2 over UDP"
      elif [[ "$key" == NGINX_TLS_PORT && "$value" == "${XHTTP_PORT:-}" ]]; then
        reason="must differ from XHTTP_PORT: nginx would take the port of the xray inbound"
      fi
      ;;
    XHTTP_PATH)
      # Unreserved URL characters only: the path lands in nginx locations and in JSON.
      if [[ ! "$value" =~ ^/([A-Za-z0-9._~-]+/)+$ || "$value" == */./* || "$value" == */../* ]]; then
        reason="expected a path like /api/v2.jpg/: starts and ends with /, letters, digits and . _ ~ -"
      fi
      ;;
    UUID)
      [[ "$value" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] ||
        reason="expected a UUIDv4: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
      ;;
    CERT_MODE)
      [[ "$value" == dns-cloudflare || "$value" == http-01 ]] ||
        reason="expected dns-cloudflare or http-01"
      ;;
    CF_API_TOKEN)
      # Cloudflare tokens use the base64url alphabet; anything else is a paste error.
      [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]] ||
        reason="expected a Cloudflare API token: letters, digits, - and _"
      ;;
    LE_EMAIL)
      if [[ -n "$value" ]] && ! prompt::_is_email "$value"; then
        reason="expected an email like ops@example.com, or - for none"
      fi
      ;;
    NODE_RELOAD_CMD)
      if [[ -z "$value" ]]; then
        reason="expected a command like: docker restart remnawave-node"
      elif [[ "$value" == *\'* && "$value" == *\"* ]]; then
        reason="use either single or double quotes: .env keeps the command as one quoted value"
      fi
      ;;
    ISSUE_CDN_ORIGIN_CERT)
      [[ "$value" == true || "$value" == false ]] || reason="expected true or false"
      ;;
    *) reason="$key is not in the .env contract" ;;
  esac
  if [[ -n "$reason" ]]; then
    printf '%s\n' "$reason"
    return 1
  fi
}

# Lowercases the case-insensitive values; "-" clears LE_EMAIL.
prompt::_normalize() {
  local key="$1" value="$2"
  case "$key" in
    *_DOMAIN | UUID | CERT_MODE) value="${value,,}" ;;
    LE_EMAIL)
      if [[ "$value" == - ]]; then
        value=""
      fi
      ;;
  esac
  printf '%s' "$value"
}

prompt::_is_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@([^@]+)$ ]] && is::fqdn "${BASH_REMATCH[1]}"
}

# --- questions --------------------------------------------------------------------------

# Asks for KEY until prompt::validate accepts the answer, then sets and exports KEY.
# Enter takes DEFAULT (the current value unless given); LABEL is shown in its place.
# Once stdin runs out, an acceptable default is taken and anything else is an error,
# so deploy.sh runs without a terminal when .env is complete.
prompt::_ask() {
  local key="$1" default label="${3-}" answer value reason eof
  if (($# >= 2)); then
    default="$2"
  else
    default="${!key:-}"
  fi
  if [[ -z "$label" && -n "$default" ]]; then
    label="$default"
    if env::is_secret "$key"; then
      label="keep current"
    fi
  fi
  while true; do
    printf '%s\n%s%s: ' "$(prompt::_question "$key")" "$key" "${label:+ [$label]}" >&2
    eof=0
    if [[ -t 0 ]] && env::is_secret "$key"; then
      IFS= read -rs answer || eof=1
      printf '\n' >&2
    else
      IFS= read -r answer || eof=1
      # Without a terminal the answer is not echoed; end the line for the next message.
      [[ -t 0 ]] || printf '\n' >&2
    fi
    answer="$(prompt::_trim "$answer")"
    value="$(prompt::_normalize "$key" "${answer:-$default}")"
    if reason="$(prompt::validate "$key" "$value")"; then
      printf -v "$key" '%s' "$value"
      export "${key?}"
      return 0
    fi
    if ((eof)); then
      log::die "$EXIT_INPUT" "$key: $reason. Input ended: run ./deploy.sh in a terminal or complete $ENV_FILE"
    fi
    log::warn "$key: $reason"
  done
}

prompt::_question() {
  case "$1" in
    VLESS_DOMAIN) echo "Domain for direct VLESS connections, an A record to this server" ;;
    HY2_DOMAIN) echo "Domain for Hysteria2, an A record to this server" ;;
    CDN_DOMAIN) echo "Domain of the CDN resource, a CNAME to the CDN" ;;
    ORIGIN_IP) echo "Public IPv4 of this server, the origin of the CDN resource" ;;
    XHTTP_PORT) echo "Local port of the xray xhttp inbound" ;;
    XHTTP_PATH) echo "xhttp path, the same in the panel inbound and host" ;;
    NGINX_TLS_PORT) echo "Port where nginx accepts connections from the CDN edge" ;;
    UUID) echo "VLESS client UUID (input hidden)" ;;
    CERT_MODE) echo "Certificate issuance: dns-cloudflare or http-01" ;;
    CF_API_TOKEN) echo "Cloudflare API token with Zone:DNS:Edit (input hidden)" ;;
    LE_EMAIL) echo "Let's Encrypt contact email, - for none" ;;
    NODE_RELOAD_CMD) echo "Command that restarts the node after a certificate renewal" ;;
  esac
}

prompt::_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# Without a value in .env, offers the IPv4 that ifconfig.me sees (tech.md §4).
prompt::_ask_origin_ip() {
  local detected
  if [[ -z "${ORIGIN_IP:-}" ]] && detected="$(prompt::_detect_ip)" &&
    confirm "Detected public IPv4 $detected. Use it as ORIGIN_IP?" y; then
    export ORIGIN_IP="$detected"
    return 0
  fi
  prompt::_ask ORIGIN_IP
}

prompt::_detect_ip() {
  local ip
  if ! command -v curl >/dev/null 2>&1; then
    log::warn "curl not found: enter ORIGIN_IP by hand"
    return 1
  fi
  # HTTPS, so nobody on the path can swap the address that gets confirmed.
  if ! ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null)" || ! is::ipv4 "$ip"; then
    log::warn "cannot detect the public IPv4 via ifconfig.me: enter ORIGIN_IP by hand"
    return 1
  fi
  printf '%s' "$ip"
}

# Keeps the current UUID; without one, Enter takes a new random UUIDv4.
prompt::_ask_uuid() {
  if [[ -z "${UUID:-}" && -r /proc/sys/kernel/random/uuid ]]; then
    prompt::_ask UUID "$(</proc/sys/kernel/random/uuid)" "new random"
  else
    prompt::_ask UUID
  fi
}

# Only DNS-01 needs the token; under http-01 the current value stays as it is.
prompt::_ask_cf_token() {
  if [[ "$CERT_MODE" == dns-cloudflare ]]; then
    prompt::_ask CF_API_TOKEN
  fi
}

# http-01 cannot validate CDN_DOMAIN, a CNAME to the CDN, so it forces false (tech.md §4).
prompt::_ask_issue_cdn_cert() {
  local default=y
  if [[ "$CERT_MODE" == http-01 ]]; then
    ISSUE_CDN_ORIGIN_CERT=false
    log::info "ISSUE_CDN_ORIGIN_CERT=false: http-01 cannot validate CDN_DOMAIN, origin nginx reuses the VLESS_DOMAIN certificate"
  else
    if [[ "${ISSUE_CDN_ORIGIN_CERT:-}" == false ]]; then
      default=n
    fi
    if confirm "Issue an origin certificate for $CDN_DOMAIN (ISSUE_CDN_ORIGIN_CERT)?" "$default"; then
      ISSUE_CDN_ORIGIN_CERT=true
    else
      ISSUE_CDN_ORIGIN_CERT=false
    fi
  fi
  export ISSUE_CDN_ORIGIN_CERT
}

# --- .env -----------------------------------------------------------------------------

# Writes .env with mode 600, since it holds CF_API_TOKEN.
prompt::_write_env() {
  local key
  for key in "${ENV_KEYS[@]}"; do
    if [[ "${!key:-}" == *\'* && "${!key:-}" == *\"* ]]; then
      log::die "$EXIT_INPUT" "$key holds both ' and \": .env cannot keep it, fix it in $ENV_FILE"
    fi
  done
  fs::write "$ENV_FILE" 600 "$(prompt::_render_env)"
}

prompt::_render_env() {
  local key
  printf '# cdn-deploy settings, described in .env.example. Written by ./deploy.sh: rerun it to change them.\n'
  for key in "${ENV_KEYS[@]}"; do
    printf '%s=%s\n' "$key" "$(prompt::_quote "${!key:-}")"
  done
}

# Quotes a value so that env::load reads it back unchanged.
prompt::_quote() {
  if [[ "$1" =~ ^[A-Za-z0-9._~@%+=:,/-]*$ ]]; then
    printf '%s' "$1"
  elif [[ "$1" != *\'* ]]; then
    printf "'%s'" "$1"
  else
    printf '"%s"' "$1"
  fi
}
