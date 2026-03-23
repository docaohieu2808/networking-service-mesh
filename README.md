# Networking & Service Mesh — Legacy Grouped Repository

Legacy grouped repository containing configurations for four networking tools: Cilium (eBPF), Linkerd (service mesh), HAProxy (load balancer), and CoreDNS (DNS). Each has been extracted into its own standalone repo — this repo is retained for reference and cross-tool examples.

## Repository Structure

```
networking-service-mesh/
├── cilium/     → see /home/hieudc/cilium for the full standalone repo
├── linkerd/    → see /home/hieudc/linkerd
├── haproxy/    → see /home/hieudc/haproxy
├── coredns/    → see /home/hieudc/coredns
├── istio/      (Istio configurations)
├── nginx/      (NGINX ingress configs)
└── traefik/    (Traefik reverse proxy configs)
```

## Standalone Repos (preferred)

For full documentation and all levels, use the dedicated repos:

| Tool | Standalone Repo | Description |
|------|----------------|-------------|
| Cilium | `/home/hieudc/cilium` | eBPF networking, L7 policy, Hubble observability |
| Linkerd | `/home/hieudc/linkerd` | Lightweight service mesh, mTLS, golden metrics |
| HAProxy | `/home/hieudc/haproxy` | TCP/HTTP load balancer, ACLs, rate limiting |
| CoreDNS | `/home/hieudc/coredns` | Kubernetes DNS, stub zones, DNSSEC |

## Contents of This Repo

### Cilium
- `cilium/l1-install-helm-values-kubeproxy-replacement-hubble-enabled.yaml` — Helm install: kube-proxy replacement + Hubble
- `cilium/l2-network-policy-l7-http-dns-egress-ingress-cilium-network-policy.yaml` — L7 CiliumNetworkPolicy
- `cilium/l-max-ebpf-custom-xdp-packet-filter-rate-limit-program.c` — Custom XDP eBPF rate limiter

### Linkerd
- `linkerd/l1-install-inject-control-plane-namespace-annotation.yaml` — Control plane Helm values + injection
- `linkerd/l2-service-profile-retry-timeout-per-route-traffic-policy.yaml` — ServiceProfile, AuthorizationPolicy, HTTPRoute

### HAProxy
- `haproxy/l1-basic-tcp-http-proxy-frontend-backend-stats.cfg` — Frontend/backend/stats, TLS termination
- `haproxy/l2-advanced-acl-backends-rate-limit-stick-table-http-rewrite.cfg` — ACLs, stick tables, CORS

### CoreDNS
- `coredns/l1-basic-dns-server-forward-cache-health-corefile.Corefile` — Forward, cache, health
- `coredns/l2-kubernetes-service-discovery-k8s-plugin-stub-zones-corefile.Corefile` — K8s plugin, stub zones
- `coredns/l-max-custom-plugin-rewrite-chaos-etcd-corefile.Corefile` — Rewrite, ACL, etcd, DNSSEC

## Prerequisites

Refer to the standalone repo READMEs for tool-specific prerequisites.

## Quick Start

```bash
# Cilium — install on Kubernetes
helm install cilium cilium/cilium --namespace kube-system \
  -f cilium/l1-install-helm-values-kubeproxy-replacement-hubble-enabled.yaml

# Linkerd — install control plane
linkerd install --crds | kubectl apply -f -
helm install linkerd-control-plane linkerd/linkerd-control-plane \
  -f linkerd/l1-install-inject-control-plane-namespace-annotation.yaml

# HAProxy — local Docker test
docker run --rm -v $(pwd)/haproxy/l1-basic-tcp-http-proxy-frontend-backend-stats.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  -p 80:80 -p 8404:8404 haproxy:2.9-alpine

# CoreDNS — local Docker test
docker run --rm -v $(pwd)/coredns/l1-basic-dns-server-forward-cache-health-corefile.Corefile:/Corefile:ro \
  -p 53:53/udp coredns/coredns:latest
```

## Tool Selection Guide

| Use case | Tool |
|----------|------|
| K8s pod networking + network policy | Cilium |
| mTLS + golden metrics between services | Linkerd |
| External load balancing, TLS termination | HAProxy |
| Custom cluster DNS, stub zones | CoreDNS |
| Full service mesh (mTLS + traffic mgmt + observability) | Linkerd or Istio |
