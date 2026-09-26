#!/usr/bin/env bats
# Contract tests for check.sh (tech.md §5, §7): the subscription parser against fixtures,
# the L7 and tunnel tiers, the table and the exit code. curl, timeout, openssl and xray are
# stubs; each kind of request gets its answer from $TMP/resp/<kind>: line 1 is the exit
# code, the rest the output.

setup() {
  # bats 1.2 on Ubuntu 22.04 has no BATS_TEST_TMPDIR.
  TMP="$(mktemp -d)"
  REPO="$TMP/repo"
  FIX="$BATS_TEST_DIRNAME/fixtures"
  mkdir -p "$REPO" "$TMP/bin" "$TMP/resp" "$TMP/open" "$TMP/tmp"
  cp -R "$BATS_TEST_DIRNAME/../lib" "$BATS_TEST_DIRNAME/../check.sh" "$REPO/"
  export STUB_DIR="$TMP" REAL_TIMEOUT
  REAL_TIMEOUT="$(command -v timeout)"
  stubs
  PATH="$TMP/bin:$PATH"
  # check::probe_tunnel keeps its xray config under TMPDIR.
  export TMPDIR="$TMP/tmp"
  # shellcheck source=../check.sh
  source "$REPO/check.sh"
  CDN="$(sed -n 1p "$FIX/sub-links.records")"
  REALITY="$(sed -n 2p "$FIX/sub-links.records")"
  HY2="$(sed -n 3p "$FIX/sub-links.records")"
  HY2_V6="$(sed -n 4p "$FIX/sub-links.records")"
  TROJAN="$(sed -n 5p "$FIX/sub-links.records")"
  SS="$(sed -n 6p "$FIX/sub-links.records")"
  VMESS="$(sed -n 7p "$FIX/sub-links.records")"
}

teardown() {
  rm -rf "${TMP:?}"
}

# respond KIND EXIT [LINE...]: what the stubs answer to that kind of request.
respond() {
  local kind="$1" code="$2"
  shift 2
  {
    echo "$code"
    printf '%s\n' "$@"
  } >"$TMP/resp/$kind"
}

# serve FILE: the subscription the panel answers with.
serve() {
  {
    echo 0
    cat "$1"
  } >"$TMP/resp/sub"
}

# stub NAME: installs stdin as the script $TMP/bin/NAME.
stub() {
  {
    echo '#!/bin/sh'
    cat
  } >"$TMP/bin/$1"
  chmod +x "$TMP/bin/$1"
}

stubs() {
  stub curl <<'EOF'
printf '%s\n' "$(printf 'curl %s' "$*" | tr '\n' ' ')" >>"$STUB_DIR/calls"
case "$*" in
  *" -A "*)
    kind=sub
    # The panel's response headers go to the -D file: $STUB_DIR/resp/sub-headers.
    while [ $# -gt 1 ]; do
      if [ "$1" = -D ]; then
        cat "$STUB_DIR/resp/sub-headers" >"$2" 2>/dev/null || true
      fi
      shift
    done
    ;;
  *--socks5-hostname*) kind=tunnel ;;
  *time_appconnect*) kind=tls ;;
  *" -D - "*) kind=xhttp ;;
  *) echo "curl stub: unexpected call: $*" >&2; exit 99 ;;
esac
[ -f "$STUB_DIR/resp/$kind" ] || exit 7
tail -n +2 "$STUB_DIR/resp/$kind"
exit "$(head -n 1 "$STUB_DIR/resp/$kind")"
EOF
  # TCP probes answer from $TMP/open/<host>-<port>, UDP probes from resp/quic; any other
  # command runs. real-timeout hands everything to the real timeout.
  stub timeout <<'EOF'
printf '%s\n' "$(printf 'timeout %s' "$*" | tr '\n' ' ')" >>"$STUB_DIR/calls"
[ -e "$STUB_DIR/real-timeout" ] && exec "$REAL_TIMEOUT" "$@"
case "$4" in
  *"/dev/tcp/"*) [ -e "$STUB_DIR/open/$6-$7" ]; exit ;;
  *"/dev/udp/"*)
    [ -f "$STUB_DIR/resp/quic" ] || exit 124
    tail -n +2 "$STUB_DIR/resp/quic"
    exit "$(head -n 1 "$STUB_DIR/resp/quic")"
    ;;
esac
shift
exec "$@"
EOF
  stub openssl <<'EOF'
printf 'openssl %s\n' "$*" >>"$STUB_DIR/calls"
case "$1" in
  s_client) echo "-----BEGIN CERTIFICATE-----" ;;
  x509) cat >/dev/null; echo "sha256 Fingerprint=AB:CD:EF" ;;
