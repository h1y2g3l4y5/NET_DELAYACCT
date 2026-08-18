// SPDX-License-Identifier: GPL-2.0-only
/* Copyright (c) 2026 laiguo-liang <2909269677@qq.com> */
/*
 * bench-net.c — NET_DELAYACCT 固定工作量网络微基准（guest 侧）
 *
 * 20260817 矩阵化重构（v2）：
 *
 *   指标体系收敛为「每包 CPU 成本」（Δns/op，工具固有属性），
 *   吞吐百分比/占用率均为导出量不再测量；tcprw 单点模式废弃，
 *   改为 3 维矩阵扫描成本规律：
 *     路径  : udp4 / tcp4 / udp6 / tcp6（hooks 覆盖的核心路径）
 *     尺寸  : 64B / 1400B / 65000B（小包 / MTU 量级 / GSO 大包）
 *     压力  : 1 流 / 16 流交错（同核 socket 轮转，测统计结构
 *             cache 局部性；跨核锁争用需 -smp>1，不在此测）
 *   矩阵 4×3×2=24 格，每格独立校准 N。物理预期：
 *     - 绝对 Δns/格 随尺寸平稳（税按 skb 收），相对值 1/尺寸 摊薄
 *     - Δns ≈ hooks/op × 单次 hook ns（ftrace 对账，逐格验证）
 *
 * v1 设计约束保留：
 *   1. 固定循环次数 N：工作量恒定，ON/OFF 总耗时差 = 插桩开销
 *   2. 信号放大：64B 小包路径 hook 占比 5-20%
 *   3. 单进程单核：sched_setaffinity(CPU0) + SCHED_FIFO（fallback），
 *      配合 QEMU -smp 1
 *   4. 自动校准 N（~1s/轮，夹在 20k-500k）；-n 强制固定 N
 *      （ftrace 计数需要确定分母）
 *
 * UDP 65000B：合法（< 65507 max payload）；TCP 65000B：loopback MTU
 * 65536，单 write 期望聚成 1 个 GSO skb——验证"税按 skb 收"的关键格。
 *
 * 输出（run-perf-tests.sh 消费）：
 *   BENCH: env=<cpu0|any>:<rt|normal>       环境控制状态
 *   BENCH: <cell> n=<N> ns_per_op=<x.x>     每轮一行，cell=<path>_<size>f<flows>
 *   BENCH: error=<what>                     失败（exit 1）
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

#define WARMUP_LOOPS	2000
#define RECV_TIMEOUT_S	5
#define MAX_PAYLOAD	65000
#define MAX_FLOWS	16

static const char *g_env_str = "unpinned:normal";

static long long now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* 绑 CPU0 + 提升调度优先级；失败降级不报错（K0/K3 同环境保证口径一致） */
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

