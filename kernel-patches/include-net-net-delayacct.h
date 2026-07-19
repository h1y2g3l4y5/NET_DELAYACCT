/* SPDX-License-Identifier: GPL-2.0-only */
/* Copyright (c) 2026 h1y2g3l4y5 */
/*
 * Per-socket network delay accounting (CONFIG_NET_DELAYACCT).
 *
 * Inline helpers are used at the RX/TX instrumentation points so that
 * when the option is disabled the compiler eliminates them entirely,
 * yielding zero runtime overhead.
 */
#ifndef _NET_DELAYACCT_H
#define _NET_DELAYACCT_H

#include <linux/spinlock.h>
#include <linux/ktime.h>
#include <linux/skbuff.h>
#include <uapi/linux/net-delayacct.h>

struct sock;

/**
 * struct net_delayacct - per-socket delay accounting state
 * @lock:  protects @stats against concurrent RX/TX updates
 * @stats: cumulative latency and packet count
 *
 * One instance is embedded in every &struct sock (when
 * CONFIG_NET_DELAYACCT is enabled).  The spinlock is independent of
 * sk->sk_lock.slock to avoid ordering issues with the socket lock
 * taken in the RX/TX fast paths.
 */
struct net_delayacct {
	spinlock_t		lock;
	struct net_delayacct_stats stats;
};

#ifdef CONFIG_NET_DELAYACCT

/**
 * net_delayacct_init - initialize per-socket delay accounting state
 * @n: the &struct net_delayacct to initialize
 */
static inline void net_delayacct_init(struct net_delayacct *n)
{
	spin_lock_init(&n->lock);
	memset(&n->stats, 0, sizeof(n->stats));
}

/**
 * net_delayacct_rx_start - stamp RX start time on an skb
 * @skb: the incoming &sk_buff
 *
 * Called at the protocol stack entry (e.g. __netif_receive_skb_core).
 * The timestamp is carried in skb->delayacct_start and consumed by
 * net_delayacct_rx_end() when the packet is read to user space.
 */
static inline void net_delayacct_rx_start(struct sk_buff *skb)
{
	skb->delayacct_start = ktime_get_ns();
}

/**
 * net_delayacct_rx_end - accumulate RX latency on a socket
 * @sk:  the destination socket
 * @skb: the skb being delivered to user space
 *
 * Computes the delta from skb->delayacct_start to "now" and adds it
 * to the per-socket RX total.  If skb->delayacct_start is 0 (the
 * start point was not hit, e.g. for locally generated loopback
 * traffic), the call is a no-op.
 *
 * Defined out-of-line in net/core/net-delayacct.c because it touches
 * sk->sk_net_delayacct and thus requires the full definition of
 * struct sock, which is not available when this header is included
 * from include/net/sock.h.
 */
void net_delayacct_rx_end(struct sock *sk, struct sk_buff *skb);

/**
 * net_delayacct_tx_start - stamp TX start time on an skb
 * @skb: the outgoing &sk_buff
 *
 * Called at tcp_sendmsg / udp_sendmsg entry, on each newly allocated
 * skb, before it enters the IP layer.
 */
static inline void net_delayacct_tx_start(struct sk_buff *skb)
{
	skb->delayacct_start = ktime_get_ns();
}

/**
 * net_delayacct_tx_end - accumulate TX latency on a socket
 * @sk:  the originating socket (may be NULL for some paths)
 * @skb: the skb about to be handed to the driver
 *
 * Computes the delta from skb->delayacct_start to "now" and adds it
 * to the per-socket TX total.  Called from dev_hard_start_xmit.
 *
 * Defined out-of-line in net/core/net-delayacct.c (see
 * net_delayacct_rx_end for the reason).
 */
void net_delayacct_tx_end(struct sock *sk, struct sk_buff *skb);

/**
 * net_delayacct_get_stats - read a snapshot of the per-socket stats
 * @sk:  target socket
 * @out: destination for the snapshot
 *
 * Returns a consistent copy under the per-socket spinlock.
 *
 * Defined out-of-line in net/core/net-delayacct.c.
 */
void net_delayacct_get_stats(struct sock *sk,
			     struct net_delayacct_stats *out);

/**
 * net_delayacct_reset - zero the per-socket statistics
 * @sk: target socket
 *
 * Defined out-of-line in net/core/net-delayacct.c.
 */
void net_delayacct_reset(struct sock *sk);

#else	/* CONFIG_NET_DELAYACCT */

static inline void net_delayacct_init(struct net_delayacct *n) {}
static inline void net_delayacct_rx_start(struct sk_buff *skb) {}
static inline void net_delayacct_rx_end(struct sock *sk, struct sk_buff *skb) {}
static inline void net_delayacct_tx_start(struct sk_buff *skb) {}
static inline void net_delayacct_tx_end(struct sock *sk, struct sk_buff *skb) {}
static inline void net_delayacct_get_stats(struct sock *sk,
					   struct net_delayacct_stats *out)
{
	memset(out, 0, sizeof(*out));
}
static inline void net_delayacct_reset(struct sock *sk) {}

#endif	/* CONFIG_NET_DELAYACCT */

#endif	/* _NET_DELAYACCT_H */
