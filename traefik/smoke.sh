#!/usr/bin/env bash
# Start a Traefik level with docker compose and prove it routes for real.
# Usage: ./smoke.sh l1|l2|l3|l4|lmax        (needs docker compose, curl, jq; binds :80/:443/:8080/:9000)
set -euo pipefail
cd "$(dirname "$0")"

level="${1:?usage: smoke.sh l1|l2|l3|l4|lmax}"
prefix=$level; [ "$level" = lmax ] && prefix=l-max
file=$(ls "$prefix"-*.yml)
dc() { docker compose -f "$file" "$@"; }
API=http://127.0.0.1:8080

cleanup() { dc down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*"; dc logs --tail 80 traefik 2>&1 || true; exit 1; }

# retry <desc> <command...>: poll up to 60s (providers need a moment to see containers)
retry() {
  local desc=$1; shift
  for _ in $(seq 1 60); do "$@" >/dev/null 2>&1 && { echo "ok   $desc"; return 0; }; sleep 1; done
  fail "$desc"
}
http_code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
code_is()   { [ "$(http_code "${@:2}")" = "$1" ]; }
body_has()  { curl -s "${@:2}" | grep -q -- "$1"; }
router_exists() { curl -fs "$API/api/http/routers" | jq -e --arg n "$1" 'map(.name) | index($n)' >/dev/null; }

case "$level" in
  l1)
    dc up -d --wait --wait-timeout 120
    retry "whoami routed by Host"      code_is 200 -H 'Host: whoami.localhost' http://127.0.0.1/
    retry "api routed by Host+Path"    code_is 200 -H 'Host: api.localhost' http://127.0.0.1/v1
    code_is 404 -H 'Host: nope.localhost' http://127.0.0.1/ || fail "unknown host should 404"; echo "ok   unknown host 404"
    retry "dashboard sees whoami"      router_exists whoami@docker
    ;;
  l2)
    BASIC_AUTH_USERS="admin:$(openssl passwd -apr1 ci-only-password)"
    export BASIC_AUTH_USERS
    dc up -d --wait --wait-timeout 120
    H='Host: app.example.com'
    retry "http redirects to https"    bash -c "c=\$(curl -s -o /dev/null -w '%{http_code}' -H '$H' http://127.0.0.1/); [ \$c = 301 ] || [ \$c = 308 ]"
    retry "https without creds is 401" code_is 401 -k --resolve app.example.com:443:127.0.0.1 https://app.example.com/
    code_is 200 -k --resolve app.example.com:443:127.0.0.1 -u admin:ci-only-password https://app.example.com/ || fail "valid creds rejected"
    echo "ok   valid creds accepted"
    code_is 401 -k --resolve app.example.com:443:127.0.0.1 -u admin:wrong https://app.example.com/ || fail "wrong creds accepted"
    echo "ok   wrong creds rejected"
    ;;
  l3)
    export CF_DNS_API_TOKEN=ci-only-not-a-token
    # Nothing listens here: ACME fails fast instead of contacting Let's Encrypt with example.com.
    export ACME_CA_SERVER=https://127.0.0.1:14000/dir
    dc up -d --wait --wait-timeout 120
    retry "webapp router loaded"       router_exists webapp@docker
    retry "api (wildcard) router loaded" router_exists api@docker
    curl -fs "$API/api/http/routers/webapp@docker" | jq -e '.tls.options == "hardened@file" and .tls.certResolver == "letsencrypt"' >/dev/null || fail "webapp tls options/resolver"
    curl -fs "$API/api/http/routers/api@docker"    | jq -e '.tls.certResolver == "letsencrypt-dns"' >/dev/null || fail "wildcard router must use the DNS-01 resolver"
    echo "ok   resolvers wired: HTTP-01 for the host, DNS-01 for the wildcard"
    # A router that names a TLS option which does not exist is disabled with an error.
    retry "hardened@file resolved (router enabled, no error)" bash -c "curl -fs $API/api/http/routers/webapp@docker | jq -e '.status == \"enabled\" and (.error // [] | length == 0)'"
    retry "http redirects to https"    bash -c "c=\$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: app.example.com' http://127.0.0.1/); [ \$c = 301 ] || [ \$c = 308 ]"
    ;;
  l4)
    dc up -d --wait --wait-timeout 120
    retry "backend-a via file provider" code_is 200 -H 'Host: a.localhost' http://127.0.0.1/
    retry "backend-b via file provider" code_is 200 -H 'Host: b.localhost' http://127.0.0.1/api
    retry "tcp router proxies raw TCP"  code_is 200 http://127.0.0.1:9000/
    n=$(for _ in $(seq 1 10); do curl -s -H 'Host: a.localhost' http://127.0.0.1/ | awk '/^Hostname:/{print $2}'; done | sort -u | wc -l)
    [ "$n" -eq 2 ] || fail "expected load balancing over 2 replicas, saw $n"; echo "ok   load balanced over 2 replicas"
    curl -si -H 'Host: a.localhost' http://127.0.0.1/ | grep -qi '^x-frame-options: DENY' || fail "secure-headers middleware not applied"
    echo "ok   secure-headers middleware applied"
    # hot reload: drop a new router file in, no restart
    cat > dynamic/zz-hot-reload-test.yml <<'YAML'
http:
  routers:
    hot:
      entryPoints: [web]
      rule: "Host(`hot.localhost`)"
      service: svc-backend-b
YAML
    trap 'rm -f dynamic/zz-hot-reload-test.yml; cleanup' EXIT
    retry "file provider hot reload"   code_is 200 -H 'Host: hot.localhost' http://127.0.0.1/
    ;;
  lmax)
    dc up -d --wait --wait-timeout 180
    retry "plugin-backed route answers" code_is 200 -H 'Host: app.localhost' http://127.0.0.1/
    out=$(curl -s -H 'Host: app.localhost' -H 'X-From-Cdn: lab-secret-rotate-me' \
          -H 'Cf-Connecting-Ip: 198.51.100.7' -H 'X-User-ID: root' http://127.0.0.1/)
    grep -qi '^X-Real-Ip: 198.51.100.7' <<<"$out" || fail "real-ip plugin did not set X-Real-Ip: $out"
    ! grep -qi '^X-User-Id:' <<<"$out" || fail "htransformation did not strip X-User-ID"
    grep -qi '^X-Request-Source: traefik-edge' <<<"$out" || fail "htransformation did not set X-Request-Source"
    echo "ok   real-ip trusted behind the secret CDN header; identity header stripped"
    spoof=$(curl -s -H 'Host: app.localhost' -H 'Cf-Connecting-Ip: 198.51.100.7' http://127.0.0.1/)
    ! grep -qi '^X-Real-Ip: 198.51.100.7' <<<"$spoof" || fail "spoofed Cf-Connecting-Ip was trusted without the secret header"
    echo "ok   spoofed Cf-Connecting-Ip ignored without the secret header"
    ;;
  *) echo "unknown level $level"; exit 2 ;;
esac

# Static config must not produce errors. Expected noise: ACME failures in l3 (no real CA) and the
# Docker provider retrying for a moment while the socket proxy starts (routers above prove it connected).
errs=$(dc logs traefik 2>&1 | grep -E ' ERR ' | grep -viE 'acme|certificate|letsencrypt|14000|docker-socket-proxy' || true)
[ -z "$errs" ] || fail "unexpected errors in traefik log: $errs"
echo "all $level smoke checks passed"
