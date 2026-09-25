#!/usr/bin/env bats
# Contract tests for lib/remnawave.sh (tech.md §5, §6): the files for the panel (config
# profile, host extra, Xray JSON template, xhttp inbound), their sync, the step-by-step
# guide, reruns.

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

# Emits as a terminal session would: remnawave::_interactive holds, stdin answers Enter.
emit_in_terminal() {
  run bash -c 'source "$1" && remnawave::_interactive() { return 0; } &&
    remnawave::emit 2>"$2" <<<"$(printf "\n%.0s" 1 2 3 4 5 6)"' _ "$REPO/lib/remnawave.sh" "$TMP/stderr"
}

full_node() {
  export VLESS_DOMAIN=vless.example.com HY2_DOMAIN=hy2.example.com REALITY_SNI=www.swiss.com \
    REALITY_PRIVATE_KEY=c3ludGhldGljLXJlYWxpdHkta2V5LWZvci10ZXN0cyE REALITY_SHORT_ID=1a2b3c4d5e6f7a8b \
    ORIGIN_IP=203.0.113.10 NGINX_TLS_PORT=8444
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

@test "stdout carries only the steps: every file, the panel sections and the CDN resource, in order" {
  local order
  full_node
  emit
  [ "$status" -eq 0 ]
  order="$(grep -oE '^  [0-9]\. [A-Za-z]+' <<<"$output" | tr -s ' ' | tr '\n' '|')"
  [ "$order" = " 1. Config| 2. Node| 3. Internal| 4. Subscription| 5. Hosts| 6. CDN|" ]
  [[ "$output" == *"paste out/remnawave/config-profile.json"* ]]
  [[ "$output" == *"Put only out/remnawave/inbound-xhttp-cdn.json into its \"inbounds\""* ]]
  [[ "$output" == *"paste out/remnawave/subscription-xray-json.json"* ]]
  [[ "$output" == *"CDN: inbound VLESS-XHTTP-CDN, address cdn.example.com, port 443. Advanced: SNI and host cdn.example.com, path /api/v2.jpg/, security TLS, extra <- out/remnawave/host-xhttp-extra.json"* ]]
  [[ "$output" == *"Reality: inbound VLESS-REALITY, address vless.example.com, port 443"* ]]
  [[ "$output" == *"Hysteria2: inbound HYSTERIA2, address hy2.example.com"* ]]
  [[ "$output" == *"Source: 203.0.113.10:8444, HTTPS for the source on"* ]]
  [[ "$output" != *INFO* ]]
}

@test "the node comes after the profile: the panel creates it with the profile, its compose file starts it here" {
  local step1 step2
  full_node
  emit
  [ "$status" -eq 0 ]
  step1="$(sed -n '/^  1\. /,/^  2\. /p' <<<"$output")"
  step2="$(sed -n '/^  2\. /,/^  3\. /p' <<<"$output")"
  [[ "$step2" == *"New node: Nodes -> Management -> Create node, address 203.0.113.10; on the last step choose the profile from step 1 with all its inbounds -> Copy docker-compose.yml -> Create node."* ]]
  [[ "$step2" == *"On this server: the file goes to /opt/remnanode/docker-compose.yml, then cd /opt/remnanode && docker compose up -d."* ]]
  [[ "$step2" == *"A node already in the panel: the node card -> Change Profile -> the profile from step 1"* ]]
  [[ "$step1" != *docker-compose* ]]
  # The volume has to be in the compose file before its first start.
  [ "$(grep -n 'add the volume /etc/letsencrypt:/etc/letsencrypt:ro' <<<"$step2" | cut -d: -f1)" -lt \
    "$(grep -n 'docker compose up -d. No Docker' <<<"$step2" | cut -d: -f1)" ]
  [[ "$step2" == *"HYSTERIA2 reads /etc/letsencrypt/live/hy2.example.com/ inside the node container"* ]]
}

@test "the config profile carries Reality, the xhttp inbound and Hysteria2 for the node's domains" {
  full_node
  emit
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.inbounds[].tag]' "$OUT/config-profile.json")" = '["VLESS-REALITY","VLESS-XHTTP-CDN","HYSTERIA2"]' ]
  jq -e '.inbounds[0].streamSettings.realitySettings == {dest: "www.swiss.com:443", show: false, xver: 0,
      shortIds: ["", "1a2b3c4d5e6f7a8b"], privateKey: "c3ludGhldGljLXJlYWxpdHkta2V5LWZvci10ZXN0cyE",
      serverNames: ["www.swiss.com"]}
    and .inbounds[2].streamSettings.tlsSettings.certificates == [{keyFile: "/etc/letsencrypt/live/hy2.example.com/privkey.pem",
      certificateFile: "/etc/letsencrypt/live/hy2.example.com/fullchain.pem"}]
    and .inbounds[2].streamSettings.hysteriaSettings.masquerade.url == "https://www.swiss.com"
    and [.outbounds[].tag] == ["DIRECT", "BLOCK"]' "$OUT/config-profile.json"
  [ "$(jq -S '.inbounds[1]' "$OUT/config-profile.json")" = "$(jq -S . "$OUT/inbound-xhttp-cdn.json")" ]
}

