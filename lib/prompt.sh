# shellcheck shell=bash
# Collects the .env contract (tech.md §4) interactively: asks in table order, checks
# every answer, writes .env with mode 600. Values of an existing .env are the defaults.

set -euo pipefail

# Modules may source this file again; readonly constants must not be redefined.
if [[ -n "${_CDN_PROMPT_LOADED:-}" ]]; then
  return 0
fi
_CDN_PROMPT_LOADED=1

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
    if ! prompt::_asks "$key"; then
      prompt::_skip "$key"
      continue
    fi
    prompt::_number "$key"
    case "$key" in
      ORIGIN_IP) prompt::_ask_origin_ip ;;
      ISSUE_CDN_ORIGIN_CERT) prompt::_ask_issue_cdn_cert ;;
      REALITY_PRIVATE_KEY | REALITY_SHORT_ID) prompt::_ask_reality "$key" ;;
      NODE_NAME) prompt::_ask_node_name ;;
      *) prompt::_ask "$key" ;;
    esac
  done
  UI_NUMBER=""
  prompt::_ask_origin_domain
  prompt::_write_env
}

# Whether KEY gets a question under the answers so far. A question that hangs on the
# answer for a key in PENDING, a list of keys still to ask, counts as asked.
prompt::_asks() {
  local key="$1" pending=" ${2-} " by
  case "$key" in
    # Panel step 2 asks for them: the panel creates the node from the rendered profile.
    NODE_PORT | NODE_SECRET_KEY) return 1 ;;
    CF_API_TOKEN | ISSUE_CDN_ORIGIN_CERT) by=CERT_MODE ;;
    NODE_RELOAD_CMD) by=HY2_DOMAIN ;;
    REALITY_PRIVATE_KEY | REALITY_SHORT_ID) by=REALITY_SNI ;;
    *) return 0 ;;
  esac
  if [[ "$pending" == *" $by "* ]]; then
    return 0
  fi
  case "$key" in
    # Only DNS-01 needs the token. http-01 cannot validate CDN_DOMAIN, a CNAME to the CDN.
    CF_API_TOKEN) [[ "${CERT_MODE:-}" == dns-cloudflare ]] ;;
    ISSUE_CDN_ORIGIN_CERT) [[ "${CERT_MODE:-}" != http-01 ]] ;;
    # The restart makes the node load a renewed HY2_DOMAIN certificate.
    NODE_RELOAD_CMD) [[ -n "${HY2_DOMAIN:-}" ]] ;;
    # Without REALITY_SNI there is no Reality inbound.
    *) [[ -n "${REALITY_SNI:-}" ]] ;;
  esac
}

# A key left without a question keeps its current value. The exception: http-01 forces
# ISSUE_CDN_ORIGIN_CERT=false (tech.md §4).
prompt::_skip() {
  if [[ "$1" == ISSUE_CDN_ORIGIN_CERT ]]; then
    export ISSUE_CDN_ORIGIN_CERT=false
    log::info "ISSUE_CDN_ORIGIN_CERT=false: http-01 cannot validate CDN_DOMAIN, origin nginx serves the VLESS_DOMAIN certificate"
  fi
}

# Numbers the question for KEY in UI_NUMBER, as "3/14". KEY and the keys after it are
# pending, so the total counts every question they may bring and only goes down.
prompt::_number() {
  local key="$1" k n=0 total=0 pending=""
  for k in "${ENV_KEYS[@]}"; do
    if [[ "$k" == "$key" || -n "$pending" ]]; then
      pending+="$k "
    fi
    if prompt::_asks "$k" "$pending"; then
      total=$((total + 1))
      if [[ "$k" == "$key" ]]; then
        n="$total"
      fi
    fi
  done
  UI_NUMBER="$n/$total"
}

