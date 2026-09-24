#!/usr/bin/env bash
# Checks every server of a Remnawave subscription (tech.md §5): parses the subscription,
# probes each server at L7, then carries real traffic through it with a local xray.
# Standalone: it needs no .env and changes nothing on the host.
set -Eeuo pipefail

# shellcheck source=lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

# Remnawave answers with base64 share links to v2ray-style clients.
readonly CHECK_USER_AGENT="${CHECK_USER_AGENT:-v2rayNG/1.10.5}"
readonly CHECK_PROBE_URL="${CHECK_PROBE_URL:-http://www.gstatic.com/generate_204}"
readonly CHECK_XRAY="${CHECK_XRAY:-xray}"
# Seconds for one request through a tunnel.
readonly CHECK_TIMEOUT=15

# jq helpers of the JSON parsers. val: the first non-empty value, as a string. q: a query
# pair with the value URL-encoded, nothing when the value is empty. record: the fields
# joined with |, each without | and control characters.
# shellcheck disable=SC2016  # jq code: $k and $v are jq variables
readonly CHECK_JQ_DEFS='
  def val(f): [f | select(. != null and . != "" and . != false) | tostring] | first // "";
  def q($k; f): val(f) as $v | if $v == "" then empty else "\($k)=\($v | @uri)" end;
  def record: map(. // "" | tostring | gsub("\\|"; "/") | gsub("[[:cntrl:]]"; "")) | join("|");
'

check::usage() {
  cat <<'EOF'
Usage: ./check.sh [--fast] <subscription-url>

Checks every server of a Remnawave subscription: an L7 probe of each endpoint, then a real
tunnel through a local xray to CHECK_PROBE_URL. Prints a table; exits 1 if any server fails.

Options:
  --fast      L7 probes only, no tunnels
  -h, --help  show this help

Environment:
  CHECK_PROBE_URL   URL fetched through each tunnel, must answer 204
                    (default http://www.gstatic.com/generate_204)
  CHECK_XRAY        xray binary for the tunnels (default: xray from PATH)
  CHECK_USER_AGENT  User-Agent for the subscription request (default v2rayNG/1.10.5)
EOF
}

# --- subscription -----------------------------------------------------------------------

# Prints one record per server: proto|addr|port|sni|host|path|params|name. params is a
# query string: the share-link query with the credential added as uid=. name, the display
# name of the server, is there for the report.
check::fetch() {
  local url="$1" body rc=0
  body="$(curl -fsSL --max-time 30 -A "$CHECK_USER_AGENT" "$url")" || rc=$?
  ((rc == 0)) || log::die "$EXIT_FAILURE" \
    "cannot fetch the subscription: $(check::_curl_error "$rc"). Check the URL and that the panel is up"
  check::parse "$body"
}

# Base64 share links first, as Remnawave serves them; a plain list, sing-box JSON and
# xray-json as fallbacks.
check::parse() {
  local body="$1" decoded
  if [[ "$body" =~ ^[[:space:]]*[\<] ]]; then
    log::die "$EXIT_FAILURE" "the subscription URL returned a web page: check the URL and CHECK_USER_AGENT"
  elif [[ "$body" =~ ^[[:space:]]*[{[] ]]; then
    if jq -e 'type == "object" and (.outbounds // [] | any(has("type")))' >/dev/null 2>&1 <<<"$body"; then
      check::_parse_singbox "$body"
    elif jq -e '[if type == "array" then .[] else . end | .outbounds // [] | .[] | has("protocol")] | any' \
      >/dev/null 2>&1 <<<"$body"; then
      check::_parse_xray "$body"
    else
      log::die "$EXIT_FAILURE" "the subscription is JSON, but neither sing-box nor xray-json"
    fi
  elif [[ "$body" == *://* ]]; then
    check::_parse_links <<<"$body"
  elif decoded="$(check::_b64decode "$body")" && [[ "$decoded" == *://* ]]; then
    check::_parse_links <<<"$decoded"
  else
    log::die "$EXIT_FAILURE" "the subscription holds no share links: an expired user or a wrong URL"
  fi
}

check::_parse_links() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    if [[ "$line" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
      check::_parse_link "$line"
    fi
  done
}

# scheme://credential@host:port?query#name; vmess:// carries base64 JSON instead.
check::_parse_link() {
  local link="$1" scheme rest name="" query="" cred="" addr port type security proto sni host params
  scheme="${link%%://*}"
  scheme="${scheme,,}"
  rest="${link#*://}"
  case "$scheme" in
    vmess)
      check::_parse_vmess "$rest"
      return 0
      ;;
    hy2) scheme=hysteria2 ;;
    ss) scheme=shadowsocks ;;
  esac
  if [[ "$rest" == *"#"* ]]; then
    name="$(check::_urldecode "${rest#*#}")"
    rest="${rest%%#*}"
  fi
  if [[ "$rest" == *"?"* ]]; then
    query="${rest#*\?}"
    rest="${rest%%\?*}"
  fi
  rest="${rest%/}"
  # Old shadowsocks links encode method:password@host:port as a whole.
  if [[ "$scheme" == shadowsocks && "$rest" != *@* ]]; then
    rest="$(check::_b64decode "$rest" || true)"
  fi
  if [[ "$rest" == *@* ]]; then
    cred="${rest%@*}"
    rest="${rest##*@}"
  fi
  if [[ "$rest" == \[* ]]; then
    addr="${rest#\[}"
    addr="${addr%%\]*}"
    port="${rest##*\]}"
  else
    addr="${rest%%:*}"
    port="${rest#"$addr"}"
  fi
  port="${port#:}"
  [[ -n "$port" ]] || port=443
  if [[ -z "$addr" ]] || ! is::port "$port"; then
    log::warn "skipped a $scheme link without a valid host and port: ${name:-unnamed}"
    return 0
  fi
  type="$(check::_param "$query" type)"
  security="$(check::_param "$query" security)"
  case "$scheme" in
    hysteria2) proto=hysteria2 ;;
    trojan) proto="trojan-${type:-tcp}-${security:-tls}" ;;
    *) proto="$scheme-${type:-tcp}-${security:-none}" ;;
  esac
  proto="${proto//-raw-/-tcp-}"
  proto="${proto//-splithttp-/-xhttp-}"
  sni="$(check::_param "$query" sni)"
  [[ -n "$sni" ]] || sni="$(check::_param "$query" peer)"
  [[ -n "$sni" ]] || sni="$addr"
  host="$(check::_param "$query" host)"
  [[ -n "$host" ]] || host="$sni"
  params="uid=$cred"
  if [[ "$scheme" == shadowsocks ]]; then
    params="$(check::_ss_params "$cred")"
  fi
  check::_record "$proto" "$addr" "$port" "$sni" "$host" "$(check::_param "$query" path)" \
    "$params${query:+&$query}" "$name"
}

# shadowsocks userinfo is base64 of method:password, or plain for 2022 ciphers (SIP002).
check::_ss_params() {
  local info
  info="$(check::_urldecode "$1")"
  if [[ "$info" != *:* ]]; then
    info="$(check::_b64decode "$info" || true)"
  fi
  jq -rn --arg method "${info%%:*}" --arg password "${info#*:}" \
    '"uid=\($password | @uri)&method=\($method | @uri)"'
}

check::_parse_vmess() {
  local json
  json="$(check::_b64decode "$1")" || return 0
  jq -r "$CHECK_JQ_DEFS"'
    select(type == "object" and val(.add) != "" and (val(.port) | test("^[0-9]+$")))
    | (val(.net) | if . == "" or . == "raw" then "tcp" else . end) as $net
    | (val(.tls) | if . == "" then "none" else . end) as $sec
    | val(.sni, .host, .add) as $sni
    | ["vmess-\($net)-\($sec)", .add, val(.port), $sni, val(.host, $sni), val(.path),
       ([q("uid"; .id), q("type"; $net), q("security"; $sec), q("sni"; .sni), q("alpn"; .alpn),
         q("fp"; .fp)] | join("&")),
       .ps]
    | record' <<<"$json" 2>/dev/null || true
}

# sing-box: the outbounds with a server, rebuilt as share-link fields. Selectors, direct,
# block and dns have none.
check::_parse_singbox() {
  jq -r "$CHECK_JQ_DEFS"'
    def one: if type == "array" then .[0] else . end;
    .outbounds[] | select(val(.server) != "" and (val(.server_port) | test("^[0-9]+$")))
    | (.tls // {}) as $tls | (.transport // {}) as $tr
    | (if $tls.reality.enabled then "reality" elif $tls.enabled then "tls" else "none" end) as $sec
    | ($tr.type // "tcp" | if . == "http" then "h2" else . end) as $net
    | val($tls.server_name, .server) as $sni
    | [(if .type == "hysteria2" then "hysteria2" else "\(.type)-\($net)-\($sec)" end),
       .server, .server_port, $sni, val(($tr.headers.Host, $tr.host | one), $sni), val($tr.path),
       ([q("uid"; .uuid, .password), q("method"; .method), q("type"; $net), q("security"; $sec),
         q("sni"; $tls.server_name), q("fp"; $tls.utls.fingerprint), q("pbk"; $tls.reality.public_key),
         q("sid"; $tls.reality.short_id), q("flow"; .flow), q("alpn"; $tls.alpn // [] | join(",")),
         q("insecure"; if $tls.insecure then 1 else "" end), q("serviceName"; $tr.service_name),
         q("obfs"; .obfs.type), q("obfs-password"; .obfs.password)] | join("&")),
       .tag]
    | record' <<<"$1"
}

# xray-json: one config per server, its first outbound that leaves the host. The outbound
# travels along as outbound= so the tunnel uses it as it is.
check::_parse_xray() {
  jq -r "$CHECK_JQ_DEFS"'
    (if type == "array" then .[] else . end) as $cfg
    | [$cfg.outbounds[]? | select(.protocol | IN("freedom", "blackhole", "dns", "loopback") | not)][0]
    | select(. != null)
    | . as $ob | (.streamSettings // {}) as $ss
    | (.settings.vnext[0] // .settings.servers[0] // .settings) as $srv
    | select(val($srv.address) != "" and (val($srv.port) | test("^[0-9]+$")))
    | (val($ss.network) | if . == "" or . == "raw" then "tcp" elif . == "splithttp" then "xhttp" else . end) as $net
    | (val($ss.security) | if . == "" then "none" else . end) as $sec
    | val($ss.tlsSettings.serverName, $ss.realitySettings.serverName, $srv.address) as $sni
    | ($ss.xhttpSettings // $ss.splithttpSettings // $ss.wsSettings // $ss.httpupgradeSettings // {}) as $http
    | [(if .protocol == "hysteria" then "hysteria2" else "\(.protocol)-\($net)-\($sec)" end),
       $srv.address, $srv.port, $sni, val($http.host, $sni), val($http.path),
       ([q("uid"; $srv.users[0].id, $srv.id, $srv.password, $ss.hysteriaSettings.auth), q("type"; $net),
         q("security"; $sec), q("extra"; $http.extra // empty | tojson),
         q("outbound"; $ob | tojson | @base64)] | join("&")),
       val($cfg.remarks, .tag)]
    | record' <<<"$1"
}

check::_record() {
  local field out=()
  for field in "$@"; do
    field="${field//[[:cntrl:]]/}"
    out+=("${field//|//}")
  done
  (
    IFS='|'
    printf '%s\n' "${out[*]}"
  )
}

# Value of KEY in a query string, URL-decoded; empty when absent.
check::_param() {
  local pair
  local -a pairs
  IFS='&' read -ra pairs <<<"$1"
  for pair in "${pairs[@]}"; do
    if [[ "${pair%%=*}" == "$2" ]]; then
      check::_urldecode "${pair#*=}"
      return 0
    fi
  done
}

# Share links encode a space as %20, so + stays a plus. Backslashes are doubled first so
# that printf %b decodes the %XX escapes only.
check::_urldecode() {
  local bs=$'\\' hex=$'\\x' s
  s="${1//"$bs"/"$bs$bs"}"
  printf '%b' "${s//%/"$hex"}"
}

# Accepts standard and URL-safe base64, with or without padding and line breaks.
check::_b64decode() {
  local s
  s="$(tr -d '[:space:]' <<<"$1" | tr '_-' '/+')"
  while ((${#s} % 4)); do
    s+="="
  done
  base64 -d 2>/dev/null <<<"$s"
}

# --- probes -----------------------------------------------------------------------------

# L7 check of one record. Prints STATUS|detail|ms: STATUS is OK, FAIL or SKIP, ms the
# latency in milliseconds when there is one.
check::probe_fast() {
  local proto addr port sni host path params name
  IFS='|' read -r proto addr port sni host path params name <<<"$1"
  if check::_placeholder "$addr"; then
    echo "SKIP|$addr is a placeholder, not a server|"
    return 0
  fi
  case "${proto%%-*}" in
    vless | vmess | trojan | shadowsocks | hysteria2 | hysteria | tuic) ;;
    *)
      echo "SKIP|no probe for ${proto%%-*}|"
      return 0
      ;;
  esac
  case "$proto" in
    hysteria2 | hysteria-* | tuic-*)
      if [[ -n "$(check::_param "$params" obfs)" ]]; then
        echo "SKIP|obfuscated QUIC, only the tunnel tells|"
      else
        check::_probe_quic "$addr" "$port"
      fi
      ;;
    *-xhttp-tls) check::_probe_xhttp "$addr" "$port" "$sni" "$host" "$path" "$params" ;;
    *-tls | *-reality) check::_probe_tls "$addr" "$port" "$sni" ;;
    *) check::_probe_tcp "$addr" "$port" ;;
  esac
}

# xray answers a request without a session with 400 and its padding header. The CDN
# codes say where the chain breaks.
check::_probe_xhttp() {
  local addr="$1" port="$2" sni="$3" host="$4" path="${5:-/}" params="$6" header out rc=0 code ms
  local -a args=(-s -o /dev/null -D - -w '\n%{time_total}' --max-time 10 -H "Host: $host"
    --connect-to "$(check::_bracket "$sni"):$port:$(check::_bracket "$addr"):$port")
  if check::_insecure "$params"; then
    args+=(-k)
  fi
  header="$(check::_param "$params" extra | jq -r '.xPaddingHeader // empty' 2>/dev/null || true)"
  [[ -n "$header" ]] || header=X-Padding
  out="$(curl "${args[@]}" "https://$(check::_bracket "$sni"):$port${path%/}/test")" || rc=$?
  out="${out//$'\r'/}"
  if ((rc != 0)); then
    echo "FAIL|$(check::_curl_error "$rc")|"
    return 0
  fi
  ms="$(check::_ms "$(tail -n 1 <<<"$out")")"
  code="$(head -n 1 <<<"$out" | awk '{print $2}')"
  case "$code" in
    204) echo "OK|204|$ms" ;;
    400)
      if grep -qi "^$header:" <<<"$out"; then
        echo "OK|400 with $header|$ms"
      else
        echo "FAIL|400 without $header: not this xhttp inbound|$ms"
      fi
      ;;
    404) echo "FAIL|404: path or host differs from the inbound|$ms" ;;
    403) echo "FAIL|403: the CDN refuses the request|$ms" ;;
    451) echo "FAIL|451: legal block of the domain|$ms" ;;
    502 | 504) echo "FAIL|$code: the CDN cannot reach the origin|$ms" ;;
    503) echo "FAIL|503: overload or a disabled resource|$ms" ;;
    *) echo "FAIL|HTTP $code|$ms" ;;
  esac
}

# Reality and TLS servers: a finished handshake with the link's SNI is enough here. The
# HTTP request after it may fail, a proxy owes it no answer.
check::_probe_tls() {
  local addr="$1" port="$2" sni="$3" out rc=0
  out="$(curl -sk -o /dev/null -w '%{time_appconnect}' --max-time 10 \
    --connect-to "$(check::_bracket "$sni"):$port:$(check::_bracket "$addr"):$port" \
    "https://$(check::_bracket "$sni"):$port/")" || rc=$?
  if [[ "$out" =~ ^[0-9]+[.,][0-9]+$ && ! "$out" =~ ^0+[.,]0+$ ]]; then
    echo "OK|TLS handshake|$(check::_ms "$out")"
  else
    echo "FAIL|$(check::_curl_error "$rc")|"
  fi
}

check::_probe_tcp() {
  local start
  start="$(check::_now)"
  if check::_tcp_open "$1" "$2" 5; then
    echo "OK|TCP connect|$(check::_since "$start")"
  else
    echo "FAIL|no TCP connection|"
  fi
}

# Hysteria and TUIC run QUIC over UDP. A QUIC server answers a packet of an unknown
# version with version negotiation (RFC 9000 §6): one datagram shows it is up, no
# handshake needed.
check::_probe_quic() {
  local addr="$1" port="$2" reply rc=0 start
  start="$(check::_now)"
  # Long header, version 0x1a2a3a4a (reserved to force negotiation), two 8-byte
  # connection IDs, padded to the 1200 bytes a server wants before it answers.
  # shellcheck disable=SC2016  # $1 and $2 expand in the inner bash
  reply="$(timeout 3 bash -c '
    set -o pipefail
    exec 3<>"/dev/udp/$1/$2" || exit 2
    printf "\xc0\x1a\x2a\x3a\x4a\x08cdncheck\x08cdncheck%1177s" "" |
      dd bs=1200 count=1 iflag=fullblock status=none >&3
    dd bs=2048 count=1 status=none <&3 | od -An -tx1 -N 5 | tr -d " \n"
  ' _ "$addr" "$port" 2>/dev/null)" || rc=$?
  if [[ "$reply" =~ ^[89a-f][0-9a-f]00000000$ ]]; then
    echo "OK|QUIC answers|$(check::_since "$start")"
  elif ((rc == 124)); then
    echo "FAIL|no QUIC answer: UDP $port filtered or nothing listens|"
  elif ((rc == 2)); then
    echo "FAIL|cannot resolve $addr|"
  elif [[ -z "$reply" ]]; then
    echo "FAIL|UDP port $port closed|"
  else
    echo "FAIL|the UDP answer is not QUIC|"
  fi
}

check::_curl_error() {
  case "$1" in
    6) echo "DNS lookup failed" ;;
    7) echo "connection refused" ;;
    22) echo "HTTP error" ;;
    28) echo "timeout" ;;
    35) echo "TLS handshake failed" ;;
    52 | 56) echo "connection dropped" ;;
    60) echo "certificate not valid for the SNI" ;;
    *) echo "curl exit $1" ;;
  esac
}

