#!/usr/bin/env bash
# Build the XDP program with clang, load it past the kernel verifier, attach it to a
# veth pair in a throw-away network namespace and prove the rate limiter works:
# an ICMP flood is mostly dropped (and was not dropped before attaching), a normal ping passes.
# Needs root (sudo), clang, libbpf-dev, iproute2. Safe: touches only a private netns.
set -euo pipefail
cd "$(dirname "$0")"
src=$(ls l-max-*.c)
obj=$(mktemp -d)/xdp_filter.o

# -target selects the BPF back end; the -I path is where Debian/Ubuntu keep asm/*.h
clang -O2 -g -Wall -Werror -target bpf -I/usr/include/"$(uname -m)"-linux-gnu -c "$src" -o "$obj"
echo "ok   clang build"

ns=xdplab
cleanup() { sudo ip netns del "$ns" 2>/dev/null || true; sudo ip link del xdp-host 2>/dev/null || true; }
trap cleanup EXIT
cleanup
sudo ip netns add "$ns"
sudo ip link add xdp-host type veth peer name xdp-peer
sudo ip link set xdp-peer netns "$ns"
sudo ip addr add 192.0.2.1/24 dev xdp-host
sudo ip link set xdp-host up
sudo ip -n "$ns" addr add 192.0.2.2/24 dev xdp-peer
sudo ip -n "$ns" link set xdp-peer up
sudo ip -n "$ns" link set lo up

fail() { echo "FAIL: $*" >&2; exit 1; }

# flood_loss: 200 pings back to back from the namespace (burst is 10, refill 10 packets/s); prints the % loss.
flood_loss() {
  local out loss
  out=$(sudo ip netns exec "$ns" ping -c 200 -i 0.005 -W 1 -q 192.0.2.1 || true)
  echo "$out" | tail -3 >&2
  loss=$(echo "$out" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p')
  [ -n "$loss" ] || fail "could not read packet loss from ping output"
  echo "$loss"
}

# Baseline WITHOUT the filter: the same flood must pass, otherwise the veth pair or ping itself drops packets and the
# drop measured below would prove nothing.
sudo ip netns exec "$ns" ping -c 3 -i 1 -W 2 192.0.2.1 >/dev/null || fail "baseline: normal ping failed before XDP was attached"
base=$(flood_loss)
awk -v l="$base" 'BEGIN { exit !(l < 10) }' || fail "baseline: flood lost ${base}% with no XDP attached (veth/ping problem, not the filter)"
echo "ok   baseline without XDP: flood loss ${base}% (< 10%)"

# The filter protects the host end: it sees what the namespace sends in.
sudo ip link set dev xdp-host xdpgeneric obj "$obj" sec xdp_filter
sudo ip link show xdp-host | grep -q 'xdpgeneric' || fail "xdpgeneric program is not attached to xdp-host"
echo "ok   verifier accepted the program, attached to xdp-host"

# Normal use: 3 pings one second apart all get through.
sudo ip netns exec "$ns" ping -c 3 -i 1 -W 2 192.0.2.1 >/dev/null || fail "normal ping dropped by the filter"
echo "ok   normal ping passes"

# Flood: the same 200 pings that passed in the baseline are now mostly dropped.
loss=$(flood_loss)
awk -v l="$loss" 'BEGIN { exit !(l >= 50) }' || fail "flood not limited (${loss}% loss, baseline was ${base}%)"
echo "ok   ICMP flood dropped (${loss}% loss with XDP vs ${base}% without)"

# The bucket refills: after a pause, normal pings pass again.
sleep 2
sudo ip netns exec "$ns" ping -c 3 -i 1 -W 2 192.0.2.1 >/dev/null || fail "ping still dropped after the bucket should have refilled"
echo "ok   normal ping passes again after the flood"
