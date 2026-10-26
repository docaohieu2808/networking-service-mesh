/*
 * Cilium L-MAX - Custom eBPF XDP program: packet filter + per-source-IP rate limiting
 * Demonstrates: XDP hook, BPF maps (per-CPU LRU hash, hash, per-CPU array),
 *               token buckets, blocklist/allowlist, safe packet parsing.
 *
 * What it limits (and what it deliberately does not):
 *   - TCP SYN without ACK (new connections)  -> limited   (SYN flood)
 *   - UDP                                    -> limited   (UDP flood)
 *   - ICMP                                   -> limited, stricter than TCP/UDP
 *   - every other TCP packet (established flows, ACKs, data) -> XDP_PASS, never limited
 * An earlier version ran a catch-all limiter on all packets, which capped every
 * source at 100 packets/s and starved legitimate established traffic.
 *
 * Buckets are per CPU (LRU_PERCPU_HASH): there is no lock and no data race, and
 * the effective limit is "rate per CPU" - roughly rate x CPUs a source's flows
 * are spread over by RSS. Use a BPF spin lock or a single-queue NIC if you need
 * an exact global rate.
 *
 * Build (CI does exactly this and also checks the object with llvm-objdump):
 *   clang -O2 -g -Wall -Werror -target bpf \
 *     -I/usr/include/$(uname -m)-linux-gnu \
 *     -c l-max-ebpf-custom-xdp-packet-filter-rate-limit-program.c -o xdp_filter.o
 *   (packages on Debian/Ubuntu: clang llvm libbpf-dev linux-libc-dev)
 *
 * Load with iproute2 (generic mode works on any NIC and in a VM):
 *   ip link set dev eth0 xdpgeneric obj xdp_filter.o sec xdp_filter
 *
 * Inspect:  bpftool map show ;  bpftool map dump name pkt_stats
 * Remove:   ip link set dev eth0 xdpgeneric off
 *
 * Cilium note: a NIC can run ONE XDP program. If Cilium's XDP load-balancer
 * acceleration (loadBalancer.acceleration) is active on that NIC, attaching this
 * program replaces it. Run this on a NIC Cilium does not manage, or chain both
 * with a libxdp dispatcher. There is no `cilium config` key that loads a custom
 * XDP object.
 */

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/icmp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define MAX_ENTRIES      65536
#define BLOCKLIST_MAX    1024
#define ALLOWLIST_MAX    256

/* One independent bucket per (source IP, traffic class). */
enum rl_class {
    RL_TCP_SYN = 0,
    RL_UDP     = 1,
    RL_ICMP    = 2,
};

struct rl_key {
    __u32 ip;       /* source IPv4 address, network byte order */
    __u32 class;    /* enum rl_class */
};

struct rl_bucket {
    __u64 tokens;
    __u64 last_refill_ns;
};

struct {
    __uint(type, BPF_MAP_TYPE_LRU_PERCPU_HASH);
    __uint(max_entries, MAX_ENTRIES);
    __type(key,   struct rl_key);
    __type(value, struct rl_bucket);
} rate_limit_map SEC(".maps");

/* Drop everything from these sources. */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, BLOCKLIST_MAX);
    __type(key,   __u32);
    __type(value, __u8);
} ip_blocklist SEC(".maps");

/* Skip rate limiting for these sources. */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, ALLOWLIST_MAX);
    __type(key,   __u32);
    __type(value, __u8);
} ip_allowlist SEC(".maps");

struct pkt_counters {
    __u64 tcp_packets;
    __u64 udp_packets;
    __u64 icmp_packets;
    __u64 dropped_blocklist;
    __u64 dropped_ratelimit;
    __u64 dropped_malformed;
    __u64 passed_total;
};

/* Per-CPU array: each CPU bumps its own copy, userspace sums them. */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key,   __u32);
    __type(value, struct pkt_counters);
} pkt_stats SEC(".maps");

