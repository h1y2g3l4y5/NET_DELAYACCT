// SPDX-License-Identifier: GPL-2.0-only
/*
 * delayacct_path_test.c — 辅助测试程序，覆盖 iperf3 无法触发的已插桩路径
 *
 * 用途：
 *   run-tests.sh 中 Test 17-19 调用本程序，验证内核 net_delayacct 框架对
 *   TCP splice RX / TCP zerocopy RX / UDP corked TX 三条路径的打点。
 *   iperf3 只走普通 sendmsg/recvmsg，无法触发这些路径，因此需要专门程序。
 *
 * 子命令：
 *   splice-server <port>
 *       TCP listen → accept → splice() 循环把数据导到 /dev/null
 *       覆盖 tcp_read_sock() 路径的 rx_end 打点
 *
 *   zerocopy-server <port>
 *       TCP listen → accept → mmap + TCP_ZEROCOPY_RECEIVE 循环
 *       覆盖 tcp_zerocopy_receive() 路径的 rx_end 打点
 *
 *   corked-udp-client <ip> <port> [duration_sec]
 *       创建 UDP socket → setsockopt(UDP_CORK) → sendto 循环 → close 触发 flush
 *       覆盖 udp_push_pending_frames() 路径的 tx_start 打点
 *
 *   corked-udp6-client <ipv6> <port> [duration_sec]
 *       IPv6 版本的 corked-udp-client，使用 AF_INET6 + IPV6_V6ONLY + ::1
 *       覆盖 udp_v6_push_pending_frames() 路径的 tx_start 打点
 *
 * 设计要点：
 *   - server 模式 accept 后持续读取，直到对端关闭（read 返回 0）或被信号终止，
 *     保持 socket 存活以便 run-tests.sh 在查询期间能枚举到统计。
 *   - 程序打印自己的 PID 到 stdout 第一行，便于脚本捕获。
 *   - 退出码：0 正常结束，非 0 出错。
 *
 * 编译：见同目录 Makefile（host 上静态编译，打包进 initramfs）
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/tcp.h>
#include <netinet/in.h>
#include <netinet/udp.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop = 0;

static void on_sigterm(int sig)
{
	(void)sig;
	g_stop = 1;
}

/* TCP server: splice() 数据到 /dev/null，覆盖 tcp_read_sock RX 路径 */
static int do_splice_server(int port)
{
	int lfd = socket(AF_INET, SOCK_STREAM, 0);
	if (lfd < 0) {
		perror("socket");
		return 1;
	}
	int yes = 1;
	setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	addr.sin_port = htons(port);
	if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		perror("bind");
		close(lfd);
		return 1;
	}
	if (listen(lfd, 1) < 0) {
		perror("listen");
		close(lfd);
		return 1;
	}

	fprintf(stderr, "splice-server: listening on 127.0.0.1:%d pid=%d\n",
		port, getpid());
	fflush(stderr);

	int cfd = accept(lfd, NULL, NULL);
	if (cfd < 0) {
		perror("accept");
		close(lfd);
		return 1;
	}
	close(lfd); /* 只服务一个连接 */

	int nullfd = open("/dev/null", O_WRONLY);
	if (nullfd < 0) {
		perror("open /dev/null");
		close(cfd);
		return 1;
	}

	/* splice 循环：socket → pipe → /dev/null
	 * 注意 splice 不能直接 socket→/dev/null（pipe only），需中转 pipe */
	int pipefd[2];
	if (pipe(pipefd) < 0) {
		perror("pipe");
		close(cfd);
		close(nullfd);
		return 1;
	}

	ssize_t total = 0;
	while (!g_stop) {
		ssize_t n = splice(cfd, NULL, pipefd[1], NULL, 65536, 0);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				/* 对端可能还在写，短暂等待 */
				usleep(1000);
				continue;
			}
			/* 对端关闭或其他错误 */
			break;
		}
		if (n == 0)
			break; /* EOF */
		ssize_t w = splice(pipefd[0], NULL, nullfd, NULL, n, 0);
		if (w < 0)
			break;
		total += n;
	}
	close(pipefd[0]);
	close(pipefd[1]);
	close(nullfd);
	close(cfd);
	fprintf(stderr, "splice-server: spliced %zd bytes, exiting\n", total);
	return 0;
}

