// SPDX-License-Identifier: GPL-2.0-only
/*
 * KUnit tests for CONFIG_NET_DELAYACCT
 *
 * Test cases:
 *   1. net_delayacct_test_init_reset       - init/reset produce zero stats
 *   2. net_delayacct_test_rx_accumulation  - RX path accumulates correctly
 *   3. net_delayacct_test_tx_accumulation  - TX path accumulates correctly
 *   4. net_delayacct_test_concurrent       - concurrent accumulation is safe
 *   5. net_delayacct_test_skip_zero_start  - zero start timestamp is skipped
 *
 * The test module stubs struct sock and struct sk_buff via kunit_kzalloc
 * to keep it self-contained without requiring a full network stack setup.
 */

#include <kunit/test.h>
#include <linux/skbuff.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/atomic.h>
#include <net/sock.h>
#include <net/net-delayacct.h>

#define CONCURRENCY_ITERS	100
#define CONCURRENCY_THREADS	4

/*
 * Fallback definition of KUNIT_DEFINE_TEST_SUITE for kernels that do
 * not yet provide it (e.g. Linux 6.6). This macro defines a struct
 * kunit_suite and registers it via kunit_test_suite().
 */
#ifndef KUNIT_DEFINE_TEST_SUITE
#define KUNIT_DEFINE_TEST_SUITE(suite_name, test_cases)			\
	static struct kunit_suite suite_name = {				\
		.name = __stringify(suite_name),				\
		.test_cases = test_cases,					\
	};								\
	kunit_test_suite(suite_name)
#endif

/*
 * Build a minimal stub sock for testing.  A real struct sock requires
 * extensive initialization; we only need the net_delayacct field so a
 * zeroed allocation suffices.
 */
static struct sock *stub_sock_create(struct kunit *test)
{
	struct sock *sk;

	sk = kunit_kzalloc(test, sizeof(*sk), GFP_KERNEL);
	KUNIT_ASSERT_NOT_NULL(test, sk);

	return sk;
}

/*
 * Build a minimal stub skb for testing.  Only the delayacct_start
 * field is relevant; the rest is zeroed.
 */
static struct sk_buff *stub_skb_create(struct kunit *test)
{
	struct sk_buff *skb;

	skb = kunit_kzalloc(test, sizeof(*skb), GFP_KERNEL);
	KUNIT_ASSERT_NOT_NULL(test, skb);

	return skb;
}

/*
 * Test 1: init leaves stats zero; reset keeps stats zero.
 *
 * Verifies that net_delayacct_init() initializes all counters to zero
 * and that net_delayacct_reset() also yields all-zero state.
 */
static void net_delayacct_test_init_reset(struct kunit *test)
{
	struct sock *sk = stub_sock_create(test);

	net_delayacct_init(&sk->sk_net_delayacct);

	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.rx_total_ns, 0);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.rx_count, 0);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.tx_total_ns, 0);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.tx_count, 0);

	/* Reset on already-zero state must remain zero */
	net_delayacct_reset(&sk->sk_net_delayacct);

	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.rx_total_ns, 0);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.rx_count, 0);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.tx_total_ns, 0);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.tx_count, 0);
}

/*
 * Test 2: simulate RX start/end on a fake skb and verify accumulation.
 *
 * Verifies that after a single RX cycle:
 *   - rx_total_ns > 0  (a measurable delay was recorded)
 *   - rx_count == 1    (exactly one packet accounted)
 *   - TX counters remain untouched
 */
static void net_delayacct_test_rx_accumulation(struct kunit *test)
{
	struct sock *sk = stub_sock_create(test);
	struct sk_buff *skb = stub_skb_create(test);

	net_delayacct_init(&sk->sk_net_delayacct);

	/* Simulate packet entering the protocol stack */
	net_delayacct_rx_start(skb);

	/* Small delay to ensure a measurable time delta */
	fsleep(1000);

	/* Simulate packet being copied to user space */
	net_delayacct_rx_end(sk, skb);

	KUNIT_EXPECT_GT(test, sk->sk_net_delayacct.rx_total_ns, 0);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.rx_count, 1);

	/* TX side must remain untouched */
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.tx_total_ns, 0);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.tx_count, 0);
}

/*
 * Test 3: simulate TX start/end on a fake skb and verify accumulation.
 *
 * Verifies that after a single TX cycle:
 *   - tx_total_ns > 0  (a measurable delay was recorded)
 *   - tx_count == 1    (exactly one packet accounted)
 *   - RX counters remain untouched
 */
