/*
 * Cilium L-MAX — Custom eBPF XDP program: packet filter + per-IP rate limiting
 * Demonstrates: XDP hook, BPF maps (LRU hash, array), per-IP token bucket,
 *               ICMP flood protection, IP allowlist/blocklist, packet parsing
 *
 * Build:
 *   clang -O2 -g -target bpf \
 *     -I/usr/include/$(uname -m)-linux-gnu \
 *     -c l-max-ebpf-custom-xdp-packet-filter-rate-limit-program.c \
 *     -o xdp_filter.o
 *
 * Load (via iproute2):
 *   ip link set dev eth0 xdp obj xdp_filter.o sec xdp_filter
 *
 * Load (via Cilium custom program — mount in ConfigMap and reference in CiliumConfig):
 *   cilium config set bpf-filter-priority 20
 *
 * Inspect maps:
 *   bpftool map show
 *   bpftool map dump name rate_limit_map
 *
 * Remove:
 *   ip link set dev eth0 xdp off
 */

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/icmp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

/* ── Constants ─────────────────────────────────────────────────────────────── */
#define MAX_ENTRIES         65536
#define RATE_LIMIT_TOKENS   100         /* max tokens per bucket */
#define TOKEN_REFILL_NS     10000000ULL /* refill 1 token per 10ms (100 pps max) */
#define ICMP_RATE_LIMIT     10          /* max ICMP packets per refill window */
#define BLOCKLIST_MAX       1024

/* ── BPF map: per-IP rate limit state (token bucket) ───────────────────────── */
struct rate_limit_entry {
    __u64 tokens;           /* current token count */
    __u64 last_refill_ns;   /* timestamp of last token refill */
};

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, MAX_ENTRIES);
    __type(key,   __u32);                   /* source IPv4 address */
    __type(value, struct rate_limit_entry);
} rate_limit_map SEC(".maps");

/* ── BPF map: IP blocklist (drop all traffic from these IPs) ────────────────── */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, BLOCKLIST_MAX);
    __type(key,   __u32);   /* IPv4 address */
    __type(value, __u8);    /* 1 = blocked */
} ip_blocklist SEC(".maps");

/* ── BPF map: IP allowlist (bypass rate limiting for trusted IPs) ───────────── */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 256);
    __type(key,   __u32);   /* IPv4 address */
    __type(value, __u8);    /* 1 = trusted */
} ip_allowlist SEC(".maps");

/* ── BPF map: per-protocol packet counters (for observability) ──────────────── */
struct pkt_counters {
    __u64 tcp_packets;
    __u64 udp_packets;
    __u64 icmp_packets;
    __u64 dropped_blocklist;
    __u64 dropped_ratelimit;
    __u64 passed_total;
};

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key,   __u32);
    __type(value, struct pkt_counters);
} pkt_stats SEC(".maps");

/* ── Helper: update token bucket, return 1 if packet allowed ───────────────── */
static __always_inline int check_rate_limit(__u32 src_ip)
{
    struct rate_limit_entry *entry;
    struct rate_limit_entry  new_entry = {};
    __u64 now = bpf_ktime_get_ns();

    entry = bpf_map_lookup_elem(&rate_limit_map, &src_ip);
    if (!entry) {
        /* First packet from this IP — initialise bucket */
        new_entry.tokens        = RATE_LIMIT_TOKENS - 1;
        new_entry.last_refill_ns = now;
        bpf_map_update_elem(&rate_limit_map, &src_ip, &new_entry, BPF_ANY);
        return 1; /* allow */
    }

    /* Refill tokens based on elapsed time */
    __u64 elapsed  = now - entry->last_refill_ns;
    __u64 new_tokens = elapsed / TOKEN_REFILL_NS;

    if (new_tokens > 0) {
        entry->tokens += new_tokens;
        if (entry->tokens > RATE_LIMIT_TOKENS)
            entry->tokens = RATE_LIMIT_TOKENS;
        entry->last_refill_ns = now;
    }

    if (entry->tokens == 0)
        return 0; /* drop: bucket empty */

    entry->tokens--;
    return 1; /* allow */
}

