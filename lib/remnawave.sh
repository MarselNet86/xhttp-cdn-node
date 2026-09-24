# shellcheck shell=bash
# xhttp configs for the Remnawave panel (tech.md §5, §6): renders remnawave/ into
# out/remnawave/ and prints where each file goes. The panel manages xray on the node, so
# nothing here touches the system or the node: the operator pastes the files by hand.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

# Fields that must match one for one between the inbound and the host extra, or the tunnel
# breaks exactly through the CDN (remnawave/README.md).
readonly -a REMNAWAVE_SYNCED=(
  seqKey seqPlacement xPaddingKey xPaddingHeader xPaddingMethod xPaddingBytes xPaddingPlacement
  xPaddingObfsMode sessionIDTable sessionIDLength sessionIDPlacement uplinkDataKey
  uplinkChunkSize uplinkHTTPMethod uplinkDataPlacement serverMaxHeaderBytes
)

remnawave::emit() {
  local out="$REPO_ROOT/out/remnawave" inbound host
  require::cmd envsubst jq
  env::require CDN_DOMAIN XHTTP_PATH XHTTP_PORT
  # shellcheck disable=SC2016  # envsubst takes the placeholder list literally
  inbound="$(CDN_DOMAIN="$CDN_DOMAIN" XHTTP_PATH="$XHTTP_PATH" XHTTP_PORT="$XHTTP_PORT" \
    envsubst '${CDN_DOMAIN} ${XHTTP_PATH} ${XHTTP_PORT}' <"$REPO_ROOT/remnawave/inbound-xhttp-cdn.json.tmpl")"
  host="$(<"$REPO_ROOT/remnawave/host-xhttp-extra.json")"
  jq -e . >/dev/null <<<"$inbound" ||
    log::die "$EXIT_FAILURE" "remnawave/inbound-xhttp-cdn.json.tmpl does not render to valid JSON"
  jq -e . >/dev/null <<<"$host" ||
    log::die "$EXIT_FAILURE" "remnawave/host-xhttp-extra.json is not valid JSON"
  remnawave::_check_sync "$inbound" "$host"

  mkdir -p "$out"
  # The files carry the xhttp path and the obfuscation profile of this node.
  chmod 700 "$REPO_ROOT/out" "$out"
  fs::write "$out/inbound-xhttp-cdn.json" 600 "$inbound"
  fs::write "$out/host-xhttp-extra.json" 600 "$host"
  jq -e . "$out/inbound-xhttp-cdn.json" "$out/host-xhttp-extra.json" >/dev/null ||
    log::die "$EXIT_FAILURE" "the files in $out are not valid JSON"
  remnawave::_instructions "$out"
}

# Dies naming each synced field that differs, and when the client may post more than the
# server accepts (scMaxEachPostBytes).
remnawave::_check_sync() {
  local inbound="$1" host="$2" problems
  problems="$(jq -rn --argjson inbound "$inbound" --argjson host "$host" \
    --args '$inbound.streamSettings.xhttpSettings as $x
      | ([$ARGS.positional[] | select($x.extra[.] != $host[.])
          | "\(.): inbound \($x.extra[.] | tojson), host \($host[.] | tojson)"]
        + (if ($host.scMaxEachPostBytes // 0) > ($x.scMaxEachPostBytes // 1000000)
           then ["scMaxEachPostBytes: host \($host.scMaxEachPostBytes) is above the inbound limit \($x.scMaxEachPostBytes // 1000000)"]
           else [] end))[]' "${REMNAWAVE_SYNCED[@]}")"
  if [[ -n "$problems" ]]; then
    log::die "$EXIT_FAILURE" "the inbound and the host extra in remnawave/ disagree, the tunnel would break through the CDN: $(paste -sd';' <<<"$problems")"
  fi
}

# Data for the operator, so it goes to stdout.
remnawave::_instructions() {
  local out="${1#"$REPO_ROOT"/}"
  cat <<EOF

Remnawave panel, by hand: xray on the node is managed by the panel, not by this script.
  1. $out/inbound-xhttp-cdn.json
     -> the node's config profile, into "inbounds": the VLESS-XHTTP-CDN inbound on 127.0.0.1:$XHTTP_PORT
  2. $out/host-xhttp-extra.json
     -> the host for $CDN_DOMAIN, field "extra". Host settings: address $CDN_DOMAIN, port 443,
        network xhttp, mode packet-up, path $XHTTP_PATH, host and SNI $CDN_DOMAIN, TLS.
  Obfuscation fields stay identical on both sides; roll out xmux first, then the buffers
  (remnawave/README.md). The validate step checks the result once the panel pushed it.
EOF
}
