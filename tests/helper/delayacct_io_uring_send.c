// SPDX-License-Identifier: GPL-2.0-only
/*
 * delayacct_io_uring_send.c — io_uring send 路径覆盖测试辅助程序
 *
 * _GNU_SOURCE 通过 Makefile CFLAGS 定义。
 */

#include <arpa/inet.h>
#include <errno.h>
#include <linux/io_uring.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

/* io_uring syscall wrappers (不依赖 liburing) */
static int io_uring_setup(unsigned int entries, struct io_uring_params *p)
{
	return (int)syscall(__NR_io_uring_setup, entries, p);
}

static int io_uring_enter(int ring_fd, unsigned int to_submit,
			   unsigned int min_complete, unsigned int flags)
{
	return (int)syscall(__NR_io_uring_enter, ring_fd, to_submit,
			    min_complete, flags, NULL, 0);
}

/* io_uring SQ 环形缓冲区的简单内存布局。
 * 参考 liburing 的 io_uring_sq 结构，offset 在 io_uring_params 中由内核填充。
 * 这里仅使用单次提交/等待模式，无需复杂的事件循环，因此手动维护指针即可。 */

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "Usage: %s <dst_ip> <dst_port> [duration_sec]\n",
			argv[0]);
		return 2;
	}

	const char *dst_ip = argv[1];
	int dst_port = atoi(argv[2]);
	int duration = (argc >= 4) ? atoi(argv[3]) : 4;

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);

	/* 创建 TCP socket */
	int sock = socket(AF_INET, SOCK_STREAM, 0);
	if (sock < 0) {
		perror("socket");
		return 1;
	}

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((uint16_t)dst_port);
	if (inet_pton(AF_INET, dst_ip, &addr.sin_addr) != 1) {
		fprintf(stderr, "invalid ip: %s\n", dst_ip);
		close(sock);
		return 1;
	}

	if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		perror("connect");
		close(sock);
		return 1;
	}

	/* --- 初始化 io_uring --- */
	struct io_uring_params params;
	memset(&params, 0, sizeof(params));

	int ring_fd = io_uring_setup(8, &params);
	if (ring_fd < 0) {
		/* io_uring 不可用（老内核或未启用 CONFIG_IO_URING） */
		fprintf(stderr, "io_uring_setup failed: %s (errno=%d) — io_uring not available\n",
			strerror(-ring_fd), -ring_fd);
		close(sock);
		return 2; /* 退出码 2 → 外部 SKIP */
	}

	/* 映射 SQ 和 CQ */
	unsigned int sq_ring_sz = params.sq_off.array +
				 params.sq_entries * sizeof(unsigned int);
	unsigned int cq_ring_sz = params.cq_off.cqes +
				 params.cq_entries * sizeof(struct io_uring_cqe);

	void *sq_ptr = mmap(NULL, sq_ring_sz, PROT_READ | PROT_WRITE,
			    MAP_SHARED | MAP_POPULATE, ring_fd,
			    IORING_OFF_SQ_RING);
	void *cq_ptr = mmap(NULL, cq_ring_sz, PROT_READ | PROT_WRITE,
			    MAP_SHARED | MAP_POPULATE, ring_fd,
			    IORING_OFF_CQ_RING);

	/* 映射 SQ entries (SQE array) */
	unsigned int sqe_size = params.sq_entries * sizeof(struct io_uring_sqe);
	void *sqe_ptr = mmap(NULL, sqe_size, PROT_READ | PROT_WRITE,
			     MAP_SHARED | MAP_POPULATE, ring_fd,
			     IORING_OFF_SQES);

	if (sq_ptr == MAP_FAILED || cq_ptr == MAP_FAILED ||
	    sqe_ptr == MAP_FAILED) {
		perror("mmap io_uring");
		close(sock);
		close(ring_fd);
		return 2;
	}

	/* 获取 ring 指针 */
	unsigned int *sq_tail = (unsigned int *)((char *)sq_ptr + params.sq_off.tail);
	unsigned int *sq_mask = (unsigned int *)((char *)sq_ptr + params.sq_off.ring_mask);
	unsigned int *sq_array = (unsigned int *)((char *)sq_ptr + params.sq_off.array);

	unsigned int *cq_head = (unsigned int *)((char *)cq_ptr + params.cq_off.head);
	unsigned int *cq_tail = (unsigned int *)((char *)cq_ptr + params.cq_off.tail);
	unsigned int *cq_mask = (unsigned int *)((char *)cq_ptr + params.cq_off.ring_mask);
	struct io_uring_cqe *cqes = (struct io_uring_cqe *)((char *)cq_ptr +
				      params.cq_off.cqes);

	struct io_uring_sqe *sqes = (struct io_uring_sqe *)sqe_ptr;

	char buf[1024];
	memset(buf, 'X', sizeof(buf));

	fprintf(stderr,
		"io_uring_send: connected to %s:%d, sending for %ds pid=%d\n",
		dst_ip, dst_port, duration, getpid());
	fflush(stderr);

	ssize_t total = 0;
	time_t end = time(NULL) + duration;

	while (!g_stop && time(NULL) < end) {
		unsigned int tail = __atomic_load_n(sq_tail, __ATOMIC_ACQUIRE);
		unsigned int idx = tail & (*sq_mask);

		/* 填充 SQE */
		struct io_uring_sqe *sqe = &sqes[idx];
		memset(sqe, 0, sizeof(*sqe));
		sqe->opcode = IORING_OP_SEND;
		sqe->fd = sock;
		sqe->addr = (uint64_t)(uintptr_t)buf;
		sqe->len = sizeof(buf);
		sqe->off = 0; /* flags */

		sq_array[idx] = idx;
		__atomic_store_n(sq_tail, tail + 1, __ATOMIC_RELEASE);

		/* 提交 */
		int ret = io_uring_enter(ring_fd, 1, 1, IORING_ENTER_GETEVENTS);
		if (ret < 0) {
			if (ret == -EINTR)
				continue;
			fprintf(stderr, "io_uring_enter failed: %s\n",
				strerror(-ret));
			break;
		}

		/* 读取 CQE */
		unsigned int cq_tail_val = __atomic_load_n(cq_tail, __ATOMIC_ACQUIRE);
		unsigned int cq_head_val = __atomic_load_n(cq_head, __ATOMIC_ACQUIRE);

		if (cq_head_val != cq_tail_val) {
			struct io_uring_cqe *cqe = &cqes[cq_head_val & (*cq_mask)];
			if (cqe->res >= 0) {
				total += cqe->res;
			} else if (cqe->res == -EINTR) {
				/* retry */
			} else if (cqe->res == -ECONNRESET ||
				 cqe->res == -EPIPE) {
				fprintf(stderr,
					"connection closed by peer (%s)\n",
					strerror(-cqe->res));
				break;
			} else {
				fprintf(stderr, "send error: %s\n",
					strerror(-cqe->res));
				break;
			}
			__atomic_store_n(cq_head, cq_head_val + 1,
					 __ATOMIC_RELEASE);
		}

		usleep(1000); /* 1ms 间隔，避免 QEMU 环境下发送过快 */
	}

	munmap(sq_ptr, sq_ring_sz);
	munmap(cq_ptr, cq_ring_sz);
	munmap(sqe_ptr, sqe_size);
	close(ring_fd);
	close(sock);

	fprintf(stderr, "io_uring_send: sent %zd bytes, exiting\n", total);
	return 0;
}