esac
EOF
  # xray run -c CONFIG: keeps the config, opens the socks port and stays up; xray-fails
  # holds the error of a config it refuses.
  stub xray <<'EOF'
exec 3>&-
printf 'xray %s\n' "$*" >>"$STUB_DIR/calls"
cp "$3" "$STUB_DIR/xray-config.json"
if [ -f "$STUB_DIR/xray-fails" ]; then
  cat "$STUB_DIR/xray-fails" >&2
  exit 23
fi
touch "$STUB_DIR/open/127.0.0.1-$(jq -r '.inbounds[0].port' "$3")"
echo $$ >"$STUB_DIR/xray-pid"
exec sleep 30
EOF
}

# Counts logged calls that match the pattern; 0 when nothing ran at all.
calls() {
  if [[ -f "$TMP/calls" ]]; then
    grep -c -- "$1" "$TMP/calls" || true
  else
    echo 0
  fi
}

# fresh [VAR=value...] FUNCTION [ARG...]: runs a function of check.sh in a fresh bash, so
# that the CHECK_* settings take effect.
fresh() {
  local -a vars=()
  while [[ "$1" == *=* ]]; do
    vars+=("$1")
    shift
  done
  # shellcheck disable=SC2016  # $1 and $@ expand in the inner bash
  run env "${vars[@]}" bash -c 'source "$1" && shift && "$@"' _ "$REPO/check.sh" "$@"
}

# --- parser ---------------------------------------------------------------------------

@test "base64 share links, as Remnawave serves them, give one record per server" {
  run check::parse "$(cat "$FIX/sub-base64.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$FIX/sub-links.records")" ]
}

@test "a plain list of links parses the same, CRLF, blank and junk lines aside" {
  run check::parse "$(cat "$FIX/sub-links.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$FIX/sub-links.records")" ]
}

@test "sing-box JSON gives every outbound with a server, not selector, direct, block or dns" {
  run check::parse "$(cat "$FIX/sub-singbox.json")"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$FIX/sub-singbox.records")" ]
}

@test "xray-json gives one server per config and carries its outbound as it is" {
  local rec i=0
  run check::parse "$(cat "$FIX/sub-xray.json")"
  [ "$status" -eq 0 ]
  [ "$(sed -E 's/outbound=[^|&]*/outbound=<base64>/' <<<"$output")" = "$(cat "$FIX/sub-xray.records")" ]
  while IFS= read -r rec; do
    [ "$(check::_outbound "$rec" | jq -S .)" = "$(jq -S ".[$i].outbounds[0]" "$FIX/sub-xray.json")" ]
    i=$((i + 1))
  done <<<"$output"
  [ "$i" -eq 2 ]
}

@test "xray-json passes over xray's own outbounds to the one that leaves the host" {
  run check::parse '{"remarks": "T", "outbounds": [{"protocol": "freedom", "tag": "direct"},
    {"protocol": "trojan", "settings": {"servers": [{"address": "t.example.com", "port": 443, "password": "pw"}]},
     "streamSettings": {"network": "raw", "security": "tls", "tlsSettings": {"serverName": "t.example.com"}}}]}'
  [ "$status" -eq 0 ]
  [ "$(sed -E 's/outbound=[^|&]*/outbound=<base64>/' <<<"$output")" = \
    'trojan-tcp-tls|t.example.com|443|t.example.com|t.example.com||uid=pw&type=tcp&security=tls&outbound=<base64>|T' ]
}

@test "fetch asks as a v2ray client and parses the answer" {
  serve "$FIX/sub-base64.txt"
  run check::fetch https://panel.example.com/api/sub/5qJcKxWbT
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$FIX/sub-links.records")" ]
  [ "$(calls ' -A v2rayNG/1.10.5 https://panel.example.com/api/sub/5qJcKxWbT$')" -eq 1 ]
}

@test "fetch comes as one device per machine, and without x-hwid when CHECK_HWID is empty" {
  local first
  serve "$FIX/sub-base64.txt"
  run check::fetch https://panel.example.com/api/sub/5qJcKxWbT
  [ "$status" -eq 0 ]
  first="$(grep -o 'x-hwid: cdn-deploy-[0-9a-f]*' "$TMP/calls")"
  [[ "$first" =~ ^x-hwid:\ cdn-deploy-[0-9a-f]{24}$ ]]
  grep -q 'x-device-model: cdn-deploy check.sh' "$TMP/calls"
  run check::fetch https://panel.example.com/api/sub/5qJcKxWbT
  [ "$(grep -o 'x-hwid: cdn-deploy-[0-9a-f]*' "$TMP/calls" | sort -u)" = "$first" ]
  : >"$TMP/calls"
  CHECK_HWID="" run check::fetch https://panel.example.com/api/sub/5qJcKxWbT
  [ "$status" -eq 0 ]
  run grep -c x-hwid "$TMP/calls"
  [ "$output" -eq 0 ]
}

