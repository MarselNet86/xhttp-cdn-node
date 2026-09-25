# shellcheck shell=bash
# Post-install check from the bottom up (tech.md §5): xray on the loopback, origin nginx,
# the xhttp path through nginx, then the CDN edge the way clients reach it. Stops at the
# first broken layer with exit 8 and says what to fix there.

set -euo pipefail

# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=node.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/node.sh"

validate::layers() {
  require::cmd curl jq openssl
  env::require CDN_DOMAIN XHTTP_PORT XHTTP_PATH NGINX_TLS_PORT ORIGIN_IP
  validate::_origin_ip
  validate::_xray
  validate::_origin
  validate::_xhttp
  validate::_cdn
  log::info "all layers pass: xray, origin nginx, xhttp path, CDN edge"
}

# --- layers -----------------------------------------------------------------------------

# Layer 1: the inbound that the panel pushed listens on the loopback. A node that runs here
# gets time to start xray, and a failure names its cause.
validate::_xray() {
  local addrs
  if ! validate::_listening "$XHTTP_PORT" && ! validate::_wait_node; then
    validate::_fail 1 xray "nothing listens on 127.0.0.1:$XHTTP_PORT: $(validate::_node_cause)"
  fi
  if command -v ss >/dev/null 2>&1; then
    addrs="$(ss -Hltn "sport = :$XHTTP_PORT" 2>/dev/null | awk '{print $4}' || true)"
    if [[ -n "$addrs" ]] && grep -qvE '^127\.0\.0\.1:' <<<"$addrs"; then
      log::warn "port $XHTTP_PORT listens beyond the loopback ($(paste -sd' ' <<<"$addrs")): set listen 127.0.0.1 in the inbound, TLS ends on nginx"
    fi
  fi
  log::info "layer 1 (xray): 127.0.0.1:$XHTTP_PORT accepts connections"
}

# Layer 2: origin nginx answers /cdn-check with 204 and its marker header.
validate::_origin() {
  local headers
  headers="$(validate::_origin_request /cdn-check)" ||
    validate::_fail 2 "origin nginx" "no answer on 127.0.0.1:$NGINX_TLS_PORT: see systemctl status nginx"
  if [[ "$(validate::_status "$headers")" != 204 ]] || ! validate::_has_header "$headers" X-CDN-Origin; then
    validate::_fail 2 "origin nginx" "/cdn-check gave $(validate::_status "$headers") without X-CDN-Origin, not 204: nginx does not serve the cdn-deploy site, rerun ./deploy.sh"
  fi
  log::info "layer 2 (origin nginx): /cdn-check on :$NGINX_TLS_PORT gives 204"
}

# Layer 3: the xhttp path reaches xray. A request without a session gets 400 carrying the
# padding header of the inbound.
validate::_xhttp() {
  local inbound="$REPO_ROOT/out/remnawave/inbound-xhttp-cdn.json" header headers status
  header="$(jq -r '.streamSettings.xhttpSettings.extra.xPaddingHeader // empty' "$inbound" 2>/dev/null || true)"
  [[ -n "$header" ]] || validate::_fail 3 "xhttp path" "no xPaddingHeader in $inbound: rerun ./deploy.sh"
  headers="$(validate::_origin_request "${XHTTP_PATH}test")" ||
    validate::_fail 3 "xhttp path" "no answer from nginx for ${XHTTP_PATH}test"
  status="$(validate::_status "$headers")"
  case "$status" in
    400)
      validate::_has_header "$headers" "$header" ||
        validate::_fail 3 "xhttp path" "xray answered 400 without the $header padding header: the inbound in the panel differs from out/remnawave/inbound-xhttp-cdn.json"
      ;;
    404) validate::_fail 3 "xhttp path" "xray answered 404: XHTTP_PATH ($XHTTP_PATH) or the inbound host ($CDN_DOMAIN) differs from the panel" ;;
    502 | 504) validate::_fail 3 "xhttp path" "nginx cannot reach xray on 127.0.0.1:$XHTTP_PORT ($status)" ;;
    *) validate::_fail 3 "xhttp path" "${XHTTP_PATH}test gave $status, not 400 with the $header padding header" ;;
  esac
  # Timeweb forwards XHTTP_PATH without its trailing slash; it has to reach xray as well.
  headers="$(validate::_origin_request "${XHTTP_PATH%/}")" ||
    validate::_fail 3 "xhttp path" "no answer from nginx for ${XHTTP_PATH%/}"
  status="$(validate::_status "$headers")"
  if [[ "$status" != 400 ]] || ! validate::_has_header "$headers" "$header"; then
    validate::_fail 3 "xhttp path" "${XHTTP_PATH%/} gave $status, not 400 with $header: nginx does not pass the path without its trailing slash, which Timeweb sends, rerun ./deploy.sh"
  fi
  log::info "layer 3 (xhttp path): xray answers ${XHTTP_PATH} and ${XHTTP_PATH%/} through nginx with 400 and $header"
}