@test "without REALITY_SNI or HY2_DOMAIN the profile leaves those inbounds out" {
  emit
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.inbounds[].tag]' "$OUT/config-profile.json")" = '["VLESS-XHTTP-CDN"]' ]
  [[ "$output" != *"Reality:"* && "$output" != *"Hysteria2:"* && "$output" != *"/etc/letsencrypt:/etc/letsencrypt:ro"* ]]
  [[ "$output" == *"Create node, address <IP of this server>;"* ]]
  HY2_DOMAIN=hy2.example.com emit
  [ "$status" -eq 0 ]
  jq -e '.inbounds[1].tag == "HYSTERIA2" and (.inbounds[1].streamSettings.hysteriaSettings | has("masquerade") | not)' \
    "$OUT/config-profile.json"
}

@test "the xhttp inbound takes the client address from nginx's X-Forwarded-For" {
  emit
  [ "$status" -eq 0 ]
  jq -e '.streamSettings.sockopt.trustedXForwardedFor == ["X-Real-IP"]' "$OUT/inbound-xhttp-cdn.json"
}

@test "the subscription template routes the operator's zone direct and resolves it locally" {
  export VLESS_DOMAIN=vless.other.org HY2_DOMAIN=hy2.example.com
  emit
  [ "$status" -eq 0 ]
  [ "$(jq -c '.dns.servers[1].domains' "$OUT/subscription-xray-json.json")" = '["domain:example.com","domain:vless.other.org"]' ]
  [ "$(jq -c '.routing.rules[1].domain' "$OUT/subscription-xray-json.json")" = '["domain:example.com","domain:vless.other.org"]' ]
  jq -e '.remnawave.addVirtualHostAsOutbound == true and .routing.rules[-1].outboundTag == "proxy"' \
    "$OUT/subscription-xray-json.json"
  [ "$(grep -c __OWN_DOMAINS__ "$OUT/subscription-xray-json.json")" -eq 0 ]
}

@test "the Reality private key stays in the private profile, never on stdout or stderr" {
  full_node
  emit
  [ "$status" -eq 0 ]
  [[ "$output" != *c3ludGhldGljLXJl* ]]
  [[ "$(cat "$TMP/stderr")" != *c3ludGhldGljLXJl* ]]
  [ "$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$OUT/config-profile.json")" = c3ludGhldGljLXJlYWxpdHkta2V5LWZvci10ZXN0cyE ]
}

@test "in a terminal the guide waits for Enter after each step, a rerun with the same files does not" {
  full_node
  emit_in_terminal
  [ "$status" -eq 0 ]
  [ "$(grep -o 'Press Enter when done' "$TMP/stderr" | wc -l)" -eq 6 ]
  emit_in_terminal
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Press Enter when done' "$TMP/stderr")" -eq 0 ]
  [[ "$output" == *"1. Config profile"* ]]
}

@test "the files are private to root and valid JSON" {
  emit
  [ "$status" -eq 0 ]
  [ "$(find "$OUT" -name '*.json' -perm 600 | wc -l)" -eq 4 ]
  [ "$(find "$OUT" -name '*.json' | wc -l)" -eq 4 ]
  [ -n "$(find "$REPO/out" "$OUT" -maxdepth 0 -perm 700 | sed -n 2p)" ]
  jq -e . "$OUT"/*.json >/dev/null
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
