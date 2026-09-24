#!/usr/bin/env bats
# Contract tests for lib/remnawave.sh (tech.md §5, §6): rendered panel configs, their sync,
# the printed instructions, reruns.

setup() {
  # bats 1.2 on Ubuntu 22.04 has no BATS_TEST_TMPDIR.
  TMP="$(mktemp -d)"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
  cp -R "$BATS_TEST_DIRNAME/../lib" "$BATS_TEST_DIRNAME/../remnawave" \
    "$BATS_TEST_DIRNAME/../.env.example" "$REPO/"
  # shellcheck source=../lib/remnawave.sh
  source "$REPO/lib/remnawave.sh"
  export CDN_DOMAIN=cdn.example.com XHTTP_PATH=/api/v2.jpg/ XHTTP_PORT=4443
  OUT="$REPO/out/remnawave"
}

teardown() {
  rm -rf "${TMP:?}"
}

# Emits with stdout only in $output; stderr goes to $TMP/stderr.
emit() {
  run bash -c 'source "$1" && remnawave::emit 2>"$2"' _ "$REPO/lib/remnawave.sh" "$TMP/stderr"
}

# Rewrites the repo's host extra through a jq filter.
host_extra() {
  jq "$1" "$REPO/remnawave/host-xhttp-extra.json" >"$TMP/extra"
  mv "$TMP/extra" "$REPO/remnawave/host-xhttp-extra.json"
}

@test "the inbound is rendered with CDN_DOMAIN, XHTTP_PATH and XHTTP_PORT" {
  XHTTP_PATH=/cdn/v1.bin/ XHTTP_PORT=4450 emit
  [ "$status" -eq 0 ]
  [ "$(jq -r .port "$OUT/inbound-xhttp-cdn.json")" = 4450 ]
  [ "$(jq -r .listen "$OUT/inbound-xhttp-cdn.json")" = 127.0.0.1 ]
  [ "$(jq -r .streamSettings.xhttpSettings.host "$OUT/inbound-xhttp-cdn.json")" = cdn.example.com ]
  [ "$(jq -r .streamSettings.xhttpSettings.path "$OUT/inbound-xhttp-cdn.json")" = /cdn/v1.bin/ ]
  [ "$(jq -r .streamSettings.xhttpSettings.mode "$OUT/inbound-xhttp-cdn.json")" = packet-up ]
}

@test "the host extra is copied as it is" {
  emit
  [ "$status" -eq 0 ]
  cmp "$OUT/host-xhttp-extra.json" "$REPO/remnawave/host-xhttp-extra.json"
}

@test "the tuned values of tech.md §6 reach the panel files" {
  emit
  [ "$status" -eq 0 ]
  [ "$(jq -c .xmux "$OUT/host-xhttp-extra.json")" = '{"hKeepAlivePeriod":15,"hMaxReusableSecs":"1800-3000"}' ]
  [ "$(jq -r .scMaxEachPostBytes "$OUT/host-xhttp-extra.json")" = 60000 ]
  [ "$(jq -r .streamSettings.xhttpSettings.scMaxBufferedPosts "$OUT/inbound-xhttp-cdn.json")" = 256 ]
  [ "$(jq -r .streamSettings.xhttpSettings.scMaxEachPostBytes "$OUT/inbound-xhttp-cdn.json")" = 60000 ]
  [ "$(jq -r .streamSettings.xhttpSettings.extra.serverMaxHeaderBytes "$OUT/inbound-xhttp-cdn.json")" = 32768 ]
}

@test "stdout carries only the instructions, naming both files and where they go" {
  emit
  [ "$status" -eq 0 ]
  [[ "$output" == *"out/remnawave/inbound-xhttp-cdn.json"* ]]
  [[ "$output" == *"into \"inbounds\""* ]]
  [[ "$output" == *"out/remnawave/host-xhttp-extra.json"* ]]
  [[ "$output" == *"the host for cdn.example.com, field \"extra\""* ]]
  [[ "$output" == *"path /api/v2.jpg/"* ]]
  [[ "$output" != *INFO* ]]
}

@test "the files are private to root and valid JSON" {
  emit
  [ "$status" -eq 0 ]
  [ -n "$(find "$OUT/inbound-xhttp-cdn.json" "$OUT/host-xhttp-extra.json" -perm 600 | sed -n 2p)" ]
  [ -n "$(find "$REPO/out" "$OUT" -maxdepth 0 -perm 700 | sed -n 2p)" ]
  jq -e . "$OUT/inbound-xhttp-cdn.json" "$OUT/host-xhttp-extra.json" >/dev/null
}

@test "a rerun leaves the files untouched" {
  local before
  emit
  before="$(cksum "$OUT"/*)"
  touch -d 2020-01-01 "$OUT"/*
  emit
  [ "$status" -eq 0 ]
  [ "$(cksum "$OUT"/*)" = "$before" ]
  [ "$(date -r "$OUT/inbound-xhttp-cdn.json" +%Y)" = 2020 ]
}

@test "an obfuscation field that differs between inbound and host stops the emit" {
  host_extra '.xPaddingHeader = "X-Other"'
  emit
  [ "$status" -eq 1 ]
  [[ "$(cat "$TMP/stderr")" == *'xPaddingHeader: inbound "X-Cache", host "X-Other"'* ]]
  [ ! -e "$OUT/host-xhttp-extra.json" ]
}

@test "a host posting more than the inbound accepts stops the emit" {
  host_extra '.scMaxEachPostBytes = 90000'
  emit
  [ "$status" -eq 1 ]
  [[ "$(cat "$TMP/stderr")" == *"scMaxEachPostBytes: host 90000 is above the inbound limit 60000"* ]]
}

@test "every field that README asks to keep in sync is checked" {
  local field
  for field in seqKey xPaddingKey xPaddingHeader xPaddingMethod xPaddingBytes xPaddingPlacement \
    sessionIDTable sessionIDLength uplinkDataKey uplinkChunkSize uplinkHTTPMethod \
    uplinkDataPlacement serverMaxHeaderBytes; do
    [[ " ${REMNAWAVE_SYNCED[*]} " == *" $field "* ]] || {
      echo "not checked: $field"
      return 1
    }
  done
}

@test "broken JSON stops the emit" {
  printf '{"xmux": ' >"$REPO/remnawave/host-xhttp-extra.json"
  emit
  [ "$status" -eq 1 ]
  [[ "$(cat "$TMP/stderr")" == *"host-xhttp-extra.json is not valid JSON"* ]]
}