/* Burst size and refill period per class. ICMP is the strictest. */
static __always_inline void class_params(__u32 class, __u64 *burst, __u64 *refill_ns)
{
    switch (class) {
    case RL_TCP_SYN:
        *burst = 100;  *refill_ns = 10000000ULL;   /* 100 new connections/s */
        break;
    case RL_UDP:
        *burst = 200;  *refill_ns = 5000000ULL;    /* 200 datagrams/s */
        break;
    default: /* RL_ICMP */
        *burst = 10;   *refill_ns = 100000000ULL;  /* 10 packets/s */
        break;
    }
}

/* Token bucket: returns 1 if the packet may pass, 0 if the bucket is empty. */
static __always_inline int take_token(__u32 ip, __u32 class)
{
    struct rl_key key = { .ip = ip, .class = class };
    struct rl_bucket *b;
    __u64 burst, refill_ns;
    __u64 now = bpf_ktime_get_ns();

    class_params(class, &burst, &refill_ns);

    b = bpf_map_lookup_elem(&rate_limit_map, &key);
    if (!b) {
        struct rl_bucket fresh = { .tokens = burst - 1, .last_refill_ns = now };
        bpf_map_update_elem(&rate_limit_map, &key, &fresh, BPF_ANY);
        return 1;
    }

    __u64 added = (now - b->last_refill_ns) / refill_ns;
    if (added > 0) {
        __u64 t = b->tokens + added;
        b->tokens = t > burst ? burst : t;
        b->last_refill_ns += added * refill_ns;   /* keep the fractional remainder */
    }

    if (b->tokens == 0)
        return 0;
    b->tokens--;
    return 1;
}

SEC("xdp_filter")
int xdp_packet_filter(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    void *data     = (void *)(long)ctx->data;
    __u32 zero = 0;
    struct pkt_counters *stats = bpf_map_lookup_elem(&pkt_stats, &zero);

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        goto malformed;

    /* Only IPv4 is filtered; ARP, IPv6, ... pass untouched. */
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *iph = (void *)(eth + 1);
    if ((void *)(iph + 1) > data_end)
        goto malformed;
    if (iph->ihl < 5)
        goto malformed;

    __u32 src_ip = iph->saddr;

    /* Blocklist first: cheapest way to shed known bad sources. */
    __u8 *blocked = bpf_map_lookup_elem(&ip_blocklist, &src_ip);
    if (blocked && *blocked == 1) {
        if (stats)
            stats->dropped_blocklist++;
        return XDP_DROP;
    }

    /* Trusted sources skip the limiter entirely. */
    __u8 *trusted = bpf_map_lookup_elem(&ip_allowlist, &src_ip);
    if (trusted && *trusted == 1) {
        if (stats)
            stats->passed_total++;
        return XDP_PASS;
    }

    void *l4 = (void *)iph + (iph->ihl * 4);
    __u32 class;

    if (iph->protocol == IPPROTO_TCP) {
        struct tcphdr *tcph = l4;
        if ((void *)(tcph + 1) > data_end)
            goto malformed;
        if (stats)
            stats->tcp_packets++;
        /* Established traffic is never limited here. */
        if (!(tcph->syn && !tcph->ack))
            goto pass;
        class = RL_TCP_SYN;
    } else if (iph->protocol == IPPROTO_UDP) {
        struct udphdr *udph = l4;
        if ((void *)(udph + 1) > data_end)
            goto malformed;
        if (stats)
            stats->udp_packets++;
        class = RL_UDP;
    } else if (iph->protocol == IPPROTO_ICMP) {
        struct icmphdr *icmph = l4;
        if ((void *)(icmph + 1) > data_end)
            goto malformed;
        if (stats)
            stats->icmp_packets++;
        class = RL_ICMP;
    } else {
        goto pass;      /* other protocols: not our business */
    }

    if (!take_token(src_ip, class)) {
        if (stats)
            stats->dropped_ratelimit++;
        return XDP_DROP;
    }

pass:
    if (stats)
        stats->passed_total++;
    return XDP_PASS;

malformed:
    if (stats)
        stats->dropped_malformed++;
    return XDP_DROP;
}

char _license[] SEC("license") = "GPL";