@test "placeholders for a missing device id or a full device limit exit 1 with the cause" {
  serve "$FIX/sub-base64.txt"
  printf 'HTTP/1.1 200 OK\r\nx-hwid-limit: true\r\nx-hwid-max-devices-reached: true\r\n\r\n' \
    >"$TMP/resp/sub-headers"
  run check::fetch https://panel.example.com/api/sub/x
  [ "$status" -eq 1 ]
  [[ "$output" == *"the user of this subscription has no free device for the checker (x-hwid cdn-deploy-"* ]]
  printf 'HTTP/1.1 200 OK\r\nx-hwid-not-supported: true\r\n\r\n' >"$TMP/resp/sub-headers"
  CHECK_HWID="" run check::fetch https://panel.example.com/api/sub/x
  [ "$status" -eq 1 ]
  [[ "$output" == *"has a device limit, and the request carried no valid x-hwid"* ]]
}

@test "a failed fetch, a web page or a body without links exits 1 with the cause" {
  respond sub 22
  run check::fetch https://panel.example.com/api/sub/x
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot fetch the subscription: HTTP error"* ]]
  respond sub 0 '<!DOCTYPE html>' '<html><a href="https://example.com/">x</a></html>'
  run check::fetch https://panel.example.com/api/sub/x
  [ "$status" -eq 1 ]
  [[ "$output" == *"the subscription URL returned a web page"* ]]
  respond sub 0 'Subscription expired'
  run check::fetch https://panel.example.com/api/sub/x
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds no share links"* ]]
  respond sub 0 '{"servers": []}'
  run check::fetch https://panel.example.com/api/sub/x
  [ "$status" -eq 1 ]
  [[ "$output" == *"neither sing-box nor xray-json"* ]]
}

@test "shadowsocks links: base64 or plain userinfo, and the old whole-link base64" {
  local legacy
  legacy="$(printf 'aes-128-gcm:ss-pass@ss.example.com:8388' | base64)"
  run check::parse "$(printf '%s\n' \
    'ss://YWVzLTEyOC1nY206c3MtcGFzcw@ss.example.com:8388#SIP002' \
    'ss://2022-blake3-aes-128-gcm:a2V5a2V5a2V5a2V5a2V5a2V5%3D%3D@ss.example.com:8388#SS 2022' \
    "ss://$legacy#Legacy")"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'shadowsocks-tcp-none|ss.example.com|8388|ss.example.com|ss.example.com||uid=ss-pass&method=aes-128-gcm|SIP002' ]
  [ "${lines[1]}" = 'shadowsocks-tcp-none|ss.example.com|8388|ss.example.com|ss.example.com||uid=a2V5a2V5a2V5a2V5a2V5a2V5%3D%3D&method=2022-blake3-aes-128-gcm|SS 2022' ]
  [ "${lines[2]}" = 'shadowsocks-tcp-none|ss.example.com|8388|ss.example.com|ss.example.com||uid=ss-pass&method=aes-128-gcm|Legacy' ]
}

@test "a vmess link with empty net, tls, sni and host falls back to tcp, none and the address" {
  local json
  json='{"v":"2","ps":"VM","add":"vm.example.com","port":8080,"id":"5b0f5e6a-1c2d-4e3f-8a9b-0c1d2e3f4a5b","net":"","tls":"","sni":"","host":""}'
  run check::parse "vmess://$(printf '%s' "$json" | base64 | tr -d '\n')"
  [ "$status" -eq 0 ]
  [ "$output" = 'vmess-tcp-none|vm.example.com|8080|vm.example.com|vm.example.com||uid=5b0f5e6a-1c2d-4e3f-8a9b-0c1d2e3f4a5b&type=tcp&security=none|VM' ]
}

@test "links without a usable host or port are left out with a warning" {
  run check::parse "$(printf '%s\n' \
    'vless://3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f@:443?security=tls#No host' \
    'vless://3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f@bad.example.com:99999?security=tls#Bad port' \
    'trojan://trojan-pass@t.example.com#Default port')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped a vless link without a valid host and port: No host"* ]]
  [[ "$output" == *"skipped a vless link without a valid host and port: Bad port"* ]]
  [[ "$output" != *3f1c2d4e* ]]
  [ "${lines[2]}" = 'trojan-tcp-tls|t.example.com|443|t.example.com|t.example.com||uid=trojan-pass|Default port' ]
}

