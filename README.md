# networking-service-mesh

A ladder (l1 to l-max) of networking configs that you can run: reverse proxies and
load balancers (nginx, OpenResty, HAProxy, Traefik), DNS (CoreDNS), service meshes
(Istio, Linkerd), and eBPF networking (Cilium, an XDP program). Every level is
checked by CI on a schedule, and the service mesh and CNI levels are installed on
real `kind` clusters and tested for behaviour, not only for syntax.

Good for "explain the layers of Kubernetes networking" interview questions: each
directory is one layer, each level adds one idea.

## Versions this repo targets (checked 2026-10-26)

| Component | Version | Note |
|-----------|---------|------|
| HAProxy | 3.4 LTS (`haproxy:3.4-alpine`) | LTS, fixes until Q2 2031 |
| nginx | 1.31 (`nginx:1.31-alpine`) | OpenResty 1.31.1.1 for l-max |
| Traefik | v3.7.16 | `traefik/whoami` v1.12.0 as the lab backend |
| CoreDNS | 1.15.0 | |
| Istio | 1.30.7 Helm charts, `istioctl` 1.30.7 | 1.31.x exists, but its Helm charts are not in the official repo yet |
| Linkerd | OSS **edge**: chart 2026.10.1 (`edge-26.10.1`) | see "Linkerd: edge vs stable" |
| Cilium | 1.20.4 | |
| Gateway API | v1.6.3 (Istio job), v1.1.1 bundle (Linkerd job) | |

## Level map

### nginx / OpenResty (`nginx/`)
| Level | File | What it teaches |
|-------|------|-----------------|
| l1 | `l1-basic-reverse-proxy-virtual-host-proxy-pass.conf` | vhosts, `proxy_pass`, WebSocket upgrade, `proxy_set_header` inheritance trap |
| l2 | `l2-load-balancing-upstream-least-conn-health-check.conf` | upstream groups, weights, passive health checks, gRPC (active checks need nginx Plus) |
| l3 | `l3-rate-limiting-waf-limit-req-limit-conn-modsecurity.conf` | `limit_req`, `limit_conn`, bad-UA blocking, IP allow-lists (stock nginx; the filename keeps its old name) |
| l3b (optional) | `l3b-modsecurity-owasp-crs-waf-optional.conf` | ModSecurity v3 + OWASP CRS. Needs the `owasp/modsecurity-crs` image: stock nginx has no `modsecurity` directive |
| l4 | `l4-ssl-hardening-...conf` | TLS 1.2/1.3, ECDHE-only ciphers, HSTS, security headers, mTLS vhost, why OCSP stapling is off for Let's Encrypt |
| l-max | `l-max-lua-scripting-openresty-dynamic-routing-jwt-auth.conf` | OpenResty: JWT auth module on every route, per-user rate limit, Redis routing table, response rewriting |

### HAProxy (`haproxy/`)
| Level | File | What it teaches |
|-------|------|-----------------|
| l1 | `l1-basic-tcp-http-proxy-frontend-backend-stats.cfg` | HTTP + TCP frontends, health checks (`http-check send`, `pgsql-check`), stats on loopback, Prometheus exporter |
| l2 | `l2-advanced-acl-backends-rate-limit-stick-table-http-rewrite.cfg` | ACLs, stick-table rate limiting synced over `peers`, CORS preflight, maintenance mode |

There is no l3 or l-max for HAProxy (runtime API, DNS service discovery and ACME are not covered).

### Traefik (`traefik/`)
| Level | File | What it teaches |
|-------|------|-----------------|
| l1 | `l1-...entrypoints-router-service.yml` | entry points, routers, services, Docker provider through a socket proxy |
| l2 | `l2-middleware-rate-limit-basic-auth-https-redirect.yml` | middleware chain: redirect, rate limit, basic auth (hash from `$BASIC_AUTH_USERS`) |
| l3 | `l3-tls-letsencrypt-...yml` + `tls-options-static-config.yml` | ACME HTTP-01 for a host, DNS-01 for the wildcard, hardened TLS options |
| l4 | `l4-dynamic-file-provider-...yml` + `dynamic/` | file provider (hot reload), load balancing with health checks and sticky cookies, TCP router |
| l-max | `l-max-custom-plugin-middleware-real-ip-header-rewrite.yml` | catalog plugins: real client IP behind a CDN, header transformation |

Plugins used in l-max are `Paxxs/traefik-get-real-ip` and `tomMoulard/htransformation`.
The three plugins the file used before (`soulbalz/traefik-real-ip`,
`maksimkurb/traefik-bot-blocker`, `traefik/plugin-rewriteheaders`) are gone from GitHub.

