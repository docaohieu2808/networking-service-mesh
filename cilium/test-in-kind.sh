#!/usr/bin/env bash
# Behavioural test of the l2 policies on a cluster that runs Cilium as its CNI.
# Proves the L7 allow-list works AND that the old `fromEntities: cluster` hole is gone:
# a pod in the same namespace that the policy does not name must be unable to connect.
# Usage: ./test-in-kind.sh   (current kube context must be the Cilium cluster)
set -euo pipefail
cd "$(dirname "$0")"

kubectl apply -f lab/test-workloads.yaml
kubectl -n production rollout status deploy/api-service --timeout=180s
kubectl -n production rollout status deploy/frontend --timeout=180s
kubectl -n production rollout status deploy/intruder --timeout=180s
# Baseline before any policy: if this fails the cluster network is broken, not the policies.
url=http://api-service.production.svc.cluster.local:8080
for _ in $(seq 1 30); do
  b=$(kubectl -n production exec deploy/frontend -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url/" 2>/dev/null || true)
  [ "$b" = "200" ] && break
  sleep 2
done
[ "$b" = "200" ] || { echo "FAIL baseline (no policy applied): got '$b'"; kubectl -n production exec deploy/frontend -- curl -sv --max-time 5 "$url/" 2>&1 | tail -10; kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>&1 | head -30; exit 1; }
echo "ok   baseline: frontend reaches api-service before any policy"
kubectl apply -f l2-network-policy-l7-http-dns-egress-ingress-cilium-network-policy.yaml
kubectl apply -f l3-host-firewall-clusterwide-network-policy-audit-mode.yaml   # schema check only: host firewall is off

url=http://api-service.production.svc.cluster.local:8080
code() { # pod  method  path  [extra curl args]
  local pod=$1 method=$2 path=$3; shift 3
  kubectl -n production exec "deploy/$pod" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X "$method" "$@" "$url$path" 2>/dev/null || true
}
expect() { # name want got
  if [ "$2" != "$3" ]; then
    echo "FAIL $1: want '$2' got '$3'"
    node=$(kubectl -n production get pod -l app=frontend -o jsonpath='{.items[0].spec.nodeName}')
    cpod=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName="$node" -o name)
    ( timeout 12 kubectl -n kube-system exec "$cpod" -c cilium-agent -- cilium-dbg monitor -t drop -t policy-verdict > /tmp/monitor.log 2>&1 & )
    sleep 2
    kubectl -n production exec deploy/frontend -- cat /etc/resolv.conf || true
    kubectl -n production exec deploy/frontend -- curl -sv --max-time 5 "$url/api/users" 2>&1 | tail -15 || true
    sleep 6; head -40 /tmp/monitor.log || true
    kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list 2>&1 | head -30 || true
    kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status 2>&1 | head -30 || true
    exit 1
  fi
  echo "ok   $1 ($3)"
}
eventually() { # name want pod method path [extra]  (policy takes a few seconds to reach the datapath)
  local name=$1 want=$2; shift 2
  for _ in $(seq 1 20); do
    [ "$(code "$@")" = "$want" ] && { echo "ok   $name ($want)"; return 0; }
    sleep 2
  done
  expect "$name" "$want" "$(code "$@")"
}

eventually "frontend GET /api/users is allowed"        200 frontend GET /api/users
expect     "frontend GET /admin is denied at L7"       403 "$(code frontend GET /admin)"
expect     "frontend DELETE without header is denied"  403 "$(code frontend DELETE /api/users/1)"
expect     "frontend DELETE with header is allowed"    200 "$(code frontend DELETE /api/users/1 -H 'X-Confirm-Delete: true')"
expect     "intruder (same namespace) cannot connect"  000 "$(code intruder GET /api/users)"
echo "all Cilium policy checks passed"
