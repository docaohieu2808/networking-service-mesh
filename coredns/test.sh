#!/usr/bin/env bash
# Run the standalone Corefiles (l1, l-max) in the real CoreDNS image and query them.
# Needs: docker, dig (dnsutils), curl. l2 needs a cluster: see test-in-kind.sh.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${COREDNS_IMAGE:-coredns/coredns:1.15.0}"
PORT=19053
work="$(mktemp -d)"
trap 'docker rm -f lab-coredns >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

dq() { dig @127.0.0.1 -p "$PORT" +time=3 +tries=2 "$@"; }
check() { # desc want got
  [ "$2" = "$3" ] || { echo "FAIL $1: want '$2' got '$3'"; docker logs --tail 40 lab-coredns 2>&1; exit 1; }
  echo "ok   $1"
}
start() { # corefile [extra docker args...]
  local cf=$1; shift
  docker rm -f lab-coredns >/dev/null 2>&1 || true
  docker run -d --name lab-coredns "$@" -v "$cf:/Corefile:ro" \
    -p "127.0.0.1:$PORT:53/udp" -p "127.0.0.1:$PORT:53/tcp" -p 127.0.0.1:18080:8080 \
    "$IMAGE" -conf /Corefile >/dev/null
  for _ in $(seq 1 30); do
    curl -fs http://127.0.0.1:18080/health >/dev/null 2>&1 && return 0; sleep 0.5
  done
  docker logs --tail 40 lab-coredns; exit 1
}

echo "== l1"
start "$PWD/$(ls l1-*.Corefile)"
check "hosts plugin answers internal zone" "10.0.1.10" "$(dq api.internal.example.com +short)"
check "localhost zone"                     "127.0.0.1" "$(dq whoami.localhost +short)"
if [ -n "$(dq example.org A +short)" ]; then echo "ok   forward to upstream resolves a public name"; else echo "FAIL: forward"; exit 1; fi

echo "== l-max"
# dnssec needs a key pair; generate a throw-away one with ldns-keygen.
mkdir "$work/keys"
docker run --rm -v "$work/keys:/k" alpine sh -c 'apk add -q ldns-tools && cd /k && ldns-keygen -a ECDSAP256SHA256 -k example.com >/dev/null && chmod a+r /k/*'
key=$(basename "$(ls "$work"/keys/*.key)" .key)
sed "s|Kexample.com.+013+12345|$key|" "$PWD/$(ls l-max-*.Corefile)" > "$work/Corefile"
start "$work/Corefile" -v "$work/keys:/etc/coredns/keys:ro" --user root
check "template: svc-7 -> 10.0.0.7"        "10.0.0.7" "$(dq svc-7.dynamic.example.com +short)"
if dq svc-7.dynamic.example.com +dnssec +noall +answer | grep -q RRSIG; then echo "ok   dnssec signs the answer"; else echo "FAIL: no RRSIG"; exit 1; fi
check "chaos identity is custom"           '"lab-dns"' "$(dq version.bind TXT CH +short)"
# The old wildcard template answered 93.184.216.34 for every name; it must be gone.
got=$(dq anything.example.com +short || true)
if [ "$got" != "93.184.216.34" ]; then echo "ok   no wildcard template shadowing etcd"; else echo "FAIL: wildcard still answers"; exit 1; fi
echo "all CoreDNS checks passed"