@test "names lose the record separator and control characters" {
  run check::parse 'trojan://trojan-pass@t.example.com:443#%1B%5B31mred%7Cname%07'
  [ "$status" -eq 0 ]
  [ "$output" = 'trojan-tcp-tls|t.example.com|443|t.example.com|t.example.com||uid=trojan-pass|[31mred/name' ]
}

# --- L7 tier --------------------------------------------------------------------------

@test "xhttp: 400 with the padding header named in the link is OK, asked on its path" {
  respond xhttp 0 'HTTP/2 400' 'x-cache: 7f3ad02m' '' '0.052000'
  run check::probe_fast "$CDN"
  [ "$status" -eq 0 ]
  [ "$output" = 'OK|400 with X-Cache|52' ]
  [ "$(calls '-H Host: cdn.example.com --connect-to cdn.example.com:443:cdn.example.com:443 https://cdn.example.com:443/api/v2.jpg/test$')" -eq 1 ]
  [ "$(calls ' -k ')" -eq 0 ]
}

@test "xhttp: each answer names the broken part" {
  local case code want
  for case in "204|OK|204|" "400|FAIL|400 without X-Cache: not this xhttp inbound|" \
    "404|FAIL|404: path or host differs from the inbound|" "403|FAIL|403: the CDN refuses the request|" \
    "451|FAIL|451: legal block of the domain|" "502|FAIL|502: the CDN cannot reach the origin|" \
    "504|FAIL|504: the CDN cannot reach the origin|" "503|FAIL|503: overload or a disabled resource|" \
    "418|FAIL|HTTP 418|"; do
    code="${case%%|*}"
    want="${case#*|}"
    respond xhttp 0 "HTTP/1.1 $code Status" '' '0.020000'
    run check::probe_fast "$CDN"
    [ "$output" = "${want}20" ] || {
      echo "$code: $output"
      return 1
    }
  done
}

@test "xhttp: curl failures name the cause, insecure links skip certificate checks" {
  local case
  for case in "6|DNS lookup failed" "7|connection refused" "28|timeout" "35|TLS handshake failed" \
    "60|certificate not valid for the SNI"; do
    respond xhttp "${case%%|*}"
    run check::probe_fast "$CDN"
    [ "$output" = "FAIL|${case#*|}|" ] || {
      echo "$case: $output"
      return 1
    }
  done
  respond xhttp 0 'HTTP/2 400' 'X-Cache: x' '' '0.020000'
  run check::probe_fast "${CDN%|*}&allowInsecure=1|${CDN##*|}"
  [ "$output" = 'OK|400 with X-Cache|20' ]
  [ "$(calls ' -k ')" -eq 1 ]
}

@test "xhttp: without a padding header in the link, X-Padding is expected" {
  respond xhttp 0 'HTTP/2 400' 'X-Padding: 0000' '' '0.020000'
  run check::probe_fast 'vless-xhttp-tls|203.0.113.10|8444|vless.example.com|vless.example.com|/xh/|uid=x&type=xhttp&security=tls|Direct xhttp'
  [ "$output" = 'OK|400 with X-Padding|20' ]
  [ "$(calls '--connect-to vless.example.com:8444:203.0.113.10:8444 https://vless.example.com:8444/xh/test$')" -eq 1 ]
}

@test "reality and TLS: a finished handshake is OK, even when no HTTP answer follows" {
  respond tls 52 '0.031000'
  run check::probe_fast "$REALITY"
  [ "$output" = 'OK|TLS handshake|31' ]
  [ "$(calls '^curl -sk .*--connect-to www.swiss.com:443:203.0.113.10:443 https://www.swiss.com:443/$')" -eq 1 ]
  respond tls 35 '0.000000'
  run check::probe_fast "$REALITY"
  [ "$output" = 'FAIL|TLS handshake failed|' ]
  respond tls 7 '0.000000'
  run check::probe_fast "$TROJAN"
  [ "$output" = 'FAIL|connection refused|' ]
}

@test "servers without TLS get a TCP connect" {
  touch "$TMP/open/ss.example.com-8388"
  run check::probe_fast "$SS"
  [[ "$output" =~ ^OK\|TCP\ connect\|[0-9]+$ ]]
  rm "$TMP/open/ss.example.com-8388"
  run check::probe_fast "$SS"
  [ "$output" = 'FAIL|no TCP connection|' ]
}