# 0.0.0.0 is no server: it stands for this host, where a probe reaches local services.
check::_placeholder() {
  [[ "$1" == 0.0.0.0 || "$1" == :: ]]
}

# allowInsecure=1 or insecure=1 in the link: the server's certificate is not trusted.
check::_insecure() {
  local value
  for value in "$(check::_param "$1" allowInsecure)" "$(check::_param "$1" insecure)"; do
    if [[ "$value" == 1 || "${value,,}" == true ]]; then
      return 0
    fi
  done
  return 1
}

check::_bracket() {
  if [[ "$1" == *:* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}

# curl prints seconds as 0.123456; the table shows whole milliseconds.
check::_ms() {
  if [[ "${1/,/.}" =~ ^([0-9]+)\.([0-9]{3}) ]]; then
    echo $((10#${BASH_REMATCH[1]} * 1000 + 10#${BASH_REMATCH[2]}))
  fi
}

check::_now() {
  date +%s%N
}

check::_since() {
  echo $((($(date +%s%N) - $1) / 1000000))
}

# Real traffic: a local xray with this server as the outbound and a socks inbound, then
# CHECK_PROBE_URL through it. Prints STATUS|detail|ms like check::probe_fast.
check::probe_tunnel() {
  local proto addr port sni host path params name outbound dir socks pid out err uid
  IFS='|' read -r proto addr port sni host path params name <<<"$1"
  if check::_placeholder "$addr"; then
    echo "SKIP|$addr is a placeholder, not a server|"
    return 0
  fi
  if ! command -v "$CHECK_XRAY" >/dev/null 2>&1; then
    echo "SKIP|no xray: install it or set CHECK_XRAY|"
    return 0
  fi
  if ! outbound="$(check::_outbound "$1")"; then
    echo "SKIP|$outbound|"
    return 0
  fi
  dir="$(mktemp -d)"
  socks="$(check::_free_port)"
  jq -n --argjson ob "$outbound" --argjson port "$socks" '{log: {loglevel: "warning"},
    inbounds: [{listen: "127.0.0.1", port: $port, protocol: "socks", settings: {udp: false}}],
    outbounds: [$ob]}' >"$dir/config.json"
  # timeout ends xray even when this script dies first.
  timeout "$((CHECK_TIMEOUT + 10))" "$CHECK_XRAY" run -c "$dir/config.json" >"$dir/xray.log" 2>&1 &
  pid=$!
  if check::_wait_port "$socks" "$pid"; then
    out="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time "$CHECK_TIMEOUT" \
      --socks5-hostname "127.0.0.1:$socks" "$CHECK_PROBE_URL" || true)"
    case "${out%% *}" in
      204) echo "OK|204 through the tunnel|$(check::_ms "${out#* }")" ;;
      000 | "") echo "FAIL|no answer through the tunnel|" ;;
      *) echo "FAIL|HTTP ${out%% *} through the tunnel, not 204|" ;;
    esac
  else
    err="$(grep -m 1 -iE 'failed|error' "$dir/xray.log" | cut -c1-160 || true)"
    uid="$(check::_param "$params" uid)"
    if [[ -n "$uid" ]]; then
      err="${err//"$uid"/<hidden>}"
    fi
    echo "FAIL|xray did not start${err:+: ${err//|//}}|"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$dir"
}

# The xray outbound for a record, as JSON. Returns 1 with the reason on stdout when the
# checker cannot build one.
check::_outbound() {
  local proto addr port sni host path params name scheme encoded obfs pin security
  IFS='|' read -r proto addr port sni host path params name <<<"$1"
  encoded="$(check::_param "$params" outbound)"
  if [[ -n "$encoded" ]]; then
    if ! base64 -d 2>/dev/null <<<"$encoded" | jq -ce 'select(type == "object")' 2>/dev/null; then
      echo "the xray-json outbound is not valid JSON"
      return 1
    fi
    return 0
  fi
  scheme="${proto%%-*}"
  case "$scheme" in
    vless | vmess | trojan | shadowsocks | hysteria2) ;;
    *)
      echo "no tunnel support for $scheme"
      return 1
      ;;
  esac
  obfs="$(check::_param "$params" obfs)"
  if [[ -n "$obfs" && "$obfs" != salamander ]]; then
    echo "hysteria2 obfs $obfs is not supported"
    return 1
  fi
  pin="$(check::_param "$params" pinSHA256)"
  if [[ -z "$pin" ]] && check::_insecure "$params"; then
    if [[ "$scheme" == hysteria2 ]]; then
      echo "insecure hysteria2 needs pinSHA256 in the link: its certificate is not reachable over TCP"
      return 1
    fi
    # xray removed allowInsecure: pin the certificate the server presents instead.
    pin="$(check::_peer_cert_sha256 "$addr" "$port" "$sni")"
  fi
  security="$(check::_param "$params" security)"
  if [[ -z "$security" ]]; then
    security=none
    [[ "$scheme" != trojan ]] || security=tls
  fi
  jq -n --arg scheme "$scheme" --arg addr "$addr" --argjson port "$port" --arg sni "$sni" \
    --arg host "$host" --arg path "$path" --arg security "$security" --arg pin "$pin" \
    --arg uid "$(check::_param "$params" uid)" --arg method "$(check::_param "$params" method)" \
    --arg type "$(check::_param "$params" type)" --arg flow "$(check::_param "$params" flow)" \
    --arg fp "$(check::_param "$params" fp)" --arg alpn "$(check::_param "$params" alpn)" \
    --arg pbk "$(check::_param "$params" pbk)" --arg sid "$(check::_param "$params" sid)" \
    --arg spx "$(check::_param "$params" spx)" --arg mode "$(check::_param "$params" mode)" \
    --arg extra "$(check::_param "$params" extra)" --arg service "$(check::_param "$params" serviceName)" \
    --arg encryption "$(check::_param "$params" encryption)" --arg obfs "$obfs" \
    --arg obfs_password "$(check::_param "$params" obfs-password)" '
    def nonempty: with_entries(select(.value != "" and .value != null and .value != []));
    ($type | if . == "" or . == "raw" then "tcp" else . end) as $net
    | ({serverName: $sni, fingerprint: $fp, alpn: ($alpn | split(",") | map(select(. != ""))),
        pinnedPeerCertSha256: $pin} | nonempty) as $tls
    | if $scheme == "hysteria2" then
        {protocol: "hysteria", settings: {version: 2, address: $addr, port: $port},
         streamSettings: ({network: "hysteria", security: "tls", tlsSettings: $tls,
             hysteriaSettings: {version: 2, auth: $uid}}
           + if $obfs == "" then {}
             else {finalmask: {udp: [{type: $obfs, settings: {password: $obfs_password}}]}} end)}
      else
        {protocol: $scheme,
         settings: (if $scheme == "trojan" then {servers: [{address: $addr, port: $port, password: $uid}]}
           elif $scheme == "shadowsocks" then
             {servers: [{address: $addr, port: $port, method: $method, password: $uid}]}
           else {vnext: [{address: $addr, port: $port, users: [({id: $uid, flow: $flow,
             encryption: (if $scheme == "vless" then ($encryption | if . == "" then "none" else . end)
               else "" end), security: (if $scheme == "vmess" then "auto" else "" end)} | nonempty)]}]} end),
         streamSettings: ({network: $net, security: $security}
           + (if $security == "tls" then {tlsSettings: $tls}
              elif $security == "reality" then {realitySettings: ({serverName: $sni,
                fingerprint: ($fp | if . == "" then "chrome" else . end), publicKey: $pbk, shortId: $sid,
                spiderX: $spx} | nonempty)}
              else {} end)
           + (if $net == "xhttp" then {xhttpSettings: ({host: $host, path: $path,
                mode: ($mode | if . == "" then "auto" else . end),
                extra: ($extra | if . == "" then null else (try fromjson catch null) end)} | nonempty)}
              elif $net == "ws" then {wsSettings: ({path: $path, host: $host} | nonempty)}
              elif $net == "httpupgrade" then {httpupgradeSettings: ({path: $path, host: $host} | nonempty)}
              elif $net == "grpc" then {grpcSettings: ({serviceName: $service} | nonempty)}
              else {} end))}
      end'
}

