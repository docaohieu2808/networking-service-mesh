#!/usr/bin/env bash
# Syntax-check every nginx / OpenResty config here with the real binaries.
# Usage: ./check.sh   (needs docker; l-max builds a small OpenResty image)
set -euo pipefail
cd "$(dirname "$0")"

NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.31-alpine}"
WAF_IMAGE="${WAF_IMAGE:-owasp/modsecurity-crs:nginx-alpine}"
ORESTY_IMAGE="${ORESTY_IMAGE:-nginx-lab-openresty:ci}"

# l1, l2, l3 are plain nginx. l4 also needs certificates.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=example.com" \
  -keyout "$work/key.pem" -out "$work/crt.pem" 2>/dev/null
chmod a+r "$work"/*

# Run nginx -t, fail on any [warn]/[emerg]/[alert] line (not just the exit code).
t() {
  out=$("$@" 2>&1) || { echo "$out"; return 1; }
  if grep -E '\[(warn|emerg|alert|crit)\]' <<<"$out"; then return 1; fi
  tail -n1 <<<"$out"
}
D=(docker run --rm --ulimit nofile=65536:65536)

for f in l1-*.conf l2-*.conf l3-[a-z]*.conf; do
  echo "== nginx -t: $f"
  t "${D[@]}" --entrypoint nginx -v "$PWD/$f:/etc/nginx/nginx.conf:ro" "$NGINX_IMAGE" -t
done

f=$(ls l4-*.conf)
echo "== nginx -t: $f"
t "${D[@]}" --entrypoint nginx -v "$PWD/$f:/etc/nginx/nginx.conf:ro" \
  -v "$work/crt.pem:/etc/letsencrypt/live/example.com/fullchain.pem:ro" \
  -v "$work/crt.pem:/etc/letsencrypt/live/example.com/chain.pem:ro" \
  -v "$work/key.pem:/etc/letsencrypt/live/example.com/privkey.pem:ro" \
  -v "$work/crt.pem:/etc/nginx/certs/server.crt:ro" \
  -v "$work/key.pem:/etc/nginx/certs/server.key:ro" \
  -v "$work/crt.pem:/etc/nginx/certs/internal-ca.crt:ro" \
  "$NGINX_IMAGE" -t

echo "== nginx -t (ModSecurity image): l3b"
# Through the image entrypoint: it renders /etc/modsecurity.d/setup.conf first.
t "${D[@]}" -v "$PWD/l3b-modsecurity-owasp-crs-waf-optional.conf:/tmp/nginx.conf:ro" \
  "$WAF_IMAGE" nginx -t -c /tmp/nginx.conf

echo "== openresty -t: l-max"
docker build -q -t "$ORESTY_IMAGE" -f openresty.Dockerfile . >/dev/null
t "${D[@]}" -e JWT_SECRET=ci-only-not-a-secret \
  -v "$PWD/$(ls l-max-*.conf):/usr/local/openresty/nginx/conf/nginx.conf:ro" \
  "$ORESTY_IMAGE" openresty -t