# Checks VALUE for KEY against the contract (tech.md §4) and the answers given before
# it in table order. Prints the reason and returns 1 when the value is rejected.
prompt::validate() {
  local key="$1" value="$2" reason="" sample
  case "$key" in
    VLESS_DOMAIN | HY2_DOMAIN | CDN_DOMAIN)
      sample="${key%%_*}"
      # VLESS and Hysteria2 are optional: a server that already runs them adds only the
      # CDN. VLESS_DOMAIN stays required when the origin certificate has to come from it.
      if [[ -z "$value" && "$key" != CDN_DOMAIN ]]; then
        if [[ "$key" == VLESS_DOMAIN ]] && ! env::cdn_has_cert; then
          reason="origin nginx needs a certificate for a domain of this server: under http-01 or ISSUE_CDN_ORIGIN_CERT=false it is VLESS_DOMAIN"
        fi
      elif ! is::fqdn "$value"; then
        reason="expected a domain name like ${sample,,}.example.com$(prompt::_foreign_chars "$value")"
      elif [[ "$key" == CDN_DOMAIN &&
        ("$value" == "${VLESS_DOMAIN:-}" || "$value" == "${HY2_DOMAIN:-}") ]]; then
        reason="must differ from VLESS_DOMAIN and HY2_DOMAIN: it resolves to the CDN, they resolve to this server"
      elif [[ "$key" != CDN_DOMAIN && "$value" == "${CDN_DOMAIN:-}" ]]; then
        reason="must differ from CDN_DOMAIN: it resolves to this server, CDN_DOMAIN to the CDN"
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
    CERT_MODE)
      [[ "$value" == dns-cloudflare || "$value" == http-01 ]] ||
        reason="expected dns-cloudflare or http-01"
      ;;
    CF_API_TOKEN)
      # Cloudflare tokens use the base64url alphabet; anything else is a paste error. The
      # input is hidden, so the reason says what arrived.
      if [[ -z "$value" ]]; then
        reason="nothing entered: the input stays hidden, paste the token and press Enter"
      elif [[ ! "$value" =~ ^[A-Za-z0-9_-]+$ ]]; then
        reason="expected a Cloudflare API token: letters, digits, - and _$(prompt::_foreign_chars "$value" A-Za-z0-9_-)"
      fi
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
    REALITY_SNI)
      if [[ -n "$value" ]] && ! is::fqdn "$value"; then
        reason="expected a domain name like www.swiss.com, or - for no Reality$(prompt::_foreign_chars "$value")"
      fi
      ;;
    REALITY_PRIVATE_KEY)
      # 32 bytes in unpadded base64url, the form xray x25519 prints.
      [[ "$value" =~ ^[A-Za-z0-9_-]{43}$ ]] ||
        reason="expected an x25519 private key: 43 characters of base64url"
      ;;
    REALITY_SHORT_ID)
      [[ "$value" =~ ^([0-9a-f]{2}){1,8}$ ]] || reason="expected 2 to 16 hex digits, an even count"
      ;;
    NODE_NAME)
      [[ "$value" =~ ^[a-z0-9]([a-z0-9-]{0,14}[a-z0-9])?$ ]] ||
        reason="expected a short name like de1: up to 16 letters, digits and inner -$(prompt::_foreign_chars "$value" a-z0-9-)"
      ;;
    NODE_PORT)
      if ! is::port "$value"; then
        reason="expected a port from 1 to 65535, NODE_PORT in the docker-compose.yml of the panel"
      elif [[ "$value" == 443 || "$value" == "${XHTTP_PORT:-}" || "$value" == "${NGINX_TLS_PORT:-}" ]]; then
        reason="must differ from 443, XHTTP_PORT and NGINX_TLS_PORT: xray and nginx listen there"
      fi
      ;;
    NODE_SECRET_KEY)
      reason="$(prompt::_node_key_problem "$value")"
      ;;
    *) reason="$key is not in the .env contract" ;;
  esac
  if [[ -n "$reason" ]]; then
    printf '%s\n' "$reason"
    return 1
  fi
}

# What is wrong with a SECRET_KEY, if anything. The node takes base64 of a JSON object with
# four PEM strings (remnawave/node 3.4 checks the same), so a mangled paste shows up here
# and not in the node log.
prompt::_node_key_problem() {
  local value="$1"
  if [[ -z "$value" ]]; then
    echo "nothing entered: copy SECRET_KEY from the docker-compose.yml that the panel shows for the node"
  elif [[ ! "$value" =~ ^[A-Za-z0-9+/]+=*$ ]]; then
    echo "expected SECRET_KEY from the panel: base64, letters, digits, + and /$(prompt::_foreign_chars "$value" 'A-Za-z0-9+/=')"
  elif ! base64 -d <<<"$value" 2>/dev/null |
    jq -e 'type == "object" and ([.caCertPem, .jwtPublicKey, .nodeCertPem, .nodeKeyPem] | all(type == "string"))' \
      >/dev/null 2>&1; then
    echo "it does not decode to the node certificates (caCertPem, jwtPublicKey, nodeCertPem, nodeKeyPem): copy the whole value from the panel"
  fi
}

