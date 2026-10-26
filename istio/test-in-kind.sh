#!/usr/bin/env bash
# Apply every Istio manifest in this directory to a cluster that already runs Istio
# (ambient profile via the Helm values in l1, plus the l1c ingress gateway) and prove
# the behaviour for real:
#   - sidecar mode:  namespace deny-all blocks, an explicit ALLOW opens one path,
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
kubectl apply -f lab/sidecar-workloads.yaml
kubectl -n production rollout status deploy/api-service --timeout=240s
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
kubectl apply -f l3-gateway-tls-termination-sni-routing-multi-host.yaml
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
