# networking-service-mesh

Networking and service mesh configs across the full stack: reverse proxies (nginx + OpenResty), load balancers (HAProxy), ingress (Traefik v3), service meshes (Istio, Linkerd), eBPF networking (Cilium + XDP), and DNS (CoreDNS).

Broadest coverage in the repo cluster — good for "explain the layers of k8s networking" interview questions.

## Tier map

### nginx
| Tier | Path | What it covers |
|------|------|----------------|
| l1–l4 | `nginx/` | Basic reverse proxy → SSL termination → upstream health checks → OpenResty Lua JWT auth |

### HAProxy
| Tier | Path | What it covers |
|------|------|----------------|
| l1–l-max | `haproxy/` | TCP/HTTP load balancing, ACLs, stats, health checks |

### Traefik
| Tier | Path | What it covers |
|------|------|----------------|
| l1–l5 | `traefik/` | Static config, dynamic routing, middleware, TLS (ACME HTTP-01), dashboard |

### Istio
| Tier | Path | What it covers |
|------|------|----------------|
| l1 | `istio/l1-install-profile-minimal-demo-ambient-helm-values.yaml` | IstioOperator / Helm values — install profiles, tracing, mTLS, HPA |
| l2 | `istio/l2-virtual-service-destination-rule-traffic-splitting-canary.yaml` | Traffic splitting + canary via VirtualService + DestinationRule |
| l3 | `istio/l3-gateway-tls-termination-sni-routing-multi-host.yaml` | Gateway TLS + SNI-based multi-host routing |
| l4 | `istio/l4-authorization-policy-mtls-peer-authentication-rbac.yaml` | AuthorizationPolicy + PeerAuthentication (STRICT mTLS + RBAC) |
| l-max | `istio/l-max-envoy-filter-wasm-custom-lua-http-filter.yaml` | EnvoyFilter — Wasm + Lua HTTP filter extensibility |

### Linkerd
| Tier | Path | What it covers |
|------|------|----------------|
| l1–l-max | `linkerd/` | ServiceProfile, TrafficSplit, policy, SMI |

### Cilium
| Tier | Path | What it covers |
|------|------|----------------|
| l1–l-max | `cilium/` | NetworkPolicy, CiliumNetworkPolicy, eBPF/XDP C program skeleton |

### CoreDNS
| Tier | Path | What it covers |
|------|------|----------------|
| l1 | `coredns/` | Corefile with forward, cache, health, rewrite plugins |

## Run

Istio (Helm, recommended for GitOps):
```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts && helm repo update
helm install istio-base istio/base -n istio-system --create-namespace
helm install istiod istio/istiod -n istio-system \
  -f istio/l1-install-profile-minimal-demo-ambient-helm-values.yaml --wait
```

Traefik:
```bash
docker compose -f traefik/l1-traefik-static-config/docker-compose.yml up -d
```

## Interview talking points

- **Istio vs Linkerd**: Istio = full-featured (traffic management, WASM extensibility, ambient mode); Linkerd = lightweight Rust proxy, lower overhead, simpler ops. Choose by complexity vs resource trade-off.
- **mTLS STRICT mode**: `PeerAuthentication` enforces mutual TLS for all in-mesh traffic; `AuthorizationPolicy` adds L7 RBAC on top — show `l4` for both.
- **Canary via VirtualService**: weight-based traffic split without touching application code — `l2` shows 90/10 split with header-based override for testing.
- **eBPF/XDP**: Cilium bypasses iptables entirely; `l-max` C skeleton shows how XDP programs attach to NIC for sub-microsecond packet processing.
- **EnvoyFilter**: `l-max` Wasm + Lua filters demonstrate extensibility beyond Istio's built-in policies — useful for custom auth or header manipulation.

## Notes

- `l1` Istio install values: duplicate `defaultConfig:` key fixed — tracing (Zipkin/Jaeger) and `holdApplicationUntilProxyStarts` are now in a single merged block.
- All IPs in this repo are RFC1918 / documentation-range (10.x, 172.x, 203.0.113.x) — no real infrastructure fingerprints.