### CoreDNS (`coredns/`)
| Level | File | What it teaches |
|-------|------|-----------------|
| l1 | `l1-basic-dns-server-forward-cache-health-corefile.Corefile` | forward, cache, health, hosts zones |
| l2 | `l2-kubernetes-service-discovery-...-corefile.Corefile` | the in-cluster Corefile layout, `kubernetes` plugin, stub zones |
| l-max | `l-max-plugin-chain-rewrite-acl-template-etcd-dnssec-chaos-corefile.Corefile` | rewrite, acl, template, etcd, online DNSSEC, chaos; plugin order comes from `plugin.cfg`, not the Corefile |

### Istio (`istio/`)
| Level | File | What it teaches |
|-------|------|-----------------|
| l1 | `l1-install-profile-minimal-demo-ambient-helm-values.yaml` | Helm values for the `istiod` chart (ambient profile), mesh config, extension providers |
| l1b | `l1b-istiooperator-sidecar-install-istioctl.yaml` | the same idea as an IstioOperator for `istioctl install` |
| l1c | `l1c-ingress-gateway-helm-values.yaml` | standalone ingress gateway chart |
| l1 (companion) | `l1-telemetry-tracing-access-log-telemetry-api.yaml` | tracing with the Telemetry API |
| l2 | `l2-virtual-service-destination-rule-...yaml` | canary split, header routing, outlier detection, mirroring (`networking.istio.io/v1`) |
| l3 | `l3-gateway-tls-termination-sni-routing-multi-host.yaml` | Gateway TLS, mTLS, SNI passthrough |
| l3b | `l3b-gateway-api-httproute-waypoint.yaml` | Kubernetes Gateway API: Gateway, HTTPRoute, ambient waypoint |
| l4 | `l4-authorization-policy-mtls-peer-authentication-rbac.yaml` | STRICT mTLS, deny-all baseline, ALLOW policies, JWT (`security.istio.io/v1`) |
| l-max | `l-max-envoy-filter-wasm-custom-lua-http-filter.yaml`, `l-max-wasm-plugin-oci-module-placeholder.yaml` | external authz with `CUSTOM`, Lua EnvoyFilter, WasmPlugin |

`istio/lab/` holds the workloads and the TLS secret script used by the tests.

### Linkerd (`linkerd/`)
| Level | File | What it teaches |
|-------|------|-----------------|
| l1 | `l1-install-inject-control-plane-namespace-annotation.yaml` | Helm values for the edge control-plane chart, `cluster-authenticated` default policy; `gen-certs.sh` makes the lab trust anchor |
| l1b | `l1b-namespace-and-workload-manifests.yaml` | namespace injection, per-pod proxy annotations |
| l2 | `l2-service-profile-retry-timeout-per-route-traffic-policy.yaml` | ServiceProfile (legacy), HTTPRoute with retry/timeout annotations, Server + AuthorizationPolicy + MeshTLSAuthentication |

There is no l-max, TrafficSplit or SMI: SMI support was removed from Linkerd; HTTPRoute weights replace TrafficSplit.

### Cilium (`cilium/`)
| Level | File | What it teaches |
|-------|------|-----------------|
| l1 | `l1-install-helm-values-kubeproxy-replacement-hubble-enabled.yaml` | kube-proxy replacement, native routing, Hubble (eBPF masquerade is a documented switch, off because it broke DNS on kind) |
| l2 | `l2-network-policy-l7-http-dns-egress-ingress-cilium-network-policy.yaml` | default deny, L7 HTTP rules, DNS-aware egress |
| l3 | `l3-host-firewall-clusterwide-network-policy-audit-mode.yaml` | node-level policy; audit before enforce |
| l-max | `l-max-ebpf-custom-xdp-packet-filter-rate-limit-program.c` | XDP program: blocklist/allowlist, token buckets for SYN/UDP/ICMP only |

The XDP program is plain eBPF, not a Cilium feature: a NIC runs one XDP program, so it
competes with Cilium's own XDP load-balancer acceleration.

## Linkerd: edge vs stable

Since February 2024 the Linkerd project publishes only **edge** releases as open source.
The "stable" 2.x line (2.15 to 2.20) ships only as **Buoyant Enterprise for Linkerd**.
`https://helm.linkerd.io/stable` is frozen at chart 1.16.11 (Linkerd about 2.14).
This repo therefore installs the OSS edge charts from `https://helm.linkerd.io/edge`.
Edge is a rolling release: pin the chart version and read the notes before upgrading.

## Run it locally

Each check is a script, the same one CI runs.