# Lowercases the case-insensitive values; "-" clears the optional ones. A SECRET_KEY
# pasted with its line from docker-compose.yml keeps only the value.
prompt::_normalize() {
  local key="$1" value="$2"
  case "$key" in
    VLESS_DOMAIN | HY2_DOMAIN | LE_EMAIL | REALITY_SNI)
      if [[ "$value" == - ]]; then
        value=""
      fi
      ;;
    NODE_SECRET_KEY)
      value="$(prompt::_trim "${value#-}")"
      if [[ "$value" == SECRET_KEY* ]]; then
        value="$(prompt::_trim "${value#SECRET_KEY}")"
        value="$(prompt::_trim "${value#[=:]}")"
      fi
      case "$value" in
        \"*\" | \'*\') value="${value:1:${#value}-2}" ;;
      esac
      ;;
  esac
  case "$key" in
    *_DOMAIN | CERT_MODE | REALITY_SNI | REALITY_SHORT_ID | NODE_NAME) value="${value,,}" ;;
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
  local key="$1" default label="${3-}" answer value reason eof cut hidden=0 text
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
  if [[ -t 0 ]] && env::is_secret "$key"; then
    hidden=1
  fi
  text="$(prompt::_question "$key")"
  ui::question "${text%%|*}" "${text#*|}"
  while true; do
    ui::field "$key" "$label"
    eof=0
    if ((hidden)); then
      IFS= read -rs answer || eof=1
    else
      IFS= read -r answer || eof=1
      # Without a terminal the answer is not echoed; end the line for the next message.
      [[ -t 0 ]] || printf '\n' >&2
    fi
    cut=0
    if [[ -t 0 ]] && (($(prompt::_bytes "$answer") >= 4095)); then
      cut=1
    fi
    answer="$(prompt::_trim "$answer")"
    if ((hidden)); then
      ui::hidden "${#answer}"
    fi
    # A terminal line holds 4095 bytes and drops the rest of a longer paste, so a line that
    # fills it lost its end.
    if ((cut)); then
      ui::rejected "$key" "the terminal cut the paste at 4095 characters: put $key into $ENV_FILE by hand"
      continue
    fi
    value="$(prompt::_normalize "$key" "${answer:-$default}")"
    if reason="$(prompt::validate "$key" "$value")"; then
      printf -v "$key" '%s' "$value"
      export "${key?}"
      return 0
    fi
    if ((eof)); then
      log::die "$EXIT_INPUT" "$key: $reason. Input ended: run ./deploy.sh in a terminal or complete $ENV_FILE"
    fi
    ui::rejected "$key" "$reason"
  done
}

# The length of S in bytes.
prompt::_bytes() {
  local LC_ALL=C
  printf '%d' "${#1}"
}

# Prints the question for KEY and, after a |, its hint.
prompt::_question() {
  case "$1" in
    VLESS_DOMAIN) echo "Domain for direct VLESS connections|an A record to this server; - for none" ;;
    HY2_DOMAIN) echo "Domain for Hysteria2 whose certificate this script issues|an A record to this server; - for none" ;;
    CDN_DOMAIN) echo "Domain of the CDN resource|a CNAME to the CDN" ;;
    ORIGIN_IP) echo "Public IPv4 of this server|the origin of the CDN resource" ;;
    XHTTP_PORT) echo "Local port of the xray xhttp inbound|" ;;
    XHTTP_PATH) echo "xhttp path|the same in the panel inbound and host" ;;
    NGINX_TLS_PORT) echo "Port where nginx accepts connections from the CDN edge|" ;;
    CERT_MODE) echo "Certificate issuance|dns-cloudflare or http-01" ;;
    CF_API_TOKEN) echo "Cloudflare API token with Zone:DNS:Edit|input hidden: paste it and press Enter" ;;
    LE_EMAIL) echo "Let's Encrypt contact email|- for none" ;;
    NODE_RELOAD_CMD) echo "Command that restarts the node after the Hysteria2 certificate renews|certbot runs it after each renewal; remnanode is the container from the panel" ;;
    REALITY_SNI) echo "Site that VLESS Reality impersonates|TLS 1.3, close to this server, open from Russia; - for no Reality" ;;
    REALITY_PRIVATE_KEY) echo "Reality x25519 private key|input hidden" ;;
    REALITY_SHORT_ID) echo "Reality short id|hex" ;;
    NODE_NAME) echo "Short name of this node for the panel|the inbound tags end with it, de1 gives VLESS-REALITY-DE1: the panel wants every tag unique" ;;
    NODE_PORT) echo "NODE_PORT of the node|from the same docker-compose.yml; the panel connects to the node on it" ;;
    NODE_SECRET_KEY) echo "SECRET_KEY of the node|from the docker-compose.yml that the panel shows; input hidden: paste the value or its whole line" ;;
  esac
}

# A paste from a web page or a messenger can carry characters that a terminal does not
# show: zero-width space, non-joiner and joiner, the direction marks, the word joiner, the
# byte order mark and the soft hyphen. No setting holds them, so they go. No-break spaces
# (plain, figure, narrow), which [:space:] leaves out, count as spaces.
readonly -a PROMPT_INVISIBLE=($'\xe2\x80\x8b' $'\xe2\x80\x8c' $'\xe2\x80\x8d' $'\xe2\x80\x8e'
  $'\xe2\x80\x8f' $'\xe2\x81\xa0' $'\xef\xbb\xbf' $'\xc2\xad')
readonly -a PROMPT_NBSP=($'\xc2\xa0' $'\xe2\x80\x87' $'\xe2\x80\xaf')