/* ------------------------------------------------------------------ */
/* 通用 UDP 基准：flows 个 UDP socket 各绑独立端口，op i 用 socket	*/
/* i%flows 自发自收 payload 字节。ipv6=1 用 ::1，否则 127.0.0.1。	*/
/* ------------------------------------------------------------------ */
static double bench_udp(int family, int payload, int flows,
			long long n, long long *out_n)
{
	int fd[MAX_FLOWS];
	struct sockaddr_storage addr[MAX_FLOWS], from;
	socklen_t alen, flen;
	static char buf[MAX_PAYLOAD];
	long long t0, t1;
	ssize_t r;
	int i, k, nf = 0;

	for (k = 0; k < flows; k++) {
		fd[k] = -1;
		if (family == AF_INET6) {
			struct sockaddr_in6 *a6 = (struct sockaddr_in6 *)&addr[k];

			memset(a6, 0, sizeof(*a6));
			a6->sin6_family = AF_INET6;
			a6->sin6_port = 0;
			a6->sin6_addr = in6addr_loopback;
			alen = sizeof(*a6);
		} else {
			struct sockaddr_in *a4 = (struct sockaddr_in *)&addr[k];

			memset(a4, 0, sizeof(*a4));
			a4->sin_family = AF_INET;
			a4->sin_port = 0;
			a4->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
			alen = sizeof(*a4);
		}
		fd[k] = socket(family, SOCK_DGRAM, 0);
		if (fd[k] < 0 || bind(fd[k], (struct sockaddr *)&addr[k], alen) < 0 ||
		    getsockname(fd[k], (struct sockaddr *)&addr[k], &alen) < 0) {
			printf("BENCH: error=udp_socket(%s)\n", strerror(errno));
			goto fail;
		}
		set_recv_timeout(fd[k]);
		nf++;
	}
	flen = sizeof(from);

	t0 = now_ns();
	for (i = 0; i < WARMUP_LOOPS; i++) {
		k = i % flows;
		if (sendto(fd[k], buf, payload, 0, (struct sockaddr *)&addr[k], alen) != payload ||
		    recvfrom(fd[k], buf, sizeof(buf), 0,
			     (struct sockaddr *)&from, &flen) != payload) {
			printf("BENCH: error=udp_warmup(%s)\n", strerror(errno));
			goto fail;
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
		k = i % flows;
		if (sendto(fd[k], buf, payload, 0,
			   (struct sockaddr *)&addr[k], alen) != payload) {
			printf("BENCH: error=udp_sendto(%s)\n", strerror(errno));
			goto fail;
		}
		r = recvfrom(fd[k], buf, sizeof(buf), 0,
			     (struct sockaddr *)&from, &flen);
		if (r != payload) {
			printf("BENCH: error=udp_recvfrom(%s,ret=%zd)\n",
			       strerror(errno), r);
			goto fail;
		}
	}
	t1 = now_ns();

	for (k = 0; k < nf; k++)
		close(fd[k]);
	if (out_n)
		*out_n = n;
	return (double)(t1 - t0) / n;

fail:
	for (k = 0; k < nf; k++)
		close(fd[k]);
	return -1;
}

/* ------------------------------------------------------------------ */
/* 通用 TCP 基准：flows 对 self-connect socket（listen+connect+accept	*/
/* 无需 fork），op i 在第 i%flows 对上 write payload + 读满 payload。	*/
/* TCP_NODELAY 必须：write-read pingpong 被 Nagle+延迟 ACK 坑 40ms。	*/
/* ------------------------------------------------------------------ */
static double bench_tcp(int family, int payload, int flows,
			long long n, long long *out_n)
{
	int lfd = -1, cfd[MAX_FLOWS], sfd[MAX_FLOWS];
	struct sockaddr_storage addr;
	socklen_t alen;
	static char buf[MAX_PAYLOAD];
	long long t0, t1;
	ssize_t r;
	size_t got;
	int i, k, on = 1, npair = 0;

	for (k = 0; k < flows; k++) {
		cfd[k] = -1;
		sfd[k] = -1;
	}

	lfd = socket(family, SOCK_STREAM, 0);
	if (lfd < 0) {
		printf("BENCH: error=tcp_socket(%s)\n", strerror(errno));
		return -1;
	}
	setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
	if (family == AF_INET6) {
		struct sockaddr_in6 *a6 = (struct sockaddr_in6 *)&addr;

		memset(a6, 0, sizeof(*a6));
		a6->sin6_family = AF_INET6;
		a6->sin6_port = 0;
		a6->sin6_addr = in6addr_loopback;
		alen = sizeof(*a6);
	} else {
		struct sockaddr_in *a4 = (struct sockaddr_in *)&addr;

		memset(a4, 0, sizeof(*a4));
		a4->sin_family = AF_INET;
		a4->sin_port = 0;
		a4->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		alen = sizeof(*a4);
	}
	if (bind(lfd, (struct sockaddr *)&addr, alen) < 0 ||
	    listen(lfd, flows + 1) < 0 ||
	    getsockname(lfd, (struct sockaddr *)&addr, &alen) < 0) {
		printf("BENCH: error=tcp_bind(%s)\n", strerror(errno));
		goto fail;
	}

	for (k = 0; k < flows; k++) {
		cfd[k] = socket(family, SOCK_STREAM, 0);
		if (cfd[k] < 0 ||
		    connect(cfd[k], (struct sockaddr *)&addr, alen) < 0) {
			printf("BENCH: error=tcp_connect(%s)\n", strerror(errno));
			goto fail;
		}
		sfd[k] = accept(lfd, NULL, NULL);
		if (sfd[k] < 0) {
			printf("BENCH: error=tcp_accept(%s)\n", strerror(errno));
			goto fail;
		}
		setsockopt(cfd[k], IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
		setsockopt(sfd[k], IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
		set_recv_timeout(cfd[k]);
		npair++;
	}
	close(lfd);
	lfd = -1;

	t0 = now_ns();
	for (i = 0; i < WARMUP_LOOPS; i++) {
		k = i % flows;
		if (write(cfd[k], buf, payload) != payload) {
			printf("BENCH: error=tcp_warmup_write(%s)\n",
			       strerror(errno));
			goto fail;
		}
		got = 0;
		while (got < (size_t)payload) {
			r = read(sfd[k], buf + got, payload - got);
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
		k = i % flows;
		if (write(cfd[k], buf, payload) != payload) {
			printf("BENCH: error=tcp_write(%s)\n", strerror(errno));
			goto fail;
		}
		got = 0;
		while (got < (size_t)payload) {
			r = read(sfd[k], buf + got, payload - got);
			if (r <= 0) {
				printf("BENCH: error=tcp_read(%s)\n",
				       strerror(errno));
				goto fail;
			}
			got += r;
		}
	}
	t1 = now_ns();

	for (k = 0; k < npair; k++) {
		close(cfd[k]);
		close(sfd[k]);
	}
	if (out_n)
		*out_n = n;
	return (double)(t1 - t0) / n;

fail:
	if (lfd >= 0)
		close(lfd);
	for (k = 0; k < npair; k++) {
		close(cfd[k]);
		close(sfd[k]);
	}
	return -1;
}

/* 跑一个矩阵格：mode(udp4|tcp4|udp6|tcp6) × size × flows × rounds 轮 */
static int run_cell(const char *mode, int size, int flows,
		    int rounds, long long fixed_n)
{
	long long n = fixed_n;
	int family = (mode[3] == '6') ? AF_INET6 : AF_INET;
	int is_tcp = (mode[0] == 't');
	char cell[64];
	double v;
	int i;

	snprintf(cell, sizeof(cell), "%s_%df%d", mode, size, flows);
	printf("BENCH: cell=%s\n", cell);

	for (i = 0; i < rounds; i++) {
		if (is_tcp)
			v = bench_tcp(family, size, flows, n, &n);
		else
			v = bench_udp(family, size, flows, n, &n);
		if (v < 0)
			return 1;
		printf("BENCH: %s n=%lld ns_per_op=%.1f\n", cell, n, v);
	}
	return 0;
}

int main(int argc, char **argv)
{
	int rounds = 5, i;
	long long fixed_n = 0;	/* 0 = 自动校准 */
	const char *mode = "all";
	const char *size_s = "64";
	const char *flows_s = "1";
	static const char * const paths[] = { "udp4", "tcp4", "udp6", "tcp6" };
	static const int sizes[] = { 64, 1400, 65000 };
	static const int flows_arr[] = { 1, 16 };

	for (i = 1; i < argc; i++) {
		if (!strncmp(argv[i], "-r=", 3))
			rounds = atoi(argv[i] + 3);
		else if (!strncmp(argv[i], "-n=", 3))
			fixed_n = atoll(argv[i] + 3);
		else if (!strncmp(argv[i], "-m=", 3))
			mode = argv[i] + 3;
		else if (!strncmp(argv[i], "-s=", 3))
			size_s = argv[i] + 3;
		else if (!strncmp(argv[i], "-f=", 3))
			flows_s = argv[i] + 3;
	}
	if (rounds < 1)
		rounds = 1;

	setup_env();
	printf("BENCH: env=%s mode=%s size=%s flows=%s rounds=%d\n",
	       g_env_str, mode, size_s, flows_s, rounds);

	if (!strcmp(mode, "all")) {
		/* 全矩阵 24 格：4 路径 × 3 尺寸 × 2 压力 */
		int p, s, f;

		for (f = 0; f < 2; f++)
			for (s = 0; s < 3; s++)
				for (p = 0; p < 4; p++)
					if (run_cell(paths[p], sizes[s],
						     flows_arr[f], rounds,
						     fixed_n))
						return 1;
		return 0;
	}

	/* 单格模式：-m=<path> -s=<size> -f=<flows> */
	{
		int size = atoi(size_s);
		int flows = atoi(flows_s);

		if (size <= 0 || size > MAX_PAYLOAD) {
			printf("BENCH: error=bad_size(%s)\n", size_s);
			return 1;
		}
		if (flows < 1 || flows > MAX_FLOWS) {
			printf("BENCH: error=bad_flows(%s)\n", flows_s);
			return 1;
		}
		return run_cell(mode, size, flows, rounds, fixed_n);
	}
}
