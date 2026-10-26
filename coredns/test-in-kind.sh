#!/usr/bin/env bash
# Deploy the l2 Corefile as a second CoreDNS in the current kube context
# (CI: a kind cluster) and resolve in-cluster names through it.
# Never touches kube-system. Usage: ./test-in-kind.sh
set -euo pipefail
cd "$(dirname "$0")"

kubectl create namespace dns-lab --dry-run=client -o yaml | kubectl apply -f -
kubectl -n dns-lab create configmap coredns-lab \
  --from-file=Corefile="$(ls l2-*.Corefile)" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f lab/coredns-lab.yaml
kubectl -n dns-lab rollout status deployment/coredns-lab --timeout=180s

ip=$(kubectl -n dns-lab get svc coredns-lab -o jsonpath='{.spec.clusterIP}')
kubectl -n dns-lab delete pod dnsq --ignore-not-found >/dev/null
# Query the lab CoreDNS directly from a throw-away pod.
out=$(kubectl -n dns-lab run dnsq --rm -i --restart=Never --image=busybox:1.37 -- \
  nslookup kubernetes.default.svc.cluster.local "$ip" 2>&1) || { echo "$out"; kubectl -n dns-lab logs deploy/coredns-lab --tail=40; exit 1; }
echo "$out"
grep -q "Address: " <<<"$out" && echo "ok   cluster.local service resolved through the l2 Corefile"
