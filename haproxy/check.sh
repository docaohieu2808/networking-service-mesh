#!/usr/bin/env bash
# Validate every HAProxy config in this directory with the real haproxy binary.
# Usage: ./check.sh            (needs docker and openssl)
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${HAPROXY_IMAGE:-haproxy:3.4-alpine}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Throw-away self-signed cert so `bind ... ssl crt` can load.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=example.com" \
  -keyout "$work/key.pem" -out "$work/crt.pem" 2>/dev/null
mkdir -p "$work/certs"
cat "$work/crt.pem" "$work/key.pem" > "$work/certs/example.com.pem"
chmod -R a+rX "$work"

status=0
for cfg in l*.cfg; do
  echo "== haproxy -c: $cfg"
  docker run --rm \
    -e STATS_PASSWORD=ci-only \
    -v "$PWD/$cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
    -v "$PWD/etc/blacklist.lst:/etc/haproxy/blacklist.lst:ro" \
    -v "$PWD/etc/scanner-agents.lst:/etc/haproxy/scanner-agents.lst:ro" \
    -v "$work/certs:/etc/haproxy/certs:ro" \
    "$IMAGE" haproxy -c -dW -L haproxy1 -f /usr/local/etc/haproxy/haproxy.cfg || status=1
done
exit "$status"