static void net_delayacct_test_tx_accumulation(struct kunit *test)
{
	struct sock *sk = stub_sock_create(test);
	struct sk_buff *skb = stub_skb_create(test);

	net_delayacct_init(&sk->sk_net_delayacct);

	/* Simulate process entering sendmsg */
	net_delayacct_tx_start(skb);

	fsleep(1000);

	/* Simulate packet reaching the driver via dev_hard_start_xmit */
	net_delayacct_tx_end(sk, skb);

	KUNIT_EXPECT_GT(test, sk->sk_net_delayacct.tx_total_ns, 0);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.tx_count, 1);

	/* RX side must remain untouched */
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.rx_total_ns, 0);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.rx_count, 0);
}

/*
 * Test 4: concurrent rx_end from multiple kthreads.
 *
 * Spawns CONCURRENCY_THREADS kthreads, each performing CONCURRENCY_ITERS
 * RX accumulation cycles.  Verifies that:
 *   - rx_count == CONCURRENCY_THREADS * CONCURRENCY_ITERS (no lost updates)
 *   - rx_total_ns > 0
 *   - TX counters remain zero
 *
 * This validates the per-socket spinlock provides adequate SMP safety.
 */
struct concurrency_ctx {
	struct sock *sk;
	atomic_t remaining;
};

static int concurrency_thread_fn(void *data)
{
	struct concurrency_ctx *ctx = data;
	struct sk_buff skb_stub;
	int i;

	for (i = 0; i < CONCURRENCY_ITERS; i++) {
		memset(&skb_stub, 0, sizeof(skb_stub));
		net_delayacct_rx_start(&skb_stub);
		net_delayacct_rx_end(ctx->sk, &skb_stub);
	}

	atomic_dec(&ctx->remaining);
	return 0;
}

static void net_delayacct_test_concurrent_accumulation(struct kunit *test)
{
	struct sock *sk = stub_sock_create(test);
	struct concurrency_ctx ctx;
	struct task_struct *tasks[CONCURRENCY_THREADS];
	int i;

	net_delayacct_init(&sk->sk_net_delayacct);
	ctx.sk = sk;
	atomic_set(&ctx.remaining, CONCURRENCY_THREADS);

	for (i = 0; i < CONCURRENCY_THREADS; i++) {
		tasks[i] = kthread_run(concurrency_thread_fn, &ctx,
				       "net_da_conc_%d", i);
		KUNIT_ASSERT_NOT_ERR_OR_NULL(test, tasks[i]);
	}

	/* Wait for all threads to finish */
	while (atomic_read(&ctx.remaining) > 0)
		fsleep(1000);

	/* Expected total count = threads * iterations per thread */
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.rx_count,
			(u64)(CONCURRENCY_THREADS * CONCURRENCY_ITERS));
	KUNIT_EXPECT_GT(test, sk->sk_net_delayacct.rx_total_ns, 0);

	/* No leaks into TX */
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.tx_count, 0);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.tx_total_ns, 0);

	for (i = 0; i < CONCURRENCY_THREADS; i++)
		kthread_stop(tasks[i]);
}

/*
 * Test 5: skb with delayacct_start == 0 must not accumulate.
 *
 * An skb that never had rx_start/tx_start called (delayacct_start is 0)
 * must be silently skipped by rx_end/tx_end to avoid bogus accumulation.
 * Verifies that both RX and TX end calls are no-ops in this case.
 */
static void net_delayacct_test_skip_zero_start(struct kunit *test)
{
	struct sock *sk = stub_sock_create(test);
	struct sk_buff *skb = stub_skb_create(test);

	net_delayacct_init(&sk->sk_net_delayacct);

	/* delayacct_start is 0 because we kzalloc'd; verify explicitly */
	KUNIT_EXPECT_EQ(test, (u64)skb->delayacct_start, 0);

	/* RX end without prior start must be a no-op */
	net_delayacct_rx_end(sk, skb);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.rx_count, 0);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.rx_total_ns, 0);

	/* TX end without prior start must be a no-op */
	net_delayacct_tx_end(sk, skb);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.tx_count, 0);
	KUNIT_EXPECT_EQ(test, sk->sk_net_delayacct.tx_total_ns, 0);
}

static struct kunit_case net_delayacct_test_cases[] = {
	KUNIT_CASE(net_delayacct_test_init_reset),
	KUNIT_CASE(net_delayacct_test_rx_accumulation),
	KUNIT_CASE(net_delayacct_test_tx_accumulation),
	KUNIT_CASE(net_delayacct_test_concurrent_accumulation),
	KUNIT_CASE(net_delayacct_test_skip_zero_start),
	{},  /* sentinel */
};

KUNIT_DEFINE_TEST_SUITE(net_delayacct_test_suite, net_delayacct_test_cases);

MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("KUnit tests for CONFIG_NET_DELAYACCT");
MODULE_AUTHOR("NET_DELAYACCT project");
