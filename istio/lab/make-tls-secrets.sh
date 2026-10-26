#!/usr/bin/env bash
# Create throw-away TLS secrets for the three credentialName entries in l3, so the
# Gateway resources have real certificates to load. Self-signed, for labs only.
# Usage: ./make-tls-secrets.sh   (kubectl context = the cluster; writes to istio-system)
set -euo pipefail
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=lab.example.com" \
  -addext "subjectAltName=DNS:app.example.com,DNS:*.api.example.com,DNS:internal.example.com" \
  -keyout "$tmp/tls.key" -out "$tmp/tls.crt" 2>/dev/null

for name in app-example-tls wildcard-api-example-tls; do
  kubectl -n istio-system create secret tls "$name" --cert="$tmp/tls.crt" --key="$tmp/tls.key" \
    --dry-run=client -o yaml | kubectl apply -f -
done
# MUTUAL mode also wants the CA that signs client certificates (key "ca.crt").
kubectl -n istio-system create secret generic internal-mtls-certs \
  --from-file=tls.crt="$tmp/tls.crt" --from-file=tls.key="$tmp/tls.key" --from-file=ca.crt="$tmp/tls.crt" \
  --dry-run=client -o yaml | kubectl apply -f -
