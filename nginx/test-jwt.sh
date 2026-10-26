#!/usr/bin/env bash
# Behavioural test for the OpenResty l-max lab: real container, real HTTP.
# Proves: no token -> 401, forged token (old default secret) -> 401, valid token
# -> 200 with verified identity headers, client-sent X-User-ID is ignored,
# /api/expensive also needs auth and is rate limited per verified user, and a
# missing JWT_SECRET fails closed (500) instead of using a default.
# Usage: ./test-jwt.sh   (needs docker, python3, curl, openssl)
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${ORESTY_IMAGE:-nginx-lab-openresty:ci}"
PORT=18080; BA=39001; BB=39002
SECRET="$(openssl rand -hex 32)"
work="$(mktemp -d)"
pids=()
cleanup() {
  docker rm -f lab-openresty >/dev/null 2>&1 || true
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT

docker build -q -t "$IMAGE" -f openresty.Dockerfile . >/dev/null
# Same config, only the ports moved so the test never collides with local services.
sed -e "s/listen 80;/listen $PORT;/" -e "s/127.0.0.1:3001/127.0.0.1:$BA/" \
    -e "s/127.0.0.1:3002/127.0.0.1:$BB/" l-max-*.conf > "$work/nginx.conf"
chmod a+r "$work/nginx.conf"

python3 test/backend.py "$BA" & pids+=($!)
python3 test/backend.py "$BB" & pids+=($!)

b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
make_jwt() { # $1 secret $2 payload-json
  local h p sig
  h=$(printf '{"alg":"HS256","typ":"JWT"}' | b64)
  p=$(printf '%s' "$2" | b64)
  sig=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$1" -binary | b64)
  printf '%s.%s.%s' "$h" "$p" "$sig"
}
start() { # $@ extra docker args
  docker rm -f lab-openresty >/dev/null 2>&1 || true
  docker run -d --name lab-openresty --network host "$@" \
    -v "$work/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf:ro" \
    "$IMAGE" openresty -g 'daemon off;' >/dev/null
  for _ in $(seq 1 30); do
    curl -fs "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  docker logs lab-openresty; return 1
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
expect() { # name want got
  if [ "$2" != "$3" ]; then echo "FAIL $1: want $2 got $3"; docker logs lab-openresty 2>&1 | tail -20; exit 1; fi
  echo "ok   $1 ($3)"
}

exp=$(( $(date +%s) + 600 ))
good=$(make_jwt "$SECRET" "{\"sub\":\"alice\",\"role\":\"admin\",\"exp\":$exp}")
forged=$(make_jwt "changeme" "{\"sub\":\"mallory\",\"exp\":$exp}")
expired=$(make_jwt "$SECRET" "{\"sub\":\"alice\",\"exp\":$(( $(date +%s) - 10 ))}")
U="http://127.0.0.1:$PORT"

start -e "JWT_SECRET=$SECRET"
expect "health is public"            200 "$(code "$U/health")"
expect "no token"                    401 "$(code "$U/api/x")"
expect "forged with old default"     401 "$(code -H "Authorization: Bearer $forged" "$U/api/x")"
expect "expired token"               401 "$(code -H "Authorization: Bearer $expired" "$U/api/x")"
expect "valid token"                 200 "$(code -H "Authorization: Bearer $good" "$U/api/x")"
expect "expensive: no token"         401 "$(code "$U/api/expensive")"
expect "unknown path"                404 "$(code "$U/nope")"

body=$(curl -s -H "Authorization: Bearer $good" -H "X-User-ID: root" "$U/api/x")
python3 - "$body" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["user"] == "alice", d       # from the verified claim, not the client header
assert d["role"] == "admin", d
print("ok   identity headers come from the token")
PY

t=$(curl -s -H "Authorization: Bearer $good" -H "X-API-Version: v2" "$U/api/transform")
python3 - "$t" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert "_request_id" in d and d["path"] == "/api/transform", d
print("ok   body rewrite kept valid JSON with correct length")
PY

# Rate limit: 10/min per verified user. Changing X-User-ID must not help.
last=200
for i in $(seq 1 12); do
  last=$(code -H "Authorization: Bearer $good" -H "X-User-ID: rotate-$i" "$U/api/expensive")
done
expect "expensive rate-limited after 10" 429 "$last"

start    # no JWT_SECRET at all
expect "missing secret fails closed" 500 "$(code -H "Authorization: Bearer $forged" "$U/api/x")"
echo "all OpenResty JWT checks passed"
