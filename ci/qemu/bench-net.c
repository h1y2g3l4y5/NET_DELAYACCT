// SPDX-License-Identifier: GPL-2.0-only
/* Copyright (c) 2026 laiguo-liang <2909269677@qq.com> */
/*
 * bench-net.c — NET_DELAYACCT 固定工作量网络微基准（guest 侧）
 *
 * 替代 iperf3 速率驱动模型的物理依据（20260816 方案重建）：
 *
 * 旧方案的信噪比倒挂：
 *   信号 = net_delayacct hook 开销（TX 2 点 + RX 2 点，每包 4 次调用，
 *          单次 ~50-150ns）→ 在 21.5Gbps 大包吞吐里被 memcpy 稀释到 ~1%
 *   噪声 = QEMU 2 vCPU 调度 + 共享 runner 时段漂移 → K0 基线轮间 ±3-6%，
 *          尾延迟 ±30-90%（K0-vs-K0B 噪声地板实测 53.6%/90.2%）
 *   iperf3 跑固定 10s：工作量不固定，任何调度扰动直接进结果
 *
 * 本基准的四个设计约束：
 *   1. 固定循环次数 N：工作量恒定，K0/K2 总耗时差 = 插桩开销，
 *      分辨率 ~0.1%，不受"这一轮碰上什么调度"影响
 *   2. 信号放大：64B UDP 自发自收单循环 ~2-5us（KVM），hook 命中
 *      4 次（tx_start/tx_end/rx_start/rx_end），hook 占比 5-20%
 *   3. 单进程单核：sched_setaffinity(CPU0) + SCHED_FIFO（fallback
 *      SCHED_OTHER），消除 guest 内调度噪声；配合 QEMU -smp 1
 *   4. 自动校准 N：warmup 实测单循环耗时，动态选 N 使每轮 ~1s，
 *      KVM/TCG 自适应，无需 host 传参；-n 可强制固定 N（ftrace
 *      对账时需要 hooks_per_op = trace_count / N 的确定分母）
 *
 * 输出（run-perf-tests.sh 消费）：
 *   BENCH: env=<cpu0|any>:<rt|normal>       环境控制状态
 *   BENCH: udp64 n=<N> ns_per_op=<x.x>      每轮一行
 *   BENCH: tcprw n=<N> ns_per_op=<x.x>
 *   BENCH: error=<what>                     失败（exit 1）
 *
 * UDP 循环路径（loopback）：sendto → udp_sendmsg[tx_start] →
 *   dev_queue_xmit[tx_end] → loopback_xmit → netif_rx backlog →
 *   softirq: netif_receive_skb[rx_start] → udp_rcv → 队列 →
 *   recvfrom → udp_recvmsg[rx_end]。
 * TCP 循环路径：write → tcp_sendmsg → __tcp_transmit_skb[tx_start] →
 *   dev_queue_xmit[tx_end] → ... → tcp_recvmsg found_ok_skb[rx_end]。
 * （TCP_NODELAY 必须：write-read pingpong 被 Nagle+延迟 ACK 坑 40ms）
 */
#define _GNU_SOURCE	/* sched_setaffinity / CPU_ZERO are GNU extensions */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <sched.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#define UDP_PAYLOAD	64
#define TCP_PAYLOAD	1024
#define WARMUP_LOOPS	2000
#define RECV_TIMEOUT_S	5

static const char *g_env_str = "unpinned:normal";

static long long now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/*
 * 绑 CPU0 + 提升调度优先级。返回描述串。
 * SCHED_FIFO 安全性：主循环每次 recvfrom/read 都会睡眠（等待 softirq
 * 完成收包），不会饿死同核内核线程；RT bandwidth（默认 95%/1s）不会
 * 触发。失败只降级不报错：unprivileged 环境仍可测，host 侧报告中
 * env= 状态可见，判定口径一致性由 K0/K2 同环境保证。
 */