```bash
./haproxy/check.sh            # haproxy -c -dW for every config (docker, openssl)
./nginx/check.sh              # nginx -t, ModSecurity image, openresty -t
./nginx/test-jwt.sh           # OpenResty JWT behaviour: forged token, expired, no token, no secret
./coredns/test.sh             # real CoreDNS container, queried with dig
./traefik/smoke.sh l1         # also l2 l3 l4 lmax; needs free ports 80, 443, 8080, 9000
./cilium/test-xdp.sh          # clang build + verifier + flood test in a netns (needs sudo)
```

The Kubernetes-based checks expect a cluster with the component already installed;
`.github/workflows/ci.yml` shows the exact install commands for each:

```bash
./cilium/test-in-kind.sh      # kind without CNI, Cilium installed from l1
./istio/test-in-kind.sh       # Istio ambient via Helm, then all manifests
./linkerd/test-in-kind.sh     # Linkerd edge via Helm, then all manifests
./coredns/test-in-kind.sh     # runs the l2 Corefile as a second CoreDNS
```

Quick start for Istio ambient (what l1 and CI do):

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts && helm repo update
helm install istio-base istio/base -n istio-system --create-namespace --version 1.30.7
helm install istiod istio/istiod -n istio-system --version 1.30.7 \
  -f istio/l1-install-profile-minimal-demo-ambient-helm-values.yaml --wait
helm install istio-cni istio/cni -n istio-system --version 1.30.7 --set profile=ambient --wait
helm install ztunnel istio/ztunnel -n istio-system --version 1.30.7 --wait
```

## What CI checks (`.github/workflows/ci.yml`)

Runs on push, pull request, `workflow_dispatch` and every Monday (images, charts and
the Traefik plugin catalog change on their own). All actions are pinned to commit SHAs;
Dependabot updates actions, the OpenResty Dockerfile and the Traefik compose images.

| Job | What it proves |
|-----|----------------|
| lint | actionlint, shellcheck, hadolint, `yamllint --strict` |
| haproxy | `haproxy -c -dW` on 3.4 for l1 and l2 (warnings fail) |
| nginx | `nginx -t` l1-l4, ModSecurity image l3b, `openresty -t` l-max; JWT test with a real container |
| coredns | l1 and l-max Corefiles answer real queries (hosts, template, DNSSEC RRSIG, chaos) |
| traefik (x5) | `docker compose up --wait` per level, then HTTP/TCP checks (routing, redirect, auth, ACME wiring, plugins, hot reload) |
| schemas | `kubeconform -strict` against the Kubernetes + CRD schemas for Istio, Cilium, Linkerd and Gateway API; every Helm values key must exist in the chart; charts render; `istioctl manifest generate` |
| xdp | `clang -target bpf -Wall -Werror`, kernel verifier, ICMP flood dropped in a netns |
| kind-cilium | Cilium as the CNI with the l1 values; L7 policy allows and denies as written; an un-named pod in the same namespace cannot connect |
| kind-istio | ambient install with the l1 values; all manifests applied; `istioctl analyze`; deny-all then allow; Lua filter changes a live response; ambient traffic over HBONE; Gateway API proxies |
| kind-linkerd | edge install with the l1 values; injection; only the allowed ServiceAccount gets through; HTTPRoute path split |
| kind-coredns | l2 Corefile as a second CoreDNS resolves `kubernetes.default.svc.cluster.local` |

## Honest limits

- No cloud load balancer, so ingress gateways run as NodePort on kind. Let's Encrypt
  cannot be reached from a runner: Traefik l3 checks the resolver wiring and TLS options
  only, and points ACME at a dead local URL so nothing talks to a real CA.
- The WasmPlugin in `l-max-wasm-plugin-oci-module-placeholder.yaml` points at a placeholder
  image. CI validates it against the CRD (server-side dry run) but cannot run it.
- Istio runs on one-node `kind`, so HA settings (replicas, anti-affinity) are lowered with
  `--set` in CI; the files keep the production values.
- The Cilium host firewall (l3) is only schema-checked; enabling it on a CI node could cut the runner off.
- The XDP program uses `xdpgeneric` in a network namespace. Native-mode XDP and exact limits
  across many CPUs are not tested (buckets are per CPU).
- The Linkerd job uses throw-away certificates from `linkerd/gen-certs.sh`. Production needs
  your own PKI or cert-manager with an offline root.
- IP addresses in the configs are RFC 1918 / documentation ranges, plus public resolvers
  (1.1.1.1, 8.8.8.8) used as upstreams.

## License

MIT, see `LICENSE`.