/* TCP server: TCP_ZEROCOPY_RECEIVE 接收，覆盖 tcp_zerocopy_receive RX 路径 */
static int do_zerocopy_server(int port)
{
	int lfd = socket(AF_INET, SOCK_STREAM, 0);
	if (lfd < 0) {
		perror("socket");
		return 1;
	}
	int yes = 1;
	setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	addr.sin_port = htons(port);
	if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		perror("bind");
		close(lfd);
		return 1;
	}
	if (listen(lfd, 1) < 0) {
		perror("listen");
		close(lfd);
		return 1;
	}

	fprintf(stderr, "zerocopy-server: listening on 127.0.0.1:%d pid=%d\n",
		port, getpid());
	fflush(stderr);

	int cfd = accept(lfd, NULL, NULL);
	if (cfd < 0) {
		perror("accept");
		close(lfd);
		return 1;
	}
	close(lfd);

	/*
	 * TCP_ZEROCOPY_RECEIVE 要求接收缓冲区是一块通过 mmap(cfd) 获得的、
	 * 绑定到该 socket 的 VMA（vm_ops == &tcp_vm_ops)。普通匿名 mmap
	 * 区域的 vm_ops 不匹配，find_tcp_vma() 会返回 NULL，导致 getsockopt
	 * 返回 EINVAL。
	 *
	 * tcp_mmap() 本身不真正映射页面，只是登记 VMA 并在后续
	 * tcp_zerocopy_receive() 中通过 vm_insert_page() 把 skb 页面插入。
	 * 参考：tools/testing/selftests/net/tcp_mmap.c
	 */
	long page_size = sysconf(_SC_PAGESIZE);
	if (page_size < 0) {
		perror("sysconf(_SC_PAGESIZE)");
		close(cfd);
		return 1;
	}
	size_t maplen = 1 << 20; /* 1 MiB，必须是 page_size 的倍数 */
	if (maplen % (size_t)page_size)
		maplen = (maplen + page_size - 1) & ~((size_t)page_size - 1);
	/* 必须用 MAP_SHARED：内核通过 vm_insert_page() 向 VMA 插入页面，
	 * MAP_PRIVATE 会触发 COW，导致映射失败或行为异常。 */
	void *raddr = mmap(NULL, maplen + page_size, PROT_READ,
			   MAP_SHARED, cfd, 0);
	if (raddr == MAP_FAILED) {
		perror("mmap(socket) for zerocopy");
		close(cfd);
		return 1;
	}
	/* mmap 返回页面对齐地址；多分配一页是为了后续按 page_size 向上对齐
	 * （尽管当前地址已对齐，保留与内核 selftest 相同的防御性写法）。 */
	void *area = (void *)(((unsigned long)raddr + page_size - 1) &
			      ~((unsigned long)page_size - 1));

	/* 接收时同样设置 TCP_MAXSEG，使对端按页面对齐的 payload 发送，
	 * 提高 skb 页面可直接映射的概率。 */
	int rcv_mss = page_size + 12; /* 12 = TCP timestamp option length */
	setsockopt(cfd, IPPROTO_TCP, TCP_MAXSEG, &rcv_mss, sizeof(rcv_mss));

	char *copybuf = malloc(page_size);
	if (!copybuf) {
		perror("malloc copybuf");
		munmap(raddr, maplen + page_size);
		close(cfd);
		return 1;
	}

	ssize_t total = 0;
	while (!g_stop) {
		struct pollfd pfd = { .fd = cfd, .events = POLLIN };
		int pr = poll(&pfd, 1, 1000);
		if (pr < 0) {
			if (errno == EINTR)
				continue;
			perror("poll");
			break;
		}

		struct tcp_zerocopy_receive zc;
		memset(&zc, 0, sizeof(zc));
		zc.address = (uint64_t)(uintptr_t)area;
		zc.length = maplen;
		/* TCP_ZEROCOPY_RECEIVE 通过 getsockopt 触发，调用 tcp_zerocopy_receive()
		 * 内核函数（本项目在此函数内有 rx_end 打点）。zc.address 必须指向通过
		 * mmap(cfd) 获得的 socket VMA，内核会把 skb 页面映射到该 VMA 中；
		 * 返回时 zc.length 更新为实际映射的字节数，recv_skip_hint 给出
		 * 因非页面对齐而无法映射的字节数（需用普通 read 消费）。
		 * 注意：这是 getsockopt（不是 setsockopt），optlen 是指针参数。 */
		socklen_t optlen = sizeof(zc);
		if (getsockopt(cfd, IPPROTO_TCP, TCP_ZEROCOPY_RECEIVE,
			       &zc, &optlen) < 0) {
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN || errno == ENOMEM) {
				usleep(1000);
				continue;
			}
			/* EIO 表示对端关闭且接收队列为空，正常 EOF */
			if (errno == EIO)
				break;
			/* EINVAL/EOPNOTSUPP/ENOPROTOOPT 等：内核不支持 zerocopy
			 * 或参数问题。打印 errno 便于诊断，并返回特定退出码 3
			 * 让 run-tests.sh 据此 SKIP 而非 FAIL */
			fprintf(stderr, "zerocopy-server: getsockopt failed: %s (errno=%d)\n",
				strerror(errno), errno);
			free(copybuf);
			munmap(raddr, maplen + page_size);
			close(cfd);
			return 3;
		}

		if (zc.length > 0) {
			total += zc.length;
			/* 释放已映射页面，避免下一轮映射冲突 */
			madvise(area, zc.length, MADV_DONTNEED);
		}

		/* 消费因非页面对齐而无法映射的数据，推进 copied_seq */
		if (zc.recv_skip_hint > 0) {
			size_t left = zc.recv_skip_hint;
			while (left > 0) {
				size_t chunk = left < (size_t)page_size ? left : (size_t)page_size;
				ssize_t n = read(cfd, copybuf, chunk);
				if (n <= 0)
					break;
				total += n;
				left -= n;
			}
		}

		/* length 和 recv_skip_hint 都为 0：可能是短暂无数据，继续 poll */
	}
	free(copybuf);
	munmap(raddr, maplen + page_size);
	close(cfd);
	fprintf(stderr, "zerocopy-server: received %zd bytes, exiting\n", total);
	return 0;
}