static void setup_env(void)
{
	cpu_set_t set;
	struct sched_param sp = { .sched_priority = 1 };
	int pinned = 0;

	CPU_ZERO(&set);
	CPU_SET(0, &set);
	if (sched_setaffinity(0, sizeof(set), &set) == 0)
		pinned = 1;

	if (sched_setscheduler(0, SCHED_FIFO, &sp) == 0)
		g_env_str = pinned ? "cpu0:rt" : "any:rt";
	else
		g_env_str = pinned ? "cpu0:normal" : "unpinned:normal";
}

static void set_recv_timeout(int fd)
{
	struct timeval tv = { .tv_sec = RECV_TIMEOUT_S };

	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
}

/*
 * UDP 64B 自发自收单循环基准。返回 ns/op，实际使用的 N 经 *out_n
 * 带出（自动校准时后续轮复用同一 N，保证轮间工作量一致）；失败 -1。
 * 端口由内核分配（bind INADDR_LOOPBACK:0 + getsockname）。
 */
static double bench_udp64(long long n, long long *out_n)
{
	int fd, i;
	struct sockaddr_in addr, from;
	socklen_t alen = sizeof(addr), flen;
	char buf[UDP_PAYLOAD];
	long long t0, t1;
	ssize_t r;

	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		printf("BENCH: error=udp_socket(%s)\n", strerror(errno));
		return -1;
	}
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = 0;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
	    getsockname(fd, (struct sockaddr *)&addr, &alen) < 0) {
		printf("BENCH: error=udp_bind(%s)\n", strerror(errno));
		close(fd);
		return -1;
	}
	set_recv_timeout(fd);
	memset(&from, 0, sizeof(from));

	/* warmup：稳定 cache/分支预测，同时为自动校准测单循环耗时 */
	t0 = now_ns();
	for (i = 0; i < WARMUP_LOOPS; i++) {
		if (sendto(fd, buf, UDP_PAYLOAD, 0,
			   (struct sockaddr *)&addr, sizeof(addr)) != UDP_PAYLOAD ||
		    recvfrom(fd, buf, sizeof(buf), 0,
			     (struct sockaddr *)&from, &flen) != UDP_PAYLOAD) {
			printf("BENCH: error=udp_warmup(%s)\n", strerror(errno));
			close(fd);
			return -1;
		}
	}
	t1 = now_ns();

	if (n <= 0) {
		/* 自动校准：N = 目标 1s / 单循环耗时，夹在 [20k, 500k] */
		double per_op = (double)(t1 - t0) / WARMUP_LOOPS;
		n = (long long)(1e9 / per_op);
		if (n < 20000)
			n = 20000;
		if (n > 500000)
			n = 500000;
	}

	t0 = now_ns();
	for (i = 0; i < n; i++) {
		if (sendto(fd, buf, UDP_PAYLOAD, 0,
			   (struct sockaddr *)&addr, sizeof(addr)) != UDP_PAYLOAD) {
			printf("BENCH: error=udp_sendto(%s)\n", strerror(errno));
			close(fd);
			return -1;
		}
		r = recvfrom(fd, buf, sizeof(buf), 0,
			     (struct sockaddr *)&from, &flen);
		if (r != UDP_PAYLOAD) {
			printf("BENCH: error=udp_recvfrom(%s,ret=%zd)\n",
			       strerror(errno), r);
			close(fd);
			return -1;
		}
	}
	t1 = now_ns();
	close(fd);

	if (out_n)
		*out_n = n;
	printf("BENCH: udp64 n=%lld ns_per_op=%.1f\n",
	       n, (double)(t1 - t0) / n);
	return (double)(t1 - t0) / n;
}

/*
 * TCP 1KB write+read 单循环基准（单进程 self-connect）。
 * listen + connect 自己 + accept：无需 fork，路径仍是完整 TCP/IP 栈。
 */