@test "hysteria2: a version negotiation answer is OK, silence or a closed port fail" {
  respond quic 0 'c300000000'
  run check::probe_fast "$HY2"
  [[ "$output" =~ ^OK\|QUIC\ answers\|[0-9]+$ ]]
  [ "$(calls '/dev/udp/.* _ hy2.example.com 443$')" -eq 1 ]
  respond quic 124
  run check::probe_fast "$HY2_V6"
  [ "$output" = 'FAIL|no QUIC answer: UDP 8443 filtered or nothing listens|' ]
  [ "$(calls '/dev/udp/.* _ 2001:db8::10 8443$')" -eq 1 ]
  respond quic 1
  run check::probe_fast "$HY2"
  [ "$output" = 'FAIL|UDP port 443 closed|' ]
  respond quic 0 '4854545020'
  run check::probe_fast "$HY2"
  [ "$output" = 'FAIL|the UDP answer is not QUIC|' ]
}

@test "hysteria2 with salamander leaves the verdict to the tunnel" {
  run check::probe_fast "$(sed -n 2p "$FIX/sub-singbox.records")"
  [ "$output" = 'SKIP|obfuscated QUIC, only the tunnel tells|' ]
  [ "$(calls .)" -eq 0 ]
}

@test "a server the checker has no probe for is listed with the reason" {
  run check::parse 'socks://dXNlcjpwYXNz@s.example.com:1080#Socks'
  [ "$output" = 'socks-tcp-none|s.example.com|1080|s.example.com|s.example.com||uid=dXNlcjpwYXNz|Socks' ]
  run check::probe_fast "$output"
  [ "$output" = 'SKIP|no probe for socks|' ]
  [ "$(calls .)" -eq 0 ]
}

@test "TUIC gets the QUIC probe, the tunnel says it has no support" {
  local tuic
  tuic="$(sed -n 4p "$FIX/sub-singbox.records")"
  respond quic 0 'c300000000'
  run check::probe_fast "$tuic"
  [[ "$output" =~ ^OK\|QUIC\ answers\|[0-9]+$ ]]
  [ "$(calls '/dev/udp/.* _ tuic.example.com 443$')" -eq 1 ]
  run check::probe_tunnel "$tuic"
  [ "$output" = 'SKIP|no tunnel support for tuic|' ]
}

@test "a placeholder address is not probed by either tier" {
  run check::probe_fast "${REALITY/203.0.113.10/0.0.0.0}"
  [ "$output" = 'SKIP|0.0.0.0 is a placeholder, not a server|' ]
  run check::probe_tunnel "${REALITY/203.0.113.10/0.0.0.0}"
  [ "$output" = 'SKIP|0.0.0.0 is a placeholder, not a server|' ]
  [ "$(calls .)" -eq 0 ]
}

@test "an address from the subscription runs no shell code in the probes" {
  local evil="\$(touch $TMP/pwned)"
  touch "$TMP/real-timeout"
  run check::probe_fast "shadowsocks-tcp-none|$evil|8388|x|x||uid=x&method=aes-128-gcm|Evil"
  [ "$output" = 'FAIL|no TCP connection|' ]
  run check::probe_fast "hysteria2|$evil|443|x|x||uid=x|Evil"
  [[ "$output" == FAIL* ]]
  [ ! -e "$TMP/pwned" ]
}

# --- outbounds ------------------------------------------------------------------------

@test "vless xhttp: the outbound carries host, path, mode and extra behind TLS" {
  run check::_outbound "$CDN"
  [ "$status" -eq 0 ]
  jq -e '.protocol == "vless"
    and .settings.vnext[0] == {address: "cdn.example.com", port: 443,
      users: [{id: "3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f", encryption: "none"}]}
    and .streamSettings.network == "xhttp" and .streamSettings.security == "tls"
    and .streamSettings.tlsSettings == {serverName: "cdn.example.com", fingerprint: "chrome"}
    and .streamSettings.xhttpSettings == {host: "cdn.example.com", path: "/api/v2.jpg/", mode: "packet-up",
      extra: {xPaddingHeader: "X-Cache", xmux: {hKeepAlivePeriod: 15}}}' <<<"$output"
}