check::_peer_cert_sha256() {
  timeout 10 openssl s_client -connect "$(check::_bracket "$1"):$2" -servername "$3" </dev/null 2>/dev/null |
    openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' || true
}

check::_free_port() {
  local port
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    port=$((20000 + RANDOM % 20000))
    if ! check::_listening "$port"; then
      break
    fi
  done
  echo "$port"
}

check::_listening() {
  check::_tcp_open 127.0.0.1 "$1" 1
}

# Opens a TCP connection to HOST PORT within SECONDS. The inner bash gets the address as
# arguments, so a subscription cannot inject shell code.
check::_tcp_open() {
  # shellcheck disable=SC2016  # $1 and $2 expand in the inner bash
  timeout "$3" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2>/dev/null
}

# Waits up to 5 s for PORT to listen; gives up early when process PID is gone.
check::_wait_port() {
  local i
  for ((i = 0; i < 50; i++)); do
    if check::_listening "$1"; then
      return 0
    fi
    if ! kill -0 "$2" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
  done
  return 1
}

# --- report -----------------------------------------------------------------------------

# Reads name|proto|endpoint|fast|tunnel lines, fast and tunnel being STATUS|detail|ms
# each. Prints the table to stdout, returns 1 when any server fails. The tunnel verdict
# wins when there is one: an L7 answer does not prove that traffic flows.
check::report() {
  local name proto endpoint fast fast_detail fast_ms tunnel tunnel_detail tunnel_ms result ms
  local failed=0 fmt="%s %-22.22s %-32.32s %-6s %8s  %s\n"
  # shellcheck disable=SC2059  # the format is the constant above
  printf "$fmt" "$(check::_cell NAME 28)" PROTO ENDPOINT RESULT LATENCY DETAIL
  while IFS='|' read -r name proto endpoint fast fast_detail fast_ms tunnel tunnel_detail tunnel_ms; do
    if [[ "$tunnel" == OK || "$tunnel" == FAIL ]]; then
      result="$tunnel" ms="$tunnel_ms"
    else
      result="$fast" ms="$fast_ms"
    fi
    if [[ "$result" == FAIL ]]; then
      failed=1
    fi
    # shellcheck disable=SC2059  # the format is the constant above
    printf "$fmt" "$(check::_cell "${name:-?}" 28)" "$proto" "$endpoint" "$result" "${ms:+$ms ms}" \
      "fast: $fast_detail; tunnel: $tunnel_detail"
  done
  return "$failed"
}