/* UDP corked 发送公共逻辑：提取自 do_corked_udp_client / do_corked_udp6_client，
 * 消除 v6.2.0 问题 2.1.3 的 ~90% 代码重复。
 * 封装 sendto 循环 + cork/uncork burst 逻辑 + 最终 flush。
 * 调用方负责创建 socket、设置 UDP_CORK、设置目标地址。
 * 策略：每 CORK_BURST 个包 uncork 一次触发 flush（udp_push_pending_frames /
 * udp_v6_push_pending_frames），再重新 cork。避免 cork 缓冲区累积超过 64K 导致 EMSGSIZE。 */
#define CORK_BURST 8
static int corked_send_loop(int s, struct sockaddr *addr, socklen_t addrlen,
			    int duration, const char *label)
{
	/* 1000 字节包，8 个包 = 8000 字节，远小于 64K cork 上限 */
	char buf[1000];
	memset(buf, 'x', sizeof(buf));

	fprintf(stderr, "%s: sending for %ds pid=%d\n", label, duration, getpid());
	fflush(stderr);

	ssize_t total = 0;
	int batch = 0;
	time_t end = time(NULL) + duration;
	while (!g_stop && time(NULL) < end) {
		ssize_t n = sendto(s, buf, sizeof(buf), 0, addr, addrlen);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			perror("sendto");
			break;
		}
		total += n;
		batch++;
		/* 每 CORK_BURST 个包 uncork 触发一次 flush，然后重新 cork。
		 * IPv4 触发 udp_push_pending_frames，IPv6 触发 udp_v6_push_pending_frames。 */
		if (batch >= CORK_BURST) {
			int no = 0;
			setsockopt(s, IPPROTO_UDP, UDP_CORK, &no, sizeof(no));
			usleep(500);
			int yes = 1;
			setsockopt(s, IPPROTO_UDP, UDP_CORK, &yes, sizeof(yes));
			batch = 0;
		}
	}
	/* 最终 uncork flush 剩余缓冲区 */
	int no = 0;
	setsockopt(s, IPPROTO_UDP, UDP_CORK, &no, sizeof(no));
	close(s);
	fprintf(stderr, "%s: sent %zd bytes, exiting\n", label, total);
	return 0;
}

/* UDP client: UDP_CORK 发送，覆盖 udp_push_pending_frames TX 路径。 */
static int do_corked_udp_client(const char *ip, int port, int duration)
{
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0) {
		perror("socket");
		return 1;
	}
	int yes = 1;
	if (setsockopt(s, IPPROTO_UDP, UDP_CORK, &yes, sizeof(yes)) < 0) {
		perror("setsockopt UDP_CORK");
		close(s);
		return 1;
	}

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(port);
	if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) {
		fprintf(stderr, "invalid ip: %s\n", ip);
		close(s);
		return 1;
	}

	return corked_send_loop(s, (struct sockaddr *)&addr, sizeof(addr),
				duration, "corked-udp-client");
}

/* UDPv6 client: UDP_CORK 发送，覆盖 udp_v6_push_pending_frames TX 路径。
 * 与 corked-udp-client 对应，但使用 AF_INET6 + ::1 loopback，
 * 触发 IPv6 协议栈的 udp_v6_push_pending_frames() 而非 IPv4 的 udp_push_pending_frames()。 */