@test "reality: the outbound carries publicKey, shortId, flow and the fingerprint" {
  run check::_outbound "$REALITY"
  [ "$status" -eq 0 ]
  jq -e '.settings.vnext[0].users == [{id: "3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f",
      flow: "xtls-rprx-vision", encryption: "none"}]
    and .streamSettings == {network: "tcp", security: "reality", realitySettings: {serverName: "www.swiss.com",
      fingerprint: "chrome", publicKey: "Jx5cZ4XH3ncnbvvS4Ov9kA0OmvpEr7X3SqJ3Hkdhc2c", shortId: "6ba85179e30d4fc2"}}' \
    <<<"$output"
  run check::_outbound "${REALITY/fp=chrome/fp=}"
  jq -e '.streamSettings.realitySettings.fingerprint == "chrome"' <<<"$output"
  run check::_outbound "${REALITY/encryption=none/encryption=}"
  jq -e '.settings.vnext[0].users[0].encryption == "none"' <<<"$output"
}

@test "trojan ws, vmess ws and shadowsocks get their own settings" {
  run check::_outbound "$TROJAN"
  jq -e '.protocol == "trojan" and .settings.servers == [{address: "ws.example.com", port: 443, password: "trojan-pass"}]
    and .streamSettings.wsSettings == {path: "/ws", host: "ws.example.com"}
    and .streamSettings.tlsSettings.serverName == "ws.example.com"' <<<"$output"
  run check::_outbound "$VMESS"
  jq -e '.protocol == "vmess"
    and .settings.vnext[0].users == [{id: "5b0f5e6a-1c2d-4e3f-8a9b-0c1d2e3f4a5b", security: "auto"}]
    and .streamSettings.wsSettings == {path: "/vm", host: "vm.example.com"}' <<<"$output"
  run check::_outbound 'trojan-tcp-tls|t.example.com|443|t.example.com|t.example.com||uid=pw|T'
  jq -e '.streamSettings == {network: "tcp", security: "tls", tlsSettings: {serverName: "t.example.com"}}' <<<"$output"
  run check::_outbound "$SS"
  jq -e '.protocol == "shadowsocks"
    and .settings.servers == [{address: "ss.example.com", port: 8388, method: "aes-128-gcm", password: "ss-pass"}]
    and .streamSettings == {network: "tcp", security: "none"}' <<<"$output"
}

@test "hysteria2: auth and SNI, salamander as a finalmask" {
  run check::_outbound "$HY2"
  [ "$status" -eq 0 ]
  jq -e '. == {protocol: "hysteria", settings: {version: 2, address: "hy2.example.com", port: 443},
    streamSettings: {network: "hysteria", security: "tls", tlsSettings: {serverName: "hy2.example.com"},
      hysteriaSettings: {version: 2, auth: "s3cr3t+pass"}}}' <<<"$output"
  run check::_outbound "$(sed -n 2p "$FIX/sub-singbox.records")"
  [ "$status" -eq 0 ]
  jq -e '.streamSettings.finalmask == {udp: [{type: "salamander", settings: {password: "obfs-pass"}}]}
    and .streamSettings.tlsSettings.alpn == ["h3"]' <<<"$output"
}

@test "an insecure link pins the certificate the server presents" {
  run check::_outbound "$(sed -n 3p "$FIX/sub-singbox.records")"
  [ "$status" -eq 0 ]
  jq -e '.streamSettings.tlsSettings == {serverName: "ws.example.com", pinnedPeerCertSha256: "AB:CD:EF"}' <<<"$output"
  [ "$(calls '^openssl s_client -connect ws.example.com:443 -servername ws.example.com$')" -eq 1 ]
}

@test "insecure hysteria2 needs pinSHA256 in the link, and then uses it" {
  run check::_outbound 'hysteria2|hy2.example.com|443|hy2.example.com|hy2.example.com||uid=pw&insecure=1|H'
  [ "$status" -eq 1 ]
  [ "$output" = "insecure hysteria2 needs pinSHA256 in the link: its certificate is not reachable over TCP" ]
  run check::_outbound 'hysteria2|hy2.example.com|443|hy2.example.com|hy2.example.com||uid=pw&insecure=1&pinSHA256=ab%3Acd|H'
  [ "$status" -eq 0 ]
  jq -e '.streamSettings.tlsSettings.pinnedPeerCertSha256 == "ab:cd"' <<<"$output"
  [ "$(calls openssl)" -eq 0 ]
}

@test "servers the checker cannot tunnel get the reason" {
  run check::_outbound 'tuic-tcp-none|t.example.com|443|t.example.com|t.example.com||uid=x|T'
  [ "$status" -eq 1 ]
  [ "$output" = "no tunnel support for tuic" ]
  run check::_outbound 'hysteria2|h.example.com|443|h.example.com|h.example.com||uid=x&obfs=gfw|H'
  [ "$status" -eq 1 ]
  [ "$output" = "hysteria2 obfs gfw is not supported" ]
  run check::_outbound 'vless-tcp-tls|h.example.com|443|h|h||uid=x&outbound=bm90IGpzb24%3D|H'
  [ "$status" -eq 1 ]
  [ "$output" = "the xray-json outbound is not valid JSON" ]
}

