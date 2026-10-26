#!/usr/bin/env bash
# Apply every Istio manifest in this directory to a cluster that already runs Istio
# (ambient profile via the Helm values in l1, plus the l1c ingress gateway) and prove
# the behaviour for real:
#   - sidecar mode:  the l2 canary VirtualService splits ~90/10 and header-routes to v2; the l3 Gateway
#                    terminates TLS per SNI host and redirects HTTP; namespace deny-all blocks, an explicit ALLOW opens one path,
#                    and the l-max Lua EnvoyFilter modifies a live response
#   - ambient mode:  a namespace with no sidecars still gets mTLS (HBONE) via ztunnel
#   - Gateway API:   the l3b Gateway and waypoint get their proxies
# Usage: ./test-in-kind.sh   (CI installs Istio first, see .github/workflows/ci.yml)
set -euo pipefail
cd "$(dirname "$0")"

fail() { echo "FAIL: $*"; exit 1; }
curl_in() { # namespace deploy args...
  local ns=$1 dep=$2; shift 2
  kubectl -n "$ns" exec "deploy/$dep" -c curl -- curl -s --max-time 8 "$@"
}

echo "== workloads"
kubectl apply -f lab/sidecar-workloads.yaml -f lab/app-service-backend.yaml
kubectl -n production rollout status deploy/api-service --timeout=240s
kubectl -n production rollout status deploy/reviews-v1 --timeout=240s
kubectl -n production rollout status deploy/reviews-v2 --timeout=240s
kubectl -n production rollout status deploy/app-service --timeout=240s
kubectl -n production rollout status deploy/test-client --timeout=240s
for d in api-service test-client; do
  n=$(kubectl -n production get pod -l app=$d -o jsonpath='{.items[0].spec.containers[*].name}' | wc -w)
  init=$(kubectl -n production get pod -l app=$d -o jsonpath='{.items[0].spec.initContainers[*].name}')
  # With istio-cni the sidecar is a native sidecar (an init container) or a second container.
  { [ "$n" -ge 2 ] || grep -q istio-proxy <<<"$init"; } || fail "$d was not injected with a sidecar"
done
echo "ok   sidecars injected"

echo "== manifests"
kubectl apply -f lab/referenced-services.yaml
lab/make-tls-secrets.sh
kubectl apply -f l1-telemetry-tracing-access-log-telemetry-api.yaml
kubectl apply -f l2-virtual-service-destination-rule-traffic-splitting-canary.yaml

echo "== l2 canary: weighted split and header routing (before l4 deny-all is applied)"
split() { # n [curl args]: prints "<v1 count> <v2 count>" for n requests from test-client to reviews
  local n=$1; shift
  kubectl -n production exec deploy/test-client -c curl -- sh -c \
    "for i in \$(seq $n); do curl -s --max-time 5 $* http://reviews.production.svc.cluster.local:8080/ | sed -n 's/^Name: //p'; done" \
    | sort | uniq -c | awk '{c[$2]=$1} END {print c["reviews-v1"]+0, c["reviews-v2"]+0}'
}
for _ in $(seq 1 30); do # wait until the sidecar has the VirtualService: header routing then sends everything to v2
  read -r h1 h2 <<<"$(split 5 -H 'x-canary:true')"
  [ "$h1" -eq 0 ] && [ "$h2" -eq 5 ] && break
  sleep 2
done
if [ "$h1" -ne 0 ] || [ "$h2" -ne 5 ]; then fail "x-canary: true did not route all requests to v2 (v1=$h1 v2=$h2)"; fi
echo "ok   header x-canary: true routes 5/5 requests to v2"
read -r v1 v2 <<<"$(split 200)"
echo "     200 requests: v1=$v1 v2=$v2 (weights 90/10)"
[ $((v1 + v2)) -eq 200 ] || fail "lost requests in the split test (v1=$v1 v2=$v2)"
# Binomial(200, 0.1): mean 20, sd 4.2. [5, 40] is more than 3.5 sd either side, so a correct 90/10 split does not flake,
# while 50/50 (round robin without weights) or 100/0 fails.
if [ "$v2" -lt 5 ] || [ "$v2" -gt 40 ]; then fail "canary split is not roughly 90/10 (v1=$v1 v2=$v2)"; fi
echo "ok   weighted canary: v2 got ${v2}/200 requests (~10%)"

kubectl apply -f l3-gateway-tls-termination-sni-routing-multi-host.yaml