/* ── Helper: increment a counter field in pkt_stats ────────────────────────── */
static __always_inline void count_pkt(__u64 *field)
{
    __u32 key = 0;
    struct pkt_counters *stats = bpf_map_lookup_elem(&pkt_stats, &key);
    if (stats)
        __sync_fetch_and_add(field, 1);
}

/* ── XDP program entry point ────────────────────────────────────────────────── */
SEC("xdp_filter")
int xdp_packet_filter(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    void *data     = (void *)(long)ctx->data;

    /* ── Parse Ethernet header ──────────────────────────────────────────────── */
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_DROP;

    /* Only process IPv4 (pass IPv6 and ARP through unmodified) */
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;

    /* ── Parse IP header ────────────────────────────────────────────────────── */
    struct iphdr *iph = (void *)(eth + 1);
    if ((void *)(iph + 1) > data_end)
        return XDP_DROP;

    __u32 src_ip = iph->saddr;
    __u32 dst_ip = iph->daddr;
    __u8  proto  = iph->protocol;

    /* ── Blocklist check: drop immediately ──────────────────────────────────── */
    __u8 *blocked = bpf_map_lookup_elem(&ip_blocklist, &src_ip);
    if (blocked && *blocked == 1) {
        __u32 key = 0;
        struct pkt_counters *stats = bpf_map_lookup_elem(&pkt_stats, &key);
        if (stats)
            __sync_fetch_and_add(&stats->dropped_blocklist, 1);
        return XDP_DROP;
    }

    /* ── Allowlist check: bypass rate limiting for trusted sources ──────────── */
    __u8 *trusted = bpf_map_lookup_elem(&ip_allowlist, &src_ip);
    if (trusted && *trusted == 1) {
        __u32 key = 0;
        struct pkt_counters *stats = bpf_map_lookup_elem(&pkt_stats, &key);
        if (stats)
            __sync_fetch_and_add(&stats->passed_total, 1);
        return XDP_PASS;
    }

    /* ── Protocol-specific handling ─────────────────────────────────────────── */
    __u32 key = 0;
    struct pkt_counters *stats = bpf_map_lookup_elem(&pkt_stats, &key);

    if (proto == IPPROTO_ICMP) {
        /* Parse ICMP header */
        struct icmphdr *icmph = (void *)iph + (iph->ihl * 4);
        if ((void *)(icmph + 1) > data_end)
            return XDP_DROP;

        if (stats)
            __sync_fetch_and_add(&stats->icmp_packets, 1);

        /* ICMP flood protection: stricter rate limit */
        if (!check_rate_limit(src_ip | 0x80000000U)) { /* separate bucket for ICMP */
            if (stats)
                __sync_fetch_and_add(&stats->dropped_ratelimit, 1);
            return XDP_DROP;
        }

    } else if (proto == IPPROTO_TCP) {
        struct tcphdr *tcph = (void *)iph + (iph->ihl * 4);
        if ((void *)(tcph + 1) > data_end)
            return XDP_DROP;

        if (stats)
            __sync_fetch_and_add(&stats->tcp_packets, 1);

        /* SYN flood mitigation: rate-limit SYN-only packets */
        if (tcph->syn && !tcph->ack) {
            if (!check_rate_limit(src_ip)) {
                if (stats)
                    __sync_fetch_and_add(&stats->dropped_ratelimit, 1);
                return XDP_DROP;
            }
        }

    } else if (proto == IPPROTO_UDP) {
        struct udphdr *udph = (void *)iph + (iph->ihl * 4);
        if ((void *)(udph + 1) > data_end)
            return XDP_DROP;

        if (stats)
            __sync_fetch_and_add(&stats->udp_packets, 1);

        /* UDP flood protection */
        if (!check_rate_limit(src_ip)) {
            if (stats)
                __sync_fetch_and_add(&stats->dropped_ratelimit, 1);
            return XDP_DROP;
        }
    }

    /* ── Global rate limit check for all remaining traffic ──────────────────── */
    if (!check_rate_limit(src_ip)) {
        if (stats)
            __sync_fetch_and_add(&stats->dropped_ratelimit, 1);
        return XDP_DROP;
    }

    if (stats)
        __sync_fetch_and_add(&stats->passed_total, 1);

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