# --- tunnel tier ----------------------------------------------------------------------

@test "the tunnel puts the server behind a loopback socks port of xray, 204 is OK" {
  respond tunnel 0 '204 0.140000'
  run check::probe_tunnel "$REALITY"
  [ "$status" -eq 0 ]
  [ "$output" = 'OK|204 through the tunnel|140' ]
  jq -e '.inbounds == [{listen: "127.0.0.1", port: .inbounds[0].port, protocol: "socks", settings: {udp: false}}]
    and (.outbounds | length) == 1' "$TMP/xray-config.json"
  [ "$(jq -S '.outbounds[0]' "$TMP/xray-config.json")" = "$(check::_outbound "$REALITY" | jq -S .)" ]
  [ "$(calls "--socks5-hostname 127.0.0.1:$(jq '.inbounds[0].port' "$TMP/xray-config.json") http://www.gstatic.com/generate_204$")" -eq 1 ]
  [ "$(calls '^timeout 25 xray run -c ')" -eq 1 ]
}

@test "CHECK_PROBE_URL and CHECK_XRAY replace the probe URL and the xray binary" {
  respond tunnel 0 '204 0.010000'
  cp "$TMP/bin/xray" "$TMP/bin/xray-custom"
  fresh CHECK_PROBE_URL=http://probe.example.test/generate_204 CHECK_XRAY=xray-custom check::probe_tunnel "$SS"
  [ "$output" = 'OK|204 through the tunnel|10' ]
  [ "$(calls 'http://probe.example.test/generate_204$')" -eq 1 ]
  [ "$(calls '^xray run -c ')" -eq 1 ]
  fresh CHECK_XRAY=no-such-xray check::probe_tunnel "$SS"
  [ "$output" = 'SKIP|no xray: install it or set CHECK_XRAY|' ]
}

@test "a tunnel without the 204 fails" {
  respond tunnel 0 '000 0.000000'
  run check::probe_tunnel "$TROJAN"
  [ "$output" = 'FAIL|no answer through the tunnel|' ]
  respond tunnel 0 '200 0.100000'
  run check::probe_tunnel "$TROJAN"
  [ "$output" = 'FAIL|HTTP 200 through the tunnel, not 204|' ]
}

@test "xray that refuses the config fails at once, its error shown without the credential" {
  echo 'Failed to start: invalid user id 3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f in outbound' >"$TMP/xray-fails"
  SECONDS=0
  run check::probe_tunnel "$CDN"
  [ "$output" = 'FAIL|xray did not start: Failed to start: invalid user id <hidden> in outbound|' ]
  [ "$SECONDS" -lt 4 ]
}

@test "a tunnel leaves no xray and no files behind" {
  respond tunnel 0 '204 0.010000'
  SECONDS=0
  run check::probe_tunnel "$VMESS"
  [ "$output" = 'OK|204 through the tunnel|10' ]
  [ "$SECONDS" -lt 10 ]
  run kill -0 "$(cat "$TMP/xray-pid")"
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$TMP/tmp")" ]
}

@test "a server the checker cannot tunnel is skipped with the reason" {
  run check::probe_tunnel 'tuic-tcp-none|t.example.com|443|t.example.com|t.example.com||uid=x|T'
  [ "$output" = 'SKIP|no tunnel support for tuic|' ]
  [ "$(calls xray)" -eq 0 ]
}

# --- report and main ------------------------------------------------------------------

@test "the report has a row per server, the tunnel verdict wins, any FAIL gives exit 1" {
  run check::report <<'EOF'
CDN|vless-xhttp-tls|cdn.example.com:443|OK|400 with X-Cache|52|OK|204 through the tunnel|140
Reality|vless-tcp-reality|203.0.113.10:443|OK|TLS handshake|31|FAIL|no answer through the tunnel|
Hy2 obfs|hysteria2|hy2.example.com:443|SKIP|obfuscated QUIC, only the tunnel tells||SKIP|no xray: install it or set CHECK_XRAY|
EOF
  [ "$status" -eq 1 ]
  [[ "${lines[0]}" =~ ^NAME\ +PROTO\ +ENDPOINT\ +RESULT\ +LATENCY\ +DETAIL$ ]]
  [[ "${lines[1]}" =~ ^CDN\ +vless-xhttp-tls\ +cdn.example.com:443\ +OK\ +140\ ms\ +fast:\ 400\ with\ X-Cache\;\ tunnel:\ 204\ through\ the\ tunnel$ ]]
  [[ "${lines[2]}" =~ ^Reality\ +vless-tcp-reality\ +203.0.113.10:443\ +FAIL\ +fast:\ TLS\ handshake\;\ tunnel:\ no\ answer ]]
  [[ "${lines[3]}" =~ ^Hy2\ obfs\ +hysteria2\ +hy2.example.com:443\ +SKIP\  ]]
}

