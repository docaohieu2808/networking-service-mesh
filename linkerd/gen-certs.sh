#!/usr/bin/env bash
# Create a THROW-AWAY Linkerd trust anchor + issuer certificate (ECDSA P-256) for labs.
# Usage: ./gen-certs.sh [outdir]   -> outdir/ca.crt issuer.crt issuer.key
# The trust anchor key is deleted afterwards on purpose: a root key that stays on
# the cluster operator's disk defeats the point of a root. Production: use
# cert-manager with an offline root, or `step certificate create`.
set -euo pipefail
out="${1:-certs}"
mkdir -p "$out"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/ca.key"
openssl req -x509 -new -key "$tmp/ca.key" -sha256 -days 365 \
  -subj "/CN=root.linkerd.cluster.local" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out "$out/ca.crt"

openssl ecparam -name prime256v1 -genkey -noout -out "$out/issuer.key"
openssl req -new -key "$out/issuer.key" -subj "/CN=identity.linkerd.cluster.local" -out "$tmp/issuer.csr"
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$tmp/ext.cnf"
openssl x509 -req -in "$tmp/issuer.csr" -CA "$out/ca.crt" -CAkey "$tmp/ca.key" -CAcreateserial \
  -days 90 -sha256 -extfile "$tmp/ext.cnf" -out "$out/issuer.crt"
echo "wrote $out/ca.crt $out/issuer.crt $out/issuer.key (certs/ is git-ignored)"