static double bench_tcprw(long long n, long long *out_n)
{
	int lfd, cfd, sfd, i, on = 1;
	struct sockaddr_in addr;
	socklen_t alen = sizeof(addr);
	char buf[TCP_PAYLOAD];
	long long t0, t1;
	ssize_t r;
	size_t got;

	lfd = socket(AF_INET, SOCK_STREAM, 0);
	if (lfd < 0) {
		printf("BENCH: error=tcp_socket(%s)\n", strerror(errno));
		return -1;
	}
	setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = 0;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
	    listen(lfd, 1) < 0 ||
	    getsockname(lfd, (struct sockaddr *)&addr, &alen) < 0) {
		printf("BENCH: error=tcp_bind(%s)\n", strerror(errno));
		close(lfd);
		return -1;
	}

	cfd = socket(AF_INET, SOCK_STREAM, 0);
	if (cfd < 0 ||
	    connect(cfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		printf("BENCH: error=tcp_connect(%s)\n", strerror(errno));
		close(lfd);
		return -1;
	}
	sfd = accept(lfd, NULL, NULL);
	if (sfd < 0) {
		printf("BENCH: error=tcp_accept(%s)\n", strerror(errno));
		close(lfd);
		close(cfd);
		return -1;
	}
	close(lfd);
	setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
	setsockopt(sfd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
	set_recv_timeout(cfd);
	set_recv_timeout(sfd);

	/* warmup（服务端读端不需要 timeout：数据已由 write 同步入队） */
	t0 = now_ns();
	for (i = 0; i < WARMUP_LOOPS; i++) {
		if (write(cfd, buf, TCP_PAYLOAD) != TCP_PAYLOAD) {
			printf("BENCH: error=tcp_warmup_write(%s)\n",
			       strerror(errno));
			goto fail;
		}
		got = 0;
		while (got < TCP_PAYLOAD) {
			r = read(sfd, buf + got, TCP_PAYLOAD - got);
			if (r <= 0) {
				printf("BENCH: error=tcp_warmup_read(%s)\n",
				       strerror(errno));
				goto fail;
			}
			got += r;
		}
	}
	t1 = now_ns();

	if (n <= 0) {
		double per_op = (double)(t1 - t0) / WARMUP_LOOPS;

		n = (long long)(1e9 / per_op);
		if (n < 20000)
			n = 20000;
		if (n > 500000)
			n = 500000;
	}

	t0 = now_ns();
	for (i = 0; i < n; i++) {
		if (write(cfd, buf, TCP_PAYLOAD) != TCP_PAYLOAD) {
			printf("BENCH: error=tcp_write(%s)\n", strerror(errno));
			goto fail;
		}
		got = 0;
		while (got < TCP_PAYLOAD) {
			r = read(sfd, buf + got, TCP_PAYLOAD - got);
			if (r <= 0) {
				printf("BENCH: error=tcp_read(%s)\n",
				       strerror(errno));
				goto fail;
			}
			got += r;
		}
	}
	t1 = now_ns();
	close(cfd);
	close(sfd);

	if (out_n)
		*out_n = n;
	printf("BENCH: tcprw n=%lld ns_per_op=%.1f\n",
	       n, (double)(t1 - t0) / n);
	return (double)(t1 - t0) / n;

fail:
	close(cfd);
	close(sfd);
	return -1;
}

int main(int argc, char **argv)
{
	int rounds = 5, i;
	long long fixed_n = 0;	/* 0 = 自动校准 */
	const char *mode = "all";

	for (i = 1; i < argc; i++) {
		if (!strncmp(argv[i], "-r=", 3))
			rounds = atoi(argv[i] + 3);
		else if (!strncmp(argv[i], "-n=", 3))
			fixed_n = atoll(argv[i] + 3);
		else if (!strncmp(argv[i], "-m=", 3))
			mode = argv[i] + 3;
	}
	if (rounds < 1)
		rounds = 1;

	setup_env();
	printf("BENCH: env=%s mode=%s rounds=%d\n", g_env_str, mode, rounds);

	/*
	 * 自动校准时第一轮 n=0 触发校准，实际 N 经 out_n 带出后
	 * 复用到后续轮，保证轮间工作量一致（中位数才有可比性）。
	 */
	if (!strcmp(mode, "all") || !strcmp(mode, "udp64")) {
		long long n = fixed_n;

		for (i = 0; i < rounds; i++) {
			if (bench_udp64(n, &n) < 0)
				return 1;
		}
	}
	if (!strcmp(mode, "all") || !strcmp(mode, "tcprw")) {
		long long n = fixed_n;

		for (i = 0; i < rounds; i++) {
			if (bench_tcprw(n, &n) < 0)
				return 1;
		}
	}
	return 0;
}