@test "the report cuts long names between characters and keeps the columns" {
  run check::report <<'EOF'
Нидерланды — сервер номер один (CDN)|vless-tcp-reality|203.0.113.10:443|OK|TLS handshake|31|OK|204 through the tunnel|140
EOF
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == "Нидерланды — сервер номер од vless-tcp-reality "* ]]
  printf '%s' "$output" | iconv -f UTF-8 -t UTF-8 >/dev/null
}

@test "a report of OK and SKIP rows exits 0" {
  run check::report <<'EOF'
CDN|vless-xhttp-tls|cdn.example.com:443|OK|400 with X-Cache|52|SKIP|--fast|
Hy2 obfs|hysteria2|hy2.example.com:443|SKIP|obfuscated QUIC, only the tunnel tells||SKIP|--fast|
EOF
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *" OK "*"52 ms"* ]]
}

@test "--help prints the usage; no URL or an unknown option exits 2" {
  run "$REPO/check.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: ./check.sh [--fast] <subscription-url>"* ]]
  run "$REPO/check.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no subscription URL"* ]]
  run "$REPO/check.sh" --verbose https://panel.example.com/api/sub/x
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option: --verbose"* ]]
  [ "$(calls .)" -eq 0 ]
}

@test "a missing tool exits 3 before any request" {
  local f
  mkdir "$TMP/nojq"
  for f in /usr/bin/* /bin/* "$TMP"/bin/*; do
    [[ "${f##*/}" == jq ]] || ln -sf "$f" "$TMP/nojq/"
  done
  run env PATH="$TMP/nojq" "$REPO/check.sh" https://panel.example.com/api/sub/x
  [ "$status" -eq 3 ]
  [[ "$output" == *"command not found: jq"* ]]
  [ "$(calls .)" -eq 0 ]
}

@test "a full run checks every server of the subscription and prints the table" {
  serve "$FIX/sub-base64.txt"
  respond xhttp 0 'HTTP/2 400' 'X-Cache: x' '' '0.052000'
  respond tls 0 '0.031000'
  respond quic 0 'c300000000'
  respond tunnel 0 '204 0.140000'
  touch "$TMP/open/ss.example.com-8388"
  run "$REPO/check.sh" https://panel.example.com/api/sub/5qJcKxWbT
  [ "$status" -eq 0 ]
  [[ "$output" == *"checking 7 servers"* ]]
  [ "$(grep -c ' OK .* 140 ms  fast: ' <<<"$output")" -eq 7 ]
  [[ "$output" == *"IPv6 hy2"*"[2001:db8::10]:8443"* ]]
  [[ "$output" != *"unexpected failure"* && "$output" != *3f1c2d4e* ]]
  [ "$(calls '^xray run -c ')" -eq 7 ]
}

@test "--fast skips the tunnels, and one failing server makes the exit code 1" {
  serve "$FIX/sub-base64.txt"
  respond xhttp 0 'HTTP/2 400' 'X-Cache: x' '' '0.052000'
  respond tls 0 '0.031000'
  respond quic 0 'c300000000'
  run "$REPO/check.sh" --fast https://panel.example.com/api/sub/5qJcKxWbT
  [ "$status" -eq 1 ]
  [[ "$output" == *"checking 7 servers, L7 probes only"* ]]
  [[ "$output" =~ Shadowsocks\ AEAD\ +shadowsocks-tcp-none\ +ss.example.com:8388\ +FAIL\ +fast:\ no\ TCP\ connection\;\ tunnel:\ --fast ]]
  [ "$(grep -c ' OK .*tunnel: --fast$' <<<"$output")" -eq 6 ]
  [[ "$output" != *"unexpected failure"* ]]
  [ "$(calls xray)" -eq 0 ]
}

@test "a subscription without a usable server exits 1" {
  serve <(printf '%s\n' 'vless://3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f@:443#Broken')
  run "$REPO/check.sh" https://panel.example.com/api/sub/x
  [ "$status" -eq 1 ]
  [[ "$output" == *"the subscription lists no servers"* ]]
  [[ "$output" != *"unexpected failure"* ]]
}
