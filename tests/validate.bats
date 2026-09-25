#!/usr/bin/env bats
# Contract tests for lib/validate.sh (tech.md §5): four layers from the bottom up, exit 8
# naming the broken layer. curl, openssl, hostname and ss are stubs; each kind of request
# gets its answer from $TMP/resp/<kind>: line 1 is curl's exit code, the rest the headers.

setup() {
  # bats 1.2 on Ubuntu 22.04 has no BATS_TEST_TMPDIR.
  TMP="$(mktemp -d)"
  REPO="$TMP/repo"
  mkdir -p "$REPO" "$TMP/bin" "$TMP/resp"
  cp -R "$BATS_TEST_DIRNAME/../lib" "$BATS_TEST_DIRNAME/../remnawave" \
    "$BATS_TEST_DIRNAME/../.env.example" "$REPO/"
  export STUB_DIR="$TMP"
  export CDN_DOMAIN=cdn.example.com XHTTP_PATH=/api/v2.jpg/ XHTTP_PORT=4443 NGINX_TLS_PORT=8444
  export ORIGIN_IP=203.0.113.10 NODE_NAME=node1
  # shellcheck source=../lib/remnawave.sh
  source "$REPO/lib/remnawave.sh"
  remnawave::emit >/dev/null 2>&1
  stubs
  PATH="$TMP/bin:$PATH"
  # shellcheck source=../lib/validate.sh
  source "$REPO/lib/validate.sh"
  touch "$TMP/xray-up"
  echo "10.0.0.5 $ORIGIN_IP" >"$TMP/addresses"
  respond origin 0 'HTTP/1.1 204 No Content' 'X-CDN-Origin: ok'
  respond xhttp 0 'HTTP/1.1 400 Bad Request' 'X-Cache: 8f3kd02mZq'
  respond bare 0 'HTTP/1.1 400 Bad Request' 'X-Cache: Zq02dk3f8'
  respond cdn 0 'HTTP/2 204' 'x-cdn-origin: ok'
}

teardown() {
  rm -rf "${TMP:?}"
}

# respond KIND EXIT [HEADER...]: what the curl stub answers to that kind of request.
respond() {
  local kind="$1" code="$2"
  shift 2
  {
    echo "$code"
    printf '%s\r\n' "$@"
  } >"$TMP/resp/$kind"
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
echo "curl $*" >>"$STUB_DIR/calls"
case "$*" in
  *ifconfig.me*) [ -f "$STUB_DIR/public-ip" ] || exit 7; cat "$STUB_DIR/public-ip"; exit 0 ;;
  *--resolve*/cdn-check) kind=origin ;;
  *--resolve*test) kind=xhttp ;;
  *--resolve*.jpg) kind=bare ;;
  *"/cdn-check?nocache="*) kind=cdn ;;
  *) echo "curl stub: unexpected call: $*" >&2; exit 99 ;;
esac
[ -f "$STUB_DIR/resp/$kind" ] || exit 7
tail -n +2 "$STUB_DIR/resp/$kind"
exit "$(head -n 1 "$STUB_DIR/resp/$kind")"
EOF
  stub openssl <<'EOF'
if [ "$1" = x509 ]; then
  cat >/dev/null
  printf 'subject=CN = *.cdn.provider.example\nX509v3 Subject Alternative Name:\n    DNS:*.cdn.provider.example\n'
fi
EOF
  stub hostname <<'EOF'
cat "$STUB_DIR/addresses"
EOF
  stub ss <<'EOF'
[ -f "$STUB_DIR/ss" ] && cat "$STUB_DIR/ss"
exit 0
EOF
  # validate::_listening probes the port through timeout: the marker decides instead.
  stub timeout <<'EOF'
[ -e "$STUB_DIR/xray-up" ]
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

@test "all four layers pass on a working node" {
  run validate::layers
  [ "$status" -eq 0 ]
  [[ "$output" == *"layer 1 (xray): 127.0.0.1:4443 accepts connections"* ]]
  [[ "$output" == *"layer 2 (origin nginx): /cdn-check on :8444 gives 204"* ]]
  [[ "$output" == *"layer 3 (xhttp path): xray answers /api/v2.jpg/ and /api/v2.jpg through nginx with 400 and X-Cache"* ]]
  [[ "$output" == *"layer 4 (CDN edge): https://cdn.example.com/cdn-check gives 204 from this origin"* ]]
  [[ "$output" != *WARN* ]]
}

@test "origin checks go to 127.0.0.1, the CDN check through DNS with certificate checks" {
  run validate::layers
  [ "$status" -eq 0 ]
  [ "$(calls '-k --resolve cdn.example.com:8444:127.0.0.1 https://cdn.example.com:8444/cdn-check$')" -eq 1 ]
  [ "$(calls '-k --resolve cdn.example.com:8444:127.0.0.1 https://cdn.example.com:8444/api/v2.jpg/test$')" -eq 1 ]
  [ "$(calls '-k --resolve cdn.example.com:8444:127.0.0.1 https://cdn.example.com:8444/api/v2.jpg$')" -eq 1 ]
  [ "$(calls 'https://cdn.example.com/cdn-check?nocache=[0-9]')" -eq 1 ]
  [ "$(grep 'nocache=' "$TMP/calls" | grep -c -- ' -k \|--resolve')" -eq 0 ]
}

@test "layer 1 stops the check when xray does not listen" {
  rm "$TMP/xray-up"
  run validate::layers
  [ "$status" -eq 8 ]
  [[ "$output" == *"layer 1 (xray) failed: nothing listens on 127.0.0.1:4443: no node runs the VLESS-XHTTP-CDN-NODE1 inbound yet. Do panel steps 1 and 2 above"* ]]
  [ "$(calls 'https://')" -eq 0 ]
}