# Layer 4: the CDN edge, as clients see it. curl checks the edge certificate against
# CDN_DOMAIN, the query defeats caches, and the marker header proves the origin answered.
validate::_cdn() {
  local headers rc=0 status
  headers="$(validate::_request "https://$CDN_DOMAIN/cdn-check?nocache=$RANDOM$RANDOM")" || rc=$?
  case "$rc" in
    0) ;;
    6) validate::_fail 4 "CDN edge" "$CDN_DOMAIN does not resolve: add the CNAME from the CDN resource to DNS" ;;
    7 | 28) validate::_fail 4 "CDN edge" "no connection to $CDN_DOMAIN:443: check the CNAME and that the CDN resource is active" ;;
    35) validate::_fail 4 "CDN edge" "TLS handshake with $CDN_DOMAIN failed: the CDN has no certificate for it yet" ;;
    60) validate::_fail 4 "CDN edge" "the edge presents a certificate that does not cover $CDN_DOMAIN ($(validate::_edge_cert)): attach a certificate for $CDN_DOMAIN to the CDN resource, the change takes up to 30 minutes" ;;
    *) validate::_fail 4 "CDN edge" "curl failed with exit $rc on https://$CDN_DOMAIN/cdn-check" ;;
  esac
  status="$(validate::_status "$headers")"
  case "$status" in
    204)
      validate::_has_header "$headers" X-CDN-Origin ||
        validate::_fail 4 "CDN edge" "204 without X-CDN-Origin: the answer did not come from this origin, check the resource's origin and caching"
      ;;
    451) validate::_fail 4 "CDN edge" "451: the CDN blocks $CDN_DOMAIN for legal reasons. A config change will not help, move to a new domain" ;;
    502 | 504) validate::_fail 4 "CDN edge" "$status: the CDN cannot reach the origin. The resource's origin must be $ORIGIN_IP:$NGINX_TLS_PORT over HTTPS, with the port open" ;;
    503) validate::_fail 4 "CDN edge" "503: the CDN reports overload or a disabled resource" ;;
    403) validate::_fail 4 "CDN edge" "403: the CDN refuses the request. Check that the resource is active and allows GET" ;;
    *) validate::_fail 4 "CDN edge" "/cdn-check through the CDN gave $status, not 204" ;;
  esac
  log::info "layer 4 (CDN edge): https://$CDN_DOMAIN/cdn-check gives 204 from this origin"
}

# ORIGIN_IP is where the CDN resource sends traffic, so it should point at this host.
validate::_origin_ip() {
  local public
  if hostname -I 2>/dev/null | tr ' ' '\n' | grep -qxF "$ORIGIN_IP"; then
    return 0
  fi
  public="$(curl -4 -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)"
  if [[ "$public" != "$ORIGIN_IP" ]]; then
    log::warn "ORIGIN_IP=$ORIGIN_IP is not an address of this host, whose public IPv4 is ${public:-unknown}: the CDN resource may send traffic elsewhere"
  fi
}

# --- helpers ----------------------------------------------------------------------------

validate::_fail() {
  log::die "$EXIT_VALIDATE" "layer $1 ($2) failed: $3"
}

validate::_listening() {
  timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null
}

# The panel starts xray once it reaches a node, so a node container that runs here gets
# CDN_DEPLOY_NODE_WAIT seconds (60; tests cut it) to open the port. A failure in its log
# ends the wait.
validate::_wait_node() {
  local wait="${CDN_DEPLOY_NODE_WAIT:-60}" waited=0
  if [[ "$(validate::_node_state)" != running ]]; then
    return 1
  fi
  log::info "waiting up to ${wait}s for xray on the node to open 127.0.0.1:$XHTTP_PORT"
  while ((waited < wait)); do
    sleep 2
    waited=$((waited + 2))
    if validate::_listening "$XHTTP_PORT"; then
      return 0
    fi
    if [[ -n "$(validate::_node_error)" ]]; then
      return 1
    fi
  done
  return 1
}