# TEXT cut or padded to WIDTH characters. printf counts bytes, and server names are often
# Cyrillic with emoji flags: it would cut them inside a character.
check::_cell() {
  local LC_ALL=C.UTF-8 text
  text="${1:0:$2}"
  printf '%s%*s' "$text" "$(($2 - ${#text}))" ''
}

# --- main -------------------------------------------------------------------------------

check::main() {
  local url="" tunnels=1 arg subscription rec proto addr port endpoint fast tunnel rows="" rc=0 i=0
  local -a records=()
  for arg in "$@"; do
    case "$arg" in
      --fast) tunnels=0 ;;
      -h | --help)
        check::usage
        exit 0
        ;;
      -*) log::die "$EXIT_INPUT" "unknown option: $arg. See ./check.sh --help" ;;
      *) url="$arg" ;;
    esac
  done
  [[ -n "$url" ]] || log::die "$EXIT_INPUT" "no subscription URL. Usage: ./check.sh [--fast] <subscription-url>"
  require::cmd curl jq base64 openssl timeout dd od
  subscription="$(check::fetch "$url")" || exit
  if [[ -n "$subscription" ]]; then
    mapfile -t records <<<"$subscription"
  fi
  ((${#records[@]} > 0)) || log::die "$EXIT_FAILURE" "the subscription lists no servers"
  log::info "checking ${#records[@]} servers$( ((tunnels)) || echo ', L7 probes only')"
  for rec in "${records[@]}"; do
    i=$((i + 1))
    IFS='|' read -r proto addr port _ <<<"$rec"
    endpoint="$(check::_bracket "$addr"):$port"
    log::info "[$i/${#records[@]}] ${rec##*|}: $proto $endpoint"
    fast="$(check::probe_fast "$rec")"
    tunnel="SKIP|--fast|"
    if ((tunnels)); then
      tunnel="$(check::probe_tunnel "$rec")"
    fi
    rows+="${rec##*|}|$proto|$endpoint|$fast|$tunnel"$'\n'
  done
  printf '%s' "$rows" | check::report || rc=$?
  exit "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # set -e alone exits without a word; name the command that failed.
  trap 'log::error "unexpected failure (exit $?) at ${BASH_SOURCE[0]##*/}:$LINENO: $BASH_COMMAND"' ERR
  check::main "$@"
fi