static int do_corked_udp6_client(const char *ip, int port, int duration)
{
	int s = socket(AF_INET6, SOCK_DGRAM, 0);
	if (s < 0) {
		perror("socket(AF_INET6)");
		return 1;
	}
	/* 限制为 IPv6 only，避免 IPv4-mapped 地址走 IPv4 路径 */
	int v6only = 1;
	if (setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, sizeof(v6only)) < 0) {
		perror("setsockopt IPV6_V6ONLY");
		close(s);
		return 1;
	}
	int yes = 1;
	if (setsockopt(s, IPPROTO_UDP, UDP_CORK, &yes, sizeof(yes)) < 0) {
		perror("setsockopt UDP_CORK");
		close(s);
		return 1;
	}

	struct sockaddr_in6 addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin6_family = AF_INET6;
	addr.sin6_port = htons(port);
	if (inet_pton(AF_INET6, ip, &addr.sin6_addr) != 1) {
		fprintf(stderr, "invalid ipv6 address: %s\n", ip);
		close(s);
		return 1;
	}

	return corked_send_loop(s, (struct sockaddr *)&addr, sizeof(addr),
				duration, "corked-udp6-client");
}

/* TCP client: 持续发送数据，配合 splice-server / zerocopy-server 使用。
 * 保持连接直到 duration 结束或被信号终止，确保 server 有足够时间读取。 */
static int do_tcp_sender(const char *ip, int port, int duration)
{
	int s = socket(AF_INET, SOCK_STREAM, 0);
	if (s < 0) {
		perror("socket");
		return 1;
	}
	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(port);
	if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) {
		fprintf(stderr, "invalid ip: %s\n", ip);
		close(s);
		return 1;
	}
	/* 为配合 TCP_ZEROCOPY_RECEIVE，将 MSS 设为 page_size + TCP TS option，
	 * 使 payload 尽量按页面对齐，提高 skb 页面可直接映射的概率。
	 * 仅影响发送段大小，对 splice 测试无负面影响。 */
	long page_size = sysconf(_SC_PAGESIZE);
	if (page_size > 0) {
		int mss = page_size + 12; /* 12 = TCP timestamp option length */
		setsockopt(s, IPPROTO_TCP, TCP_MAXSEG, &mss, sizeof(mss));
	}

	if (connect(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		perror("connect");
		close(s);
		return 1;
	}

	char buf[4096];
	memset(buf, 'x', sizeof(buf));

	fprintf(stderr, "tcp-sender: connected to %s:%d, sending for %ds pid=%d\n",
		ip, port, duration, getpid());
	fflush(stderr);

	ssize_t total = 0;
	time_t end = time(NULL) + duration;
	while (!g_stop && time(NULL) < end) {
		ssize_t n = send(s, buf, sizeof(buf), 0);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			perror("send");
			break;
		}
		total += n;
		usleep(200);
	}
	close(s);
	fprintf(stderr, "tcp-sender: sent %zd bytes, exiting\n", total);
	return 0;
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"Usage:\n"
		"  %s splice-server <port>\n"
		"  %s zerocopy-server <port>\n"
		"  %s corked-udp-client <ip> <port> [duration_sec]\n"
		"  %s corked-udp6-client <ipv6> <port> [duration_sec]\n"
		"  %s tcp-sender <ip> <port> [duration_sec]\n",
		prog, prog, prog, prog, prog);
}

int main(int argc, char **argv)
{
	signal(SIGTERM, on_sigterm);
	signal(SIGINT, on_sigterm);

	if (argc < 3) {
		usage(argv[0]);
		return 2;
	}

	if (strcmp(argv[1], "splice-server") == 0) {
		return do_splice_server(atoi(argv[2]));
	} else if (strcmp(argv[1], "zerocopy-server") == 0) {
		return do_zerocopy_server(atoi(argv[2]));
	} else if (strcmp(argv[1], "corked-udp-client") == 0) {
		if (argc < 4) {
			usage(argv[0]);
			return 2;
		}
		int dur = (argc >= 5) ? atoi(argv[4]) : 6;
		return do_corked_udp_client(argv[2], atoi(argv[3]), dur);
	} else if (strcmp(argv[1], "corked-udp6-client") == 0) {
		if (argc < 4) {
			usage(argv[0]);
			return 2;
		}
		int dur = (argc >= 5) ? atoi(argv[4]) : 6;
		return do_corked_udp6_client(argv[2], atoi(argv[3]), dur);
	} else if (strcmp(argv[1], "tcp-sender") == 0) {
		if (argc < 4) {
			usage(argv[0]);
			return 2;
		}
		int dur = (argc >= 5) ? atoi(argv[4]) : 6;
		return do_tcp_sender(argv[2], atoi(argv[3]), dur);
	}

	usage(argv[0]);
	return 2;
}