@test "layer 1 warns when xray also listens beyond the loopback" {
  printf '%s\n' 'LISTEN 0 4096 0.0.0.0:4443 0.0.0.0:*' >"$TMP/ss"
  run validate::layers
  [ "$status" -eq 0 ]
  [[ "$output" == *"port 4443 listens beyond the loopback (0.0.0.0:4443)"* ]]
}

@test "layer 1 stays quiet when xray listens on the loopback only" {
  printf '%s\n' 'LISTEN 0 4096 127.0.0.1:4443 0.0.0.0:*' >"$TMP/ss"
  run validate::layers
  [ "$status" -eq 0 ]
  [[ "$output" != *WARN* ]]
}

@test "layer 2 fails when /cdn-check is not the 204 of the cdn-deploy site" {
  respond origin 0 'HTTP/1.1 404 Not Found'
  run validate::layers
  [ "$status" -eq 8 ]
  [[ "$output" == *"layer 2 (origin nginx) failed: /cdn-check gave 404"* ]]
  respond origin 7
  run validate::layers
  [ "$status" -eq 8 ]
  [[ "$output" == *"layer 2 (origin nginx) failed: no answer on 127.0.0.1:8444"* ]]
}

@test "layer 3 wants the padding header named in the rendered inbound" {
  respond xhttp 0 'HTTP/1.1 400 Bad Request'
  run validate::layers
  [ "$status" -eq 8 ]
  [[ "$output" == *"layer 3 (xhttp path) failed: xray answered 400 without the X-Cache padding header"* ]]
  jq '.streamSettings.xhttpSettings.extra.xPaddingHeader = "X-Pad"' \
    "$REPO/out/remnawave/inbound-xhttp-cdn.json" >"$TMP/in" && mv "$TMP/in" "$REPO/out/remnawave/inbound-xhttp-cdn.json"
  respond xhttp 0 'HTTP/1.1 400 Bad Request' 'x-pad: abc'
  respond bare 0 'HTTP/1.1 400 Bad Request' 'x-pad: def'
  run validate::layers
  [ "$status" -eq 0 ]
}

@test "layer 3 tells a path or host mismatch from an unreachable xray" {
  respond xhttp 0 'HTTP/1.1 404 Not Found'
  run validate::layers
  [ "$status" -eq 8 ]
  [[ "$output" == *"xray answered 404: XHTTP_PATH (/api/v2.jpg/) or the inbound host (cdn.example.com) differs from the panel"* ]]
  respond xhttp 0 'HTTP/1.1 502 Bad Gateway'
  run validate::layers
  [ "$status" -eq 8 ]
  [[ "$output" == *"nginx cannot reach xray on 127.0.0.1:4443 (502)"* ]]
}

@test "layer 3 wants XHTTP_PATH without its trailing slash to reach xray, as Timeweb sends it" {
  respond bare 0 'HTTP/1.1 301 Moved Permanently' 'Location: https://cdn.example.com:8444/api/v2.jpg/'
  run validate::layers
  [ "$status" -eq 8 ]
  [[ "$output" == *"layer 3 (xhttp path) failed: /api/v2.jpg gave 301, not 400 with X-Cache: nginx does not pass the path without its trailing slash, which Timeweb sends"* ]]
  [ "$(calls 'nocache=')" -eq 0 ]
}

@test "layer 4 names the cause of each CDN answer" {
  local case status want
  for case in "451|move to a new domain" "502|must be 203.0.113.10:8444 over HTTPS" \
    "504|the CDN cannot reach the origin" "503|overload or a disabled resource" \
    "403|allows GET" "418|gave 418, not 204"; do
    status="${case%%|*}"
    want="${case#*|}"
    respond cdn 0 "HTTP/2 $status"
    run validate::layers
    [ "$status" -eq 8 ] || {
      echo "$case: exit $status"
      return 1
    }
    [[ "$output" == *"layer 4 (CDN edge) failed"*"$want"* ]] || {
      echo "$case: $output"
      return 1
    }
  done
}

@test "layer 4 rejects a 204 that did not come from this origin" {
  respond cdn 0 'HTTP/2 204'
  run validate::layers
  [ "$status" -eq 8 ]
  [[ "$output" == *"204 without X-CDN-Origin: the answer did not come from this origin"* ]]
}

@test "layer 4 shows the certificate the edge presents when it does not cover CDN_DOMAIN" {
  respond cdn 60
  run validate::layers
  [ "$status" -eq 8 ]
  [[ "$output" == *"does not cover cdn.example.com (subject=CN = *.cdn.provider.example X509v3 Subject Alternative Name: DNS:*.cdn.provider.example)"* ]]
}

@test "layer 4 separates DNS, connection and TLS failures" {
  respond cdn 6
  run validate::layers
  [[ "$output" == *"cdn.example.com does not resolve: add the CNAME"* ]]
  respond cdn 28
  run validate::layers
  [[ "$output" == *"no connection to cdn.example.com:443"* ]]
  respond cdn 35
  run validate::layers
  [ "$status" -eq 8 ]
  [[ "$output" == *"TLS handshake with cdn.example.com failed"* ]]
}

@test "an ORIGIN_IP that is not this host gets a warning, not a failure" {
  echo 10.0.0.5 >"$TMP/addresses"
  printf 198.51.100.7 >"$TMP/public-ip"
  run validate::layers
  [ "$status" -eq 0 ]
  [[ "$output" == *"ORIGIN_IP=203.0.113.10 is not an address of this host, whose public IPv4 is 198.51.100.7"* ]]
  printf 203.0.113.10 >"$TMP/public-ip"
  run validate::layers
  [[ "$output" != *WARN* ]]
}