prompt::_trim() {
  local s="$1" c
  for c in "${PROMPT_INVISIBLE[@]}"; do
    s="${s//"$c"/}"
  done
  for c in "${PROMPT_NBSP[@]}"; do
    s="${s//"$c"/ }"
  done
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# Names the first characters of VALUE outside ALLOWED, a bracket expression that defaults
# to the characters of a domain, with their positions: a Cyrillic letter that looks Latin,
# a typographic dash, a key typed as a control code.
prompt::_foreign_chars() {
  local LC_ALL=C.UTF-8 s="$1" re="^[${2:-A-Za-z0-9.-}]$" ch n i list="" found=0
  for ((i = 0; i < ${#s} && found < 3; i++)); do
    ch="${s:i:1}"
    if [[ "$ch" =~ $re ]]; then
      continue
    fi
    printf -v n '%d' "'$ch"
    if ((n < 32 || n == 127)); then
      ch="a control character (an arrow or another special key)"
    elif ((n == 32)); then
      ch="a space"
    elif ((n < 128)); then
      ch="'$ch'"
    elif ((n >= 0x400 && n <= 0x4ff)); then
      ch="Cyrillic $ch"
    elif ((n >= 0x2010 && n <= 0x2015 || n == 0x2212)); then
      printf -v ch 'a typographic dash %s (U+%04X)' "$ch" "$n"
    else
      printf -v ch '%s (U+%04X)' "$ch" "$n"
    fi
    list+="${list:+, }$ch at $((i + 1))"
    # A special key types a whole escape sequence: its start says enough.
    if ((n < 32 || n == 127)); then
      break
    fi
    found=$((found + 1))
  done
  if [[ -n "$list" ]]; then
    printf '; it holds %s' "$list"
  fi
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

# The Reality keys of the generated config profile. Enter keeps the keys of an existing
# .env, so a rerun does not break the clients; without them it takes new ones.
prompt::_ask_reality() {
  local key="$1"
  if [[ -n "${!key:-}" ]]; then
    prompt::_ask "$key"
  elif [[ "$key" == REALITY_PRIVATE_KEY ]]; then
    prompt::_ask "$key" "$(prompt::_new_reality_key)" "new random"
  else
    prompt::_ask "$key" "$(prompt::_new_short_id)"
  fi
}

# Any 32 random bytes make an x25519 private key: the curve clamps it on use.
prompt::_new_reality_key() {
  head -c 32 /dev/urandom | base64 | tr -d '\n=' | tr '+/' '-_'
}

prompt::_new_short_id() {
  head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# Panel step 2: SECRET_KEY and NODE_PORT of the node that the panel has just created, from
# the docker-compose.yml it shows. Asked once and kept in .env. SECRET and PORT, the values
# of a compose file set up by hand, are the defaults, and input that has ended takes them.
# Returns 1 when no key comes from anywhere.
prompt::node() {
  local secret="$1" port="${2:-}"
  if [[ -n "${NODE_SECRET_KEY:-}" ]]; then
    return 0
  fi
  if [[ -z "$secret" && ! -t 0 ]]; then
    return 1
  fi
  UI_NUMBER=""
  prompt::_ask NODE_SECRET_KEY "$secret" "${secret:+from docker-compose.yml}"
  prompt::_ask NODE_PORT "${port:-${NODE_PORT:-}}"
  prompt::_write_env
}

# Without a name in .env, the first label of VLESS_DOMAIN names the node, else the host.
prompt::_ask_node_name() {
  local name="${NODE_NAME:-}"
  if [[ -z "$name" && -n "${VLESS_DOMAIN:-}" ]]; then
    name="${VLESS_DOMAIN%%.*}"
  elif [[ -z "$name" ]]; then
    name="$(hostname -s 2>/dev/null || true)"
  fi
  prompt::_ask NODE_NAME "${name,,}"
}

# VLESS_DOMAIN may be skipped before CERT_MODE is known. When the answers leave origin
# nginx without a certificate, it is asked again, now as a required value.
prompt::_ask_origin_domain() {
  if ! env::origin_cert_domain >/dev/null; then
    log::warn "origin nginx needs a certificate: under http-01 or ISSUE_CDN_ORIGIN_CERT=false it comes from VLESS_DOMAIN, a domain of this server"
    prompt::_ask VLESS_DOMAIN
  fi
}

prompt::_ask_issue_cdn_cert() {
  local default=y
  if [[ "${ISSUE_CDN_ORIGIN_CERT:-}" == false ]]; then
    default=n
  fi
  if confirm "Issue an origin certificate for $CDN_DOMAIN (ISSUE_CDN_ORIGIN_CERT)?" "$default"; then
    ISSUE_CDN_ORIGIN_CERT=true
  else
    ISSUE_CDN_ORIGIN_CERT=false
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
