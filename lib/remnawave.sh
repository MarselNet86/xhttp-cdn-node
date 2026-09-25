# shellcheck shell=bash
# Files for the Remnawave panel (tech.md §5, §6): renders remnawave/ into out/remnawave/
# for this node's domains, then walks the operator through the panel and the CDN resource.
# The panel manages xray on the node: the operator pastes the files by hand. At panel step
# 2 the node that the panel created starts on this server (lib/node.sh).

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=prompt.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/prompt.sh"
# shellcheck source=node.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/node.sh"

# Fields that must match one for one between the inbound and the host extra, or the tunnel
# breaks exactly through the CDN (remnawave/README.md).
readonly -a REMNAWAVE_SYNCED=(
  seqKey seqPlacement xPaddingKey xPaddingHeader xPaddingMethod xPaddingBytes xPaddingPlacement
  xPaddingObfsMode sessionIDTable sessionIDLength sessionIDPlacement uplinkDataKey
  uplinkChunkSize uplinkHTTPMethod uplinkDataPlacement serverMaxHeaderBytes
)

# Writes the three files the panel takes (config profile, host extra, Xray JSON
# subscription template) plus the xhttp inbound alone, for a node that keeps its own
# profile. Then prints the steps; in a terminal it waits for each one while a file changed.
remnawave::emit() {
  local out="$REPO_ROOT/out/remnawave" inbound host reality="" hy2="" profile template
  local file changed=0
  require::cmd envsubst jq
  env::require CDN_DOMAIN XHTTP_PATH XHTTP_PORT NODE_NAME
  inbound="$(remnawave::_render inbound-xhttp-cdn.json.tmpl)"
  host="$(<"$REPO_ROOT/remnawave/host-xhttp-extra.json")"
  jq -e . >/dev/null <<<"$host" ||
    log::die "$EXIT_FAILURE" "remnawave/host-xhttp-extra.json is not valid JSON"
  remnawave::_check_sync "$inbound" "$host"
  if [[ -n "${REALITY_SNI:-}" ]]; then
    env::require REALITY_PRIVATE_KEY REALITY_SHORT_ID
    reality="$(remnawave::_render inbound-reality.json.tmpl)"
  fi
  if [[ -n "${HY2_DOMAIN:-}" ]]; then
    # The masquerade answers probes with the Reality site; without one, xray's default.
    hy2="$(remnawave::_render inbound-hysteria2.json.tmpl |
      jq --arg sni "${REALITY_SNI:-}" 'if $sni == "" then del(.streamSettings.hysteriaSettings.masquerade) else . end')"
  fi
  profile="$(jq --argjson xhttp "$inbound" --arg reality "$reality" --arg hy2 "$hy2" \
    '.inbounds = [($reality | select(. != "") | fromjson), $xhttp, ($hy2 | select(. != "") | fromjson)]' \
    "$REPO_ROOT/remnawave/config-profile.json")" ||
    log::die "$EXIT_FAILURE" "remnawave/config-profile.json does not make a valid profile"
  template="$(jq --argjson own "$(remnawave::_own_domains)" \
    'walk(if . == "__OWN_DOMAINS__" then $own else . end)' "$REPO_ROOT/remnawave/subscription-xray-json.json")" ||
    log::die "$EXIT_FAILURE" "remnawave/subscription-xray-json.json is not valid JSON"

  mkdir -p "$out"
  # The files carry the Reality private key, the xhttp path and the obfuscation profile.
  chmod 700 "$REPO_ROOT/out" "$out"
  for file in config-profile host-xhttp-extra subscription-xray-json inbound-xhttp-cdn; do
    case "$file" in
      config-profile) fs::write "$out/$file.json" 600 "$profile" ;;
      host-xhttp-extra) fs::write "$out/$file.json" 600 "$host" ;;
      subscription-xray-json) fs::write "$out/$file.json" 600 "$template" ;;
      inbound-xhttp-cdn) fs::write "$out/$file.json" 600 "$inbound" ;;
    esac
    changed=$((changed + FS_CHANGED))
  done
  jq -e . "$out"/*.json >/dev/null || log::die "$EXIT_FAILURE" "the files in $out are not valid JSON"
  remnawave::_guide "$out" "$changed"
}

# Renders remnawave/NAME with the .env values it names and checks that it is JSON.
# NODE_TAG, the node name in capitals, ends the inbound tags: the panel wants every tag
# unique across its profiles.
remnawave::_render() {
  local name="$1" out
  # shellcheck disable=SC2016  # envsubst takes the placeholder list literally
  out="$(CDN_DOMAIN="$CDN_DOMAIN" XHTTP_PATH="$XHTTP_PATH" XHTTP_PORT="$XHTTP_PORT" \
    HY2_DOMAIN="${HY2_DOMAIN:-}" REALITY_SNI="${REALITY_SNI:-}" \
    REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}" REALITY_SHORT_ID="${REALITY_SHORT_ID:-}" \
    NODE_TAG="${NODE_NAME^^}" \
    envsubst '${CDN_DOMAIN} ${XHTTP_PATH} ${XHTTP_PORT} ${HY2_DOMAIN} ${REALITY_SNI} ${REALITY_PRIVATE_KEY} ${REALITY_SHORT_ID} ${NODE_TAG}' \
    <"$REPO_ROOT/remnawave/$name")"
  jq -e . >/dev/null <<<"$out" || log::die "$EXIT_FAILURE" "remnawave/$name does not render to valid JSON"
  printf '%s' "$out"
}

# The operator's own domains, as the subscription template routes them direct: the zone
# of CDN_DOMAIN, which Timeweb wants as a subdomain, and any other domain outside it.
remnawave::_own_domains() {
  local zone="$CDN_DOMAIN" domain
  local -a own
  if [[ "$CDN_DOMAIN" == *.*.* ]]; then
    zone="${CDN_DOMAIN#*.}"
  fi
  own=("domain:$zone")
  for domain in "${VLESS_DOMAIN:-}" "${HY2_DOMAIN:-}"; do
    if [[ -n "$domain" && "$domain" != "$zone" && "$domain" != *".$zone" &&
      " ${own[*]} " != *" domain:$domain "* ]]; then
      own+=("domain:$domain")
    fi
  done
  jq -cn '$ARGS.positional' --args "${own[@]}"
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

# The steps, as data for the operator, so they go to stdout. PAUSE (the count of changed
# files) makes a terminal session wait after each step: a rerun with the same files only
# lists them.
remnawave::_guide() {
  local out="${1#"$REPO_ROOT"/}" pause="$2" step=0 inbounds="" address bold="" reset=""
  local tag="${NODE_NAME^^}"
  local -a hosts
  # The colours follow stderr; a guide sent to a file stays plain.
  if [[ -t 1 ]]; then
    bold="$UI_BOLD" reset="$UI_RESET"
  fi
  if [[ -n "${REALITY_SNI:-}" ]]; then
    inbounds+="VLESS-REALITY-$tag on :443/tcp, "
  fi
  inbounds+="VLESS-XHTTP-CDN-$tag on 127.0.0.1:$XHTTP_PORT"
  if [[ -n "${HY2_DOMAIN:-}" ]]; then
    inbounds+=", HYSTERIA2-$tag on :443/udp"
  fi
  address="${VLESS_DOMAIN:-${ORIGIN_IP:-<IP of this server>}}"
  hosts=("CDN: inbound VLESS-XHTTP-CDN-$tag, address $CDN_DOMAIN, port 443. Advanced: SNI and host $CDN_DOMAIN, path $XHTTP_PATH, security TLS, extra <- $out/host-xhttp-extra.json")
  if [[ -n "${REALITY_SNI:-}" ]]; then
    hosts+=("Reality: inbound VLESS-REALITY-$tag, address $address, port 443")
  fi
  if [[ -n "${HY2_DOMAIN:-}" ]]; then
    hosts+=("Hysteria2: inbound HYSTERIA2-$tag, address $HY2_DOMAIN, port 443. Advanced: SNI $HY2_DOMAIN")
  fi

  printf '\n%sRemnawave panel and the CDN resource, step by step.%s The files are in %s/.\n' \
    "$bold" "$reset" "$out"
  # Profile names are unique in the panel too, so the node name serves as one.
  remnawave::_step "Config profile" \
    "Config Profiles -> Create Config Profile -> the name $tag -> paste $out/config-profile.json -> Save." \
    "Inbounds: $inbounds." \
    "The node keeps a profile of its own? Put only $out/inbound-xhttp-cdn.json into its \"inbounds\"."
  # The panel asks for the profile when it creates a node, so the node comes second. Its
  # questions take the place of the wait.
  remnawave::_print "Node" \
    "New node: Nodes -> Management -> Create node, address ${ORIGIN_IP:-<IP of this server>}; on the last step choose the profile from step 1 with all its inbounds -> Create node." \
    "The panel then shows docker-compose.yml: ./deploy.sh takes its SECRET_KEY and NODE_PORT once, keeps them in .env and runs the node from $NODE_COMPOSE, installing Docker when it is missing." \
    "A node already in the panel: the node card -> Change Profile -> the profile from step 1 with all its inbounds."
  remnawave::_node
  remnawave::_step "Internal squad" \
    "Internal Squads -> the squad of your users (Default-Squad) -> turn the new inbounds on -> Save."
  remnawave::_step "Subscription template" \
    "Templates -> Xray JSON -> a new template -> paste $out/subscription-xray-json.json -> Save."
  remnawave::_step "Hosts: Hosts -> Create new host, one per inbound; Advanced -> Xray JSON template: the one from step 4" \
    "${hosts[@]}"
  remnawave::_step "CDN resource (Timeweb)" \
    "Source: ${ORIGIN_IP:-<IP of this server>}:${NGINX_TLS_PORT:-8444}, HTTPS for the source on." \
    "Distribution domain $CDN_DOMAIN: a CNAME to the technical domain of the resource (*.cdn.twcstorage.ru), then Let's Encrypt in the Timeweb panel." \
    "Caching stays on; ignoring cache headers, always online and large file acceleration stay off."
  printf '\nObfuscation fields stay identical in the inbound and the host extra (remnawave/README.md).\n'
}

# Prints a step, then waits per remnawave::_guide.
remnawave::_step() {
  remnawave::_print "$@"
  if ((pause > 0)) && remnawave::_interactive; then
    printf '     %sPress Enter when done.%s ' "$UI_DIM" "$UI_RESET" >&2
    read -r _ || true
  fi
}

# Prints step TITLE with its LINEs, skipping the empty ones.
remnawave::_print() {
  local title="$1" line
  shift
  step=$((step + 1))
  printf '\n  %s%d. %s%s\n' "$bold" "$step" "$title" "$reset"
  for line in "$@"; do
    if [[ -n "$line" ]]; then
      printf '     %s\n' "$line"
    fi
  done
}

# Starts the node of step 2 on this server. Without a SECRET_KEY from .env, from the
# compose file of a node set up by hand or from the terminal, the node waits for one.
remnawave::_node() {
  if prompt::node "$(node::compose_value SECRET_KEY)" "$(node::compose_value NODE_PORT)"; then
    node::install
  else
    log::warn "no SECRET_KEY for the node: put SECRET_KEY and NODE_PORT from the docker-compose.yml that the panel shows into $ENV_FILE as NODE_SECRET_KEY and NODE_PORT, rerun ./deploy.sh"
  fi
}

remnawave::_interactive() {
  [[ -t 0 ]]
}
