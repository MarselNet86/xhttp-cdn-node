# shellcheck shell=bash
# Collects the .env contract (tech.md §4) interactively: asks in table order, checks
# every answer, writes .env with mode 600. Values of an existing .env are the defaults.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

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