# Why no xray listens: no node here yet, a node that does not see the Hysteria2
# certificate, an error in the node log, a stopped container, or a panel that has not
# started the inbound.
validate::_node_cause() {
  local state error absent="no Docker" tag="VLESS-XHTTP-CDN${NODE_NAME:+-${NODE_NAME^^}}"
  state="$(validate::_node_state)"
  error="$(validate::_node_error)"
  if command -v docker >/dev/null 2>&1; then
    absent="no $NODE_CONTAINER container"
  fi
  if [[ -z "$state" ]]; then
    printf 'no node runs here yet (%s): create it in the panel (steps 1 and 2 above), give ./deploy.sh its SECRET_KEY there or as NODE_SECRET_KEY in .env, rerun ./deploy.sh' \
      "$absent"
  elif [[ -n "${HY2_DOMAIN:-}" ]] &&
    ! docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$NODE_CONTAINER" 2>/dev/null | grep -qw /etc/letsencrypt; then
    printf 'the %s container does not see /etc/letsencrypt, so xray stops on the Hysteria2 certificate: rerun ./deploy.sh, it rewrites %s with the volume /etc/letsencrypt:/etc/letsencrypt:ro' \
      "$NODE_CONTAINER" "$NODE_COMPOSE"
  elif [[ "$error" == *SECRET_KEY* ]]; then
    printf 'the node rejects its SECRET_KEY (docker logs %s): copy it again from the panel into NODE_SECRET_KEY in .env, rerun ./deploy.sh' "$NODE_CONTAINER"
  elif [[ -n "$error" ]]; then
    printf 'xray on the node fails: %s (docker logs %s)' "$error" "$NODE_CONTAINER"
  elif [[ "$state" != running ]]; then
    printf 'the %s container is %s: docker logs %s says why' "$NODE_CONTAINER" "$state" "$NODE_CONTAINER"
  else
    printf 'the node runs, but xray has no %s: check in the panel that the node is online (the panel reaches NODE_PORT %s) with this inbound on, rerun ./deploy.sh' \
      "$tag" "${NODE_PORT:-2222}"
  fi
}

# The state of the node container (running, restarting, exited...), empty without one.
validate::_node_state() {
  if command -v docker >/dev/null 2>&1; then
    docker inspect -f '{{.State.Status}}' "$NODE_CONTAINER" 2>/dev/null || true
  fi
}

# The latest failure in the node log: a rejected SECRET_KEY, or the last link of the error
# chain of a failed xray start ("... > open /etc/...: no such file or directory").
validate::_node_error() {
  local line
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  line="$(docker logs --tail 200 "$NODE_CONTAINER" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' |
    grep -E 'Failed to start Xray|SECRET_KEY (INVALID|payload|missing|contains)|Invalid SECRET_KEY' |
    tail -n 1 || true)"
  if [[ "$line" == *SECRET_KEY* ]]; then
    printf 'SECRET_KEY rejected'
  elif [[ -n "$line" ]]; then
    line="${line#*Failed to start Xray: }"
    printf '%s' "${line##* > }"
  fi
}

# Headers of a GET, CR stripped; returns curl's exit code.
validate::_request() {
  local out rc=0
  out="$(curl -s -o /dev/null -D - --max-time 10 "$@")" || rc=$?
  printf '%s' "${out//$'\r'/}"
  return "$rc"
}

# Origin requests skip DNS and certificate checks: the origin certificate may name
# VLESS_DOMAIN, and layer 4 covers what clients see.
validate::_origin_request() {
  validate::_request -k --resolve "$CDN_DOMAIN:$NGINX_TLS_PORT:127.0.0.1" \
    "https://$CDN_DOMAIN:$NGINX_TLS_PORT$1"
}

validate::_status() {
  local line
  line="$(head -n 1 <<<"$1")"
  line="${line#* }"
  printf '%s' "${line%% *}"
}

validate::_has_header() {
  grep -qi "^$2:" <<<"$1"
}

validate::_edge_cert() {
  openssl s_client -connect "$CDN_DOMAIN:443" -servername "$CDN_DOMAIN" </dev/null 2>/dev/null |
    openssl x509 -noout -subject -ext subjectAltName 2>/dev/null | tr -s '\n ' ' ' | sed 's/ $//' ||
    echo "certificate unreadable"
}