echo "== l3 Gateway: TLS termination by SNI and HTTP redirect (through the ingress gateway, before l4/l-max: l-max sends gateway traffic to an ext-authz provider that does not exist here)"
tmp=$(mktemp -d)
pf_pid=""
trap '[ -z "$pf_pid" ] || kill "$pf_pid" 2>/dev/null; rm -rf "$tmp"' EXIT
kubectl -n istio-system get secret app-example-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "$tmp/ca.crt"
kubectl -n istio-system port-forward svc/istio-ingressgateway 8443:443 >/dev/null 2>&1 &
pf_pid=$!
res=app.example.com:8443:127.0.0.1
body=""
for _ in $(seq 1 30); do
  body=$(curl -sS --max-time 5 --cacert "$tmp/ca.crt" --resolve "$res" https://app.example.com:8443/ 2>/dev/null) && break
  sleep 2
done
grep -q '^Name: app-service' <<<"$body" || { echo "$body"; curl -svk --max-time 5 --resolve "$res" https://app.example.com:8443/ 2>&1 | tail -30 || true; kubectl -n istio-system logs deploy/istio-ingressgateway --tail=20 || true; fail "https://app.example.com through the gateway was not routed to app-service"; }
echo "ok   SNI app.example.com: TLS verified against the Secret's certificate, routed to app-service"
# A name the Gateway has no server entry for: even with verification off (-k) the handshake must be refused,
# so this proves the gateway selects its server by SNI rather than answering everything with one certificate.
if curl -sSk --max-time 5 --resolve other.example.com:8443:127.0.0.1 https://other.example.com:8443/ >/dev/null 2>&1; then
  fail "a host with no Gateway server entry was served over TLS"
fi
echo "ok   unknown SNI other.example.com is not served"
kill "$pf_pid" 2>/dev/null || true
kubectl -n istio-system port-forward svc/istio-ingressgateway 8080:80 >"$tmp/pf-http.log" 2>&1 &
pf_pid=$!
redirect=""
for _ in $(seq 1 15); do
  redirect=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code} %{redirect_url}' --resolve app.example.com:8080:127.0.0.1 http://app.example.com:8080/ 2>&1) || true
  case "$redirect" in 301*) break ;; esac
  sleep 2
done
grep -q '^301 https://app.example.com' <<<"$redirect" || { cat "$tmp/pf-http.log"; fail "HTTP did not redirect to HTTPS (got: $redirect)"; }
echo "ok   plain HTTP is redirected to HTTPS (301)"
kill "$pf_pid" 2>/dev/null || true; pf_pid=""

kubectl apply -f l4-authorization-policy-mtls-peer-authentication-rbac.yaml
kubectl apply -f l-max-envoy-filter-wasm-custom-lua-http-filter.yaml
# The WasmPlugin points at a placeholder image: validate against the CRD, do not run it.
kubectl apply --dry-run=server -f l-max-wasm-plugin-oci-module-placeholder.yaml
echo "ok   all manifests accepted by the API server"

istioctl analyze -A --failure-threshold Error || fail "istioctl analyze reported errors"
echo "ok   istioctl analyze: no errors"

echo "== sidecar: deny-all, then an explicit allow"
# Wait until the proxy has the deny-all (RBAC denied returns 403 with this body).
denied=""
for _ in $(seq 1 30); do
  denied=$(curl_in production test-client -o /dev/null -w '%{http_code}' http://api-service.production:8080/ || true)
  [ "$denied" = "403" ] && break
  sleep 2
done
[ "$denied" = "403" ] || fail "namespace deny-all did not block test-client (got $denied)"
echo "ok   deny-all blocks test-client (403)"

kubectl apply -f lab/allow-test-client.yaml
ok=""
for _ in $(seq 1 30); do
  ok=$(curl_in production test-client -o /dev/null -w '%{http_code}' http://api-service.production:8080/ || true)
  [ "$ok" = "200" ] && break
  sleep 2
done
[ "$ok" = "200" ] || fail "allow-test-client did not open the path (got $ok)"
echo "ok   explicit ALLOW opens exactly that path (200)"

hdr=$(curl_in production test-client -D - -o /dev/null http://api-service.production:8080/ | tr -d '\r')
grep -qi '^x-served-by: envoy-lua' <<<"$hdr" || { echo "$hdr"; fail "Lua EnvoyFilter did not add x-served-by"; }
echo "ok   Lua EnvoyFilter rewrote a live response (x-served-by: envoy-lua)"

echo "== ambient: mTLS without sidecars"
kubectl apply -f lab/ambient-workloads.yaml
kubectl -n ambient-demo rollout status deploy/echo --timeout=240s
kubectl -n ambient-demo rollout status deploy/client --timeout=240s
c=$(kubectl -n ambient-demo get pod -l app=echo -o jsonpath='{.items[0].spec.containers[*].name}' | wc -w)
[ "$c" -eq 1 ] || fail "ambient pod has $c containers: a sidecar was injected"
code=""
for _ in $(seq 1 30); do
  code=$(curl_in ambient-demo client -o /dev/null -w '%{http_code}' http://echo.ambient-demo/ || true)
  [ "$code" = "200" ] && break
  sleep 2
done
[ "$code" = "200" ] || fail "ambient request failed (got $code)"
istioctl ztunnel-config workloads 2>/dev/null | grep -E 'ambient-demo.*(echo|client)' | grep -q HBONE \
  || { istioctl ztunnel-config workloads || true; fail "ztunnel does not show HBONE for the ambient workloads"; }
echo "ok   ambient namespace: 1 container per pod, traffic carried over HBONE"

echo "== Gateway API (l3b)"
kubectl apply -f l3b-gateway-api-httproute-waypoint.yaml
kubectl -n gateway-api-demo rollout status deploy/echo --timeout=240s
kubectl -n gateway-api-demo rollout status deploy/web-istio --timeout=240s
kubectl -n gateway-api-demo rollout status deploy/waypoint --timeout=240s
accepted=$(kubectl -n gateway-api-demo get httproute echo -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')
[ "$accepted" = "True" ] || fail "HTTPRoute not accepted by Istio (status: $accepted)"
echo "ok   Istio provisioned the Gateway and waypoint proxies, HTTPRoute accepted"

echo "all Istio checks passed"
