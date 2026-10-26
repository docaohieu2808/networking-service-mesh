#!/usr/bin/env bash
# Apply the Linkerd manifests to a cluster that already runs the Linkerd control
# plane (CI installs it from the edge Helm charts) and check what they promise:
#   - pods get the proxy through namespace injection
#   - the Server + AuthorizationPolicy let ONLY the frontend ServiceAccount through
#   - the Gateway API HTTPRoute splits traffic by path and retries 5xx responses
#   - the ServiceProfile applies a different timeout per route (GET 3s cuts a slow answer, POST 8s lets it through)
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

# ServiceProfile per-route timeouts (reviews-service): GET /reviews has timeout 3s, POST /reviews has 8s.
# whoami sleeps for ?wait=, so a 6s answer is cut by the proxy (504) on GET but allowed on POST.
rv=http://reviews-service.production:8080/reviews
code=$(curl_in frontend --max-time 15 -o /dev/null -w '%{http_code}' "$rv?wait=1s") || true
[ "$code" = "200" ] || fail "GET /reviews?wait=1s: want 200 got $code"
start=$(date +%s)
code=$(curl_in frontend --max-time 15 -o /dev/null -w '%{http_code}' "$rv?wait=6s") || true
took=$(( $(date +%s) - start ))
[ "$code" = "504" ] || fail "GET /reviews?wait=6s: want 504 from the 3s route timeout, got $code after ${took}s"
[ "$took" -lt 6 ] || fail "GET /reviews timed out after ${took}s, so the 3s route timeout did not cut it"
code=$(curl_in frontend --max-time 15 -X POST -o /dev/null -w '%{http_code}' "$rv?wait=6s") || true
[ "$code" = "200" ] || fail "POST /reviews?wait=6s: want 200 under the 8s route timeout, got $code"
echo "ok   ServiceProfile timeouts are per route (GET cut at 3s -> 504, POST allowed 6s -> 200)"

# HTTPRoute retries (retry.linkerd.io/http=5xx, limit=2): make both backends answer /health with 500, send ONE GET
# through the api-service Service (the catch-all rule, 90/10 split) and count what the backends received: with
# retries 1 request + 2 retries = 3 hits; with no retries it would be 1.
# whoami --verbose logs each request twice (outer mux + handler), so two log lines are one request.
hits() { # total GET /health requests received by the two backends
  local n=0 d c
  for d in api-service-v1 api-service-v2; do
    c=$(kubectl -n production logs "deploy/$d" -c app | grep -c '"GET /health ' || true)
    n=$((n + c))
  done
  echo $((n / 2))
}
for svc in api-service-v1 api-service-v2; do
  code=$(curl_in frontend -X POST -d 500 -o /dev/null -w '%{http_code}' "http://$svc.production:8080/health") || true
  [ "$code" = "200" ] || fail "could not set $svc /health to 500 (got $code)"
done
before=$(hits)
code=$(curl_in frontend -o /dev/null -w '%{http_code}' http://api-service.production:8080/health) || true
[ "$code" = "500" ] || fail "GET /health through the HTTPRoute: want the backend's 500, got $code"
sleep 2
after=$(hits)
got=$((after - before))
[ "$got" -eq 3 ] || fail "one failing request produced $got backend hits, want 3 (1 + 2 retries from retry.linkerd.io/limit)"
echo "ok   HTTPRoute retries a 5xx twice (1 request -> $got backend hits)"

echo "all Linkerd checks passed"
