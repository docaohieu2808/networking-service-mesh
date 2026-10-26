#!/usr/bin/env bash
# Apply the Linkerd manifests to a cluster that already runs the Linkerd control
# plane (CI installs it from the edge Helm charts) and check what they promise:
#   - pods get the proxy through namespace injection
#   - the Server + AuthorizationPolicy let ONLY the frontend ServiceAccount through
#   - the Gateway API HTTPRoute splits traffic by path
# Usage: ./test-in-kind.sh
set -euo pipefail
cd "$(dirname "$0")"

fail() { echo "FAIL: $*"; exit 1; }
curl_in() { # deploy args...
  local dep=$1; shift
  kubectl -n production exec "deploy/$dep" -c curl -- curl -s --max-time 8 "$@"
}

kubectl apply -f l1b-namespace-and-workload-manifests.yaml
kubectl apply -f l2-service-profile-retry-timeout-per-route-traffic-policy.yaml
kubectl apply -f lab/test-clients.yaml
for d in api-service api-service-v1 api-service-v2 frontend other; do
  kubectl -n production rollout status "deploy/$d" --timeout=240s
done

for d in api-service frontend other; do
  names=$(kubectl -n production get pod -l app=$d -o jsonpath='{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}')
  grep -q linkerd-proxy <<<"$names" || fail "$d has no linkerd-proxy (containers: $names)"
done
echo "ok   namespace injection added linkerd-proxy to every pod"

want() { # name want-code deploy url
  local got=""
  for _ in $(seq 1 30); do
    got=$(curl_in "$3" -o /dev/null -w '%{http_code}' "$4" || true)
    [ "$got" = "$2" ] && { echo "ok   $1 ($got)"; return 0; }
    sleep 2
  done
  fail "$1: want $2 got $got"
}
want "frontend (allowed identity) reaches api-service" 200 frontend http://api-service-direct.production:8080/
want "other service account is refused"                403 other    http://api-service-direct.production:8080/

# The HTTPRoute is client-side: the request is sent to the v2 backend, whose whoami name is v2.
for _ in $(seq 1 30); do
  body=$(curl_in frontend http://api-service.production:8080/api/v2/ping || true)
  grep -q '^Name: v2' <<<"$body" && break
  sleep 2
done
grep -q '^Name: v2' <<<"$body" || { echo "$body"; fail "HTTPRoute did not send /api/v2 to api-service-v2"; }
body=$(curl_in frontend http://api-service.production:8080/api/v1/ping)
grep -q '^Name: v1' <<<"$body" || { echo "$body"; fail "HTTPRoute did not send /api/v1 to api-service-v1"; }
echo "ok   HTTPRoute sends /api/v1 and /api/v2 to different backends"

echo "all Linkerd checks passed"
