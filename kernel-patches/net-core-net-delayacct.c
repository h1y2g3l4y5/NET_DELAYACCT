// SPDX-License-Identifier: GPL-2.0-only
/* Copyright (c) 2026 laiguo-liang <2909269677@qq.com> */
/*
 * net/core/net-delayacct.c - Per-socket network delay accounting
 *
 * This module registers the "net_delayacct" generic netlink family and
 * implements three commands:
 *
 *   NET_DELAYACCT_CMD_GET_BY_PID   - return stats for every TCP/UDP
 *                                    socket held by the given PID
 *   NET_DELAYACCT_CMD_GET_BY_INODE - return stats for the socket
 *                                    identified by its inode number
 *   NET_DELAYACCT_CMD_RESET        - zero all per-socket statistics
 *
 * Multi-socket replies use NLM_F_MULTI followed by a final NLMSG_DONE,
 * one netlink message per socket (mirroring the dump style of
 * taskstats / sock_diag).
 *
 * Locking order:
 *   rcu_read_lock()
 *     -> task_lock(task)
 *       -> spin_lock(&files->file_lock)
 *         -> lock_sock(sk) / net_delayacct.lock
 *
 * All lookups are bounded and never block on user memory.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/spinlock.h>
#include <linux/sched.h>
#include <linux/sched/task.h>
#include <linux/pid.h>
#include <linux/rcupdate.h>
#include <linux/fdtable.h>
#include <linux/net.h>
#include <linux/socket.h>
#include <linux/inet.h>
#include <linux/in.h>
#include <linux/in6.h>
#include <linux/file.h>
#include <linux/fs.h>
#include <linux/proc_fs.h>
#include <net/sock.h>
#include <net/inet_sock.h>
#include <net/ipv6.h>
#include <net/net_namespace.h>
#include <net/genetlink.h>
#include <net/netlink.h>
#include <linux/net-delayacct.h>
#include <net/net-delayacct.h>

static const struct nla_policy
net_delayacct_policy[NET_DELAYACCT_A_MAX + 1] = {
	[NET_DELAYACCT_A_PID]		= { .type = NLA_U32 },
	[NET_DELAYACCT_A_INODE]		= { .type = NLA_U64 },
	[NET_DELAYACCT_A_TYPE]		= { .type = NLA_U8 },
	[NET_DELAYACCT_A_FAMILY]	= { .type = NLA_U8 },
	[NET_DELAYACCT_A_LPORT]		= { .type = NLA_U16 },
	[NET_DELAYACCT_A_RPORT]		= { .type = NLA_U16 },
	[NET_DELAYACCT_A_LADDR]		= NLA_POLICY_MIN_LEN(sizeof(__be32)),
	[NET_DELAYACCT_A_RADDR]		= NLA_POLICY_MIN_LEN(sizeof(__be32)),
};

/* Forward declarations */
static int net_delayacct_dump_start(struct netlink_callback *cb);
static int net_delayacct_dump_by_pid(struct sk_buff *skb,
				     struct netlink_callback *cb);
static int net_delayacct_dump_done(struct netlink_callback *cb);
static int net_delayacct_cmd_get_by_inode(struct sk_buff *skb,
					  struct genl_info *info);
static int net_delayacct_cmd_reset(struct sk_buff *skb,
				   struct genl_info *info);

static const struct genl_ops net_delayacct_ops[] = {
	{
		.cmd	= NET_DELAYACCT_CMD_GET_BY_PID,
		.start	= net_delayacct_dump_start,
		.dumpit	= net_delayacct_dump_by_pid,
		.done	= net_delayacct_dump_done,
		.flags	= GENL_ADMIN_PERM,
		.validate = GENL_DONT_VALIDATE_STRICT,
	},
	{
		.cmd	= NET_DELAYACCT_CMD_GET_BY_INODE,
		.doit	= net_delayacct_cmd_get_by_inode,
		.flags	= GENL_ADMIN_PERM,
		.validate = GENL_DONT_VALIDATE_STRICT,
	},
	{
		.cmd	= NET_DELAYACCT_CMD_RESET,
		.doit	= net_delayacct_cmd_reset,
		.flags	= GENL_ADMIN_PERM,
		.validate = GENL_DONT_VALIDATE_STRICT,
	},
};

static struct genl_family net_delayacct_genl_family = {
	.name		= "net_delayacct",
	.version	= 1,
	.maxattr	= NET_DELAYACCT_A_MAX,
	.netnsok	= true,
	.module		= THIS_MODULE,
	.ops		= net_delayacct_ops,
	.n_ops          = ARRAY_SIZE(net_delayacct_ops),
	.resv_start_op	= __NET_DELAYACCT_CMD_MAX,
	.policy		= net_delayacct_policy,
};

/**
 * net_delayacct_fill_sock - build one netlink reply for a socket
 * @skb:   reply skb (already initialised with genlmsg_put)
 * @sk:    target socket (caller must hold a reference)
 * @pid:   owning task PID (from the request)
 * @comm:  owning task comm (may be NULL)
 * @inode: socket inode number (0 if unknown)
 *
 * Returns 0 on success or a negative error code from nla_put_*.
 */
static int net_delayacct_fill_sock(struct sk_buff *skb, struct sock *sk,
				   u32 pid, const char *comm, u64 inode)
{
	struct net_delayacct_stats stats;
	u8 family, proto;
	u16 lport, rport;
	int addr_len;
	void *laddr, *raddr;

	/* Snapshot the stats under the per-socket spinlock. */
	net_delayacct_get_stats(sk, &stats);

	family = sk->sk_family;
	proto  = sk->sk_protocol;
	/* sk->sk_num is already in host byte order (__u16); sk->sk_dport
	 * is in network byte order (__be16) and needs ntohs().
	 */
	lport  = sk->sk_num;
	rport  = ntohs(sk->sk_dport);

	if (family == AF_INET) {
		struct inet_sock *inet = inet_sk(sk);

		addr_len = sizeof(__be32);
		laddr = &inet->inet_rcv_saddr;
		raddr = &inet->inet_daddr;
	} else if (family == AF_INET6) {
		addr_len = sizeof(struct in6_addr);
		laddr = &sk->sk_v6_rcv_saddr;
		raddr = &sk->sk_v6_daddr;
	} else {
		return -EAFNOSUPPORT;
	}

	if (nla_put_u8(skb, NET_DELAYACCT_A_TYPE, proto) ||
	    nla_put_u8(skb, NET_DELAYACCT_A_FAMILY, family) ||
	    nla_put(skb, NET_DELAYACCT_A_LADDR, addr_len, laddr) ||
	    nla_put_u16(skb, NET_DELAYACCT_A_LPORT, lport) ||
	    nla_put(skb, NET_DELAYACCT_A_RADDR, addr_len, raddr) ||
	    nla_put_u16(skb, NET_DELAYACCT_A_RPORT, rport) ||
	    nla_put_u64_64bit(skb, NET_DELAYACCT_A_RX_TOTAL_NS,
			      stats.rx_total_ns, 0) ||
	    nla_put_u64_64bit(skb, NET_DELAYACCT_A_RX_COUNT,
			      stats.rx_count, 0) ||
	    nla_put_u64_64bit(skb, NET_DELAYACCT_A_RX_MIN_NS,
			      stats.rx_min_ns, 0) ||
	    nla_put_u64_64bit(skb, NET_DELAYACCT_A_RX_MAX_NS,
			      stats.rx_max_ns, 0) ||
	    nla_put_u64_64bit(skb, NET_DELAYACCT_A_TX_TOTAL_NS,
			      stats.tx_total_ns, 0) ||
	    nla_put_u64_64bit(skb, NET_DELAYACCT_A_TX_COUNT,
			      stats.tx_count, 0) ||
	    nla_put_u64_64bit(skb, NET_DELAYACCT_A_TX_MIN_NS,
			      stats.tx_min_ns, 0) ||
	    nla_put_u64_64bit(skb, NET_DELAYACCT_A_TX_MAX_NS,
			      stats.tx_max_ns, 0) ||
	    nla_put_u64_64bit(skb, NET_DELAYACCT_A_INODE, inode, 0) ||
	    nla_put_u32(skb, NET_DELAYACCT_A_PID, pid))
		return -EMSGSIZE;

	if (comm)
		return nla_put_string(skb, NET_DELAYACCT_A_COMM, comm);
	return 0;
}

/**
 * sock_inode_for - get the inode number of a socket's backing file
 * @sk: target socket
 *
 * Returns the inode number, or 0 if not available.
 *
 * TODO: verify SOCKET_I() availability in 6.6; this fallback walks
 * sk_socket->file.
 */
static u64 sock_inode_for(struct sock *sk)
{
	struct socket *sock;
	struct file *file;

	sock = sk->sk_socket;
	if (!sock)
		return 0;
	file = sock->file;
	if (!file)
		return 0;
	return file_inode(file)->i_ino;
}

/**
 * is_inet_tcp_udp - filter to inet TCP/UDP sockets
 * @sk: target socket
 */
static bool is_inet_tcp_udp(struct sock *sk)
{
	if (!sk)
		return false;
	if (sk->sk_family != AF_INET && sk->sk_family != AF_INET6)
		return false;
	return sk->sk_protocol == IPPROTO_TCP ||
	       sk->sk_protocol == IPPROTO_UDP;
}

/**
 * net_delayacct_match_filter - check if a socket matches the request filter
 * @sk:   target socket (caller holds a reference)
 * @info: genl_info from the request (contains optional filter attributes)
 *
 * Returns true if the socket matches all specified filter criteria.
 * Unspecified (absent) attributes are treated as wildcards — match all.
 *
 * Filter attributes (all optional, reused from reply attributes per
 * the inet_diag convention):
 *   NET_DELAYACCT_A_TYPE   - u8 protocol (IPPROTO_TCP/IPPROTO_UDP)
 *   NET_DELAYACCT_A_FAMILY - u8 address family (AF_INET/AF_INET6)
 *   NET_DELAYACCT_A_LPORT  - u16 local port (host byte order)
 *   NET_DELAYACCT_A_RPORT  - u16 remote port (host byte order)
 *   NET_DELAYACCT_A_LADDR  - binary local address (network byte order)
 *   NET_DELAYACCT_A_RADDR  - binary remote address (network byte order)
 *
 * For address attributes, the length determines the comparison width:
 * sizeof(__be32) for IPv4, sizeof(struct in6_addr) for IPv6.  A mismatch
 * between the filter address length and the socket family causes a
 * non-match (the socket is skipped).
 */
static bool net_delayacct_match_filter(struct sock *sk,
				       const struct genl_info *info)
{
	if (info->attrs[NET_DELAYACCT_A_TYPE]) {
		u8 proto = nla_get_u8(info->attrs[NET_DELAYACCT_A_TYPE]);
		if (sk->sk_protocol != proto)
			return false;
	}

	if (info->attrs[NET_DELAYACCT_A_FAMILY]) {
		u8 family = nla_get_u8(info->attrs[NET_DELAYACCT_A_FAMILY]);
		if (sk->sk_family != family)
			return false;
	}

	if (info->attrs[NET_DELAYACCT_A_LPORT]) {
		u16 lport = nla_get_u16(info->attrs[NET_DELAYACCT_A_LPORT]);
		/* sk->sk_num is already in host byte order (__u16). */
		if (sk->sk_num != lport)
			return false;
	}

	if (info->attrs[NET_DELAYACCT_A_RPORT]) {
		u16 rport = nla_get_u16(info->attrs[NET_DELAYACCT_A_RPORT]);
		/* sk->sk_dport is in network byte order (__be16). */
		if (ntohs(sk->sk_dport) != rport)
			return false;
	}

	if (info->attrs[NET_DELAYACCT_A_LADDR]) {
		int attr_len = nla_len(info->attrs[NET_DELAYACCT_A_LADDR]);

		if (sk->sk_family == AF_INET) {
			struct inet_sock *inet = inet_sk(sk);

			if (attr_len != sizeof(__be32))
				return false;
			if (inet->inet_rcv_saddr !=
			    nla_get_be32(info->attrs[NET_DELAYACCT_A_LADDR]))
				return false;
		} else if (sk->sk_family == AF_INET6) {
			if (attr_len != sizeof(struct in6_addr))
				return false;
			if (memcmp(&sk->sk_v6_rcv_saddr,
				   nla_data(info->attrs[NET_DELAYACCT_A_LADDR]),
				   sizeof(struct in6_addr)) != 0)
				return false;
		} else {
			return false;
		}
	}

	if (info->attrs[NET_DELAYACCT_A_RADDR]) {
		int attr_len = nla_len(info->attrs[NET_DELAYACCT_A_RADDR]);

		if (sk->sk_family == AF_INET) {
			struct inet_sock *inet = inet_sk(sk);

			if (attr_len != sizeof(__be32))
				return false;
			if (inet->inet_daddr !=
			    nla_get_be32(info->attrs[NET_DELAYACCT_A_RADDR]))
				return false;
		} else if (sk->sk_family == AF_INET6) {
			if (attr_len != sizeof(struct in6_addr))
				return false;
			if (memcmp(&sk->sk_v6_daddr,
				   nla_data(info->attrs[NET_DELAYACCT_A_RADDR]),
				   sizeof(struct in6_addr)) != 0)
				return false;
		} else {
			return false;
		}
	}

	return true;
}

/*
 * Resolve a &struct file to a &struct sock via sock_from_file().
 *
 * sock_from_file() is available since 5.15+ and is the canonical
 * helper.  It returns a &struct socket, so we extract ->sk.
 */
static struct sock *sock_from_file_safe(struct file *file)
{
	struct socket *sock = sock_from_file(file);

	return sock ? sock->sk : NULL;
}

/**
 * net_delayacct_one_reply - emit one netlink reply for a single socket
 * @info:   genl_info from the request
 * @flags:  NLM_F_MULTI for multipart, 0 for the last
 * @sk:     target socket
 * @pid:    owning PID
 * @comm:   owning comm
 * @inode:  socket inode
 *
 * Used by GET_BY_INODE (doit handler) to send a single reply.
 * GET_BY_PID now uses the standard dumpit path instead.
 *
 * Returns 0 on success, negative error otherwise.
 */
static int net_delayacct_one_reply(struct genl_info *info, int flags,
				   struct sock *sk, u32 pid,
				   const char *comm, u64 inode)
{
	struct sk_buff *msg;
	void *hdr;
	int ret;

	msg = genlmsg_new(NLMSG_DEFAULT_SIZE, GFP_KERNEL);
	if (!msg)
		return -ENOMEM;

	hdr = genlmsg_put_reply(msg, info, &net_delayacct_genl_family,
				flags, info->genlhdr->cmd);
	if (!hdr) {
		nlmsg_free(msg);
		return -EMSGSIZE;
	}

	ret = net_delayacct_fill_sock(msg, sk, pid, comm, inode);
	if (ret) {
		genlmsg_cancel(msg, hdr);
		nlmsg_free(msg);
		return ret;
	}
	genlmsg_end(msg, hdr);

	return genlmsg_reply(msg, info);
}

/**
 * struct net_delayacct_dump_ctx - per-dump iteration state
 *
 * Stored inside the netlink_callback ctx[48] inline buffer (not a
 * heap allocation).  Total size is 40 bytes, which fits within the
 * 48-byte cb->ctx area.
 *
 * @task:  task_struct reference held via get_task_struct()
 * @files: files_struct reference held via atomic_inc(&files->count)
 * @fd:    next fd index to scan
 * @pid:   PID of the target task (for the reply)
 * @comm:  task comm snapshot (safe copy, no locking needed after start)
 */
struct net_delayacct_dump_ctx {
	struct task_struct	*task;
	struct files_struct	*files;
	unsigned int		fd;
	u32			pid;
	char			comm[TASK_COMM_LEN];
};

/**
 * net_delayacct_dump_start - .start callback for GET_BY_PID dump
 * @cb: netlink callback
 *
 * Resolves the requested PID, performs netns isolation check, and
 * captures task_struct/files_struct references for the duration of
 * the dump.  The state is stored in cb->ctx (inline, not heap).
 *
 * Returns 0 on success or a negative errno.
 */
static int net_delayacct_dump_start(struct netlink_callback *cb)
{
	const struct genl_info *info = genl_info_dump(cb);
	struct net_delayacct_dump_ctx *ctx =
		(struct net_delayacct_dump_ctx *)cb->ctx;
	struct pid *pidp;
	struct task_struct *task;
	struct files_struct *files;
	u32 pid;

	/* Defensive: __netlink_dump_start() currently zeroes cb, but we
	 * must not depend on that — .done() checks ctx->files/task for
	 * NULL to decide whether to release references.  Clear ctx up
	 * front so every early error-return path is safe.
	 */
	memset(ctx, 0, sizeof(*ctx));

	if (!info->attrs[NET_DELAYACCT_A_PID])
		return -EINVAL;

	pid = nla_get_u32(info->attrs[NET_DELAYACCT_A_PID]);

	rcu_read_lock();
	pidp = find_vpid(pid);
	if (!pidp) {
		rcu_read_unlock();
		return -ESRCH;
	}
	task = pid_task(pidp, PIDTYPE_PID);
	if (!task) {
		rcu_read_unlock();
		return -ESRCH;
	}

	/* netns consistency: when netnsok=true, ensure the resolved task
	 * lives in the caller's network namespace (see issue 2.2.1).
	 */
	if (task->nsproxy &&
	    task->nsproxy->net_ns != current->nsproxy->net_ns) {
		rcu_read_unlock();
		return -ESRCH;
	}

	get_task_struct(task);
	rcu_read_unlock();

	/* Acquire files_struct reference.  get_task_files() is not
	 * exported in 6.6, so we use task_lock + atomic_inc.
	 */
	task_lock(task);
	files = task->files;
	if (files)
		atomic_inc(&files->count);
	task_unlock(task);

	if (!files) {
		put_task_struct(task);
		return -ESRCH;
	}

	ctx->task = task;
	ctx->files = files;
	ctx->pid = pid;
	get_task_comm(ctx->comm, task);
	return 0;
}

/**
 * net_delayacct_dump_by_pid - .dumpit callback for GET_BY_PID
 * @skb: skb to fill with one socket's reply
 * @cb:  netlink callback (cb->ctx holds iteration state)
 *
 * Each invocation fills at most one socket into @skb.  The Generic
 * Netlink framework handles NLM_F_MULTI, message fragmentation, and
 * NLMSG_DONE automatically.
 *
 * Returns skb->len (>0) if data was added, 0 when the dump is done.
 */
static int net_delayacct_dump_by_pid(struct sk_buff *skb,
				     struct netlink_callback *cb)
{
	struct net_delayacct_dump_ctx *ctx =
		(struct net_delayacct_dump_ctx *)cb->ctx;
	struct files_struct *files = ctx->files;
	unsigned int fd = ctx->fd;
	const struct genl_info *info = genl_info_dump(cb);
	struct fdtable *fdt;
	void *hdr;
	int ret;

	if (!files)
		return 0;

	spin_lock(&files->file_lock);
	fdt = files_fdtable(files);

	while (fd < fdt->max_fds) {
		struct file *file = fdt->fd[fd];
		struct sock *sk;

		if (!file) {
			fd++;
			continue;
		}
		sk = sock_from_file_safe(file);
		if (!sk || !is_inet_tcp_udp(sk)) {
			fd++;
			continue;
		}

		/* Apply optional request filters (proto/family/port/addr).
		 * Sockets that do not match are skipped silently.
		 */
		if (!net_delayacct_match_filter(sk, info)) {
			fd++;
			continue;
		}

		/* Hold references while we drop file_lock to fill skb.
		 * lock_sock() inside net_delayacct_get_stats() may
		 * sleep, so we cannot hold file_lock (spinlock).
		 */
		get_file(file);
		sock_hold(sk);
		spin_unlock(&files->file_lock);

		hdr = genlmsg_put(skb, NETLINK_CB(cb->skb).portid,
				  cb->nlh->nlmsg_seq, &net_delayacct_genl_family,
				  NLM_F_MULTI, NET_DELAYACCT_CMD_GET_BY_PID);
		if (!hdr) {
			sock_put(sk);
			fput(file);
			ctx->fd = fd;
			return skb->len;
		}

		ret = net_delayacct_fill_sock(skb, sk, ctx->pid, ctx->comm,
					      sock_inode_for(sk));
		if (ret < 0) {
			genlmsg_cancel(skb, hdr);
			sock_put(sk);
			fput(file);
			ctx->fd = fd;
			return skb->len;
		}

		genlmsg_end(skb, hdr);
		sock_put(sk);
		fput(file);

		ctx->fd = fd + 1;
		return skb->len;
	}
	spin_unlock(&files->file_lock);

	/* No more sockets to dump.  Return 0 (not skb->len) to signal
	 * dump completion immediately — the skb here is empty, so the
	 * framework will not send it and will proceed to NLMSG_DONE.
	 */
	return 0;
}

/**
 * net_delayacct_dump_done - .done callback for GET_BY_PID dump
 * @cb: netlink callback
 *
 * Releases the task_struct and files_struct references acquired in
 * .start.  Must handle ctx == NULL / zeroed (in case .start failed
 * after partial initialization).
 */
static int net_delayacct_dump_done(struct netlink_callback *cb)
{
	struct net_delayacct_dump_ctx *ctx =
		(struct net_delayacct_dump_ctx *)cb->ctx;

	if (ctx->files)
		put_files_struct(ctx->files);
	if (ctx->task)
		put_task_struct(ctx->task);
	memset(ctx, 0, sizeof(*ctx));
	return 0;
}

static int net_delayacct_cmd_get_by_inode(struct sk_buff *skb,
					  struct genl_info *info)
{
	u64 target_inode;
	struct task_struct *task;
	char comm[TASK_COMM_LEN];
	int sock_count = 0;
	int match_count = 0;

	if (!info->attrs[NET_DELAYACCT_A_INODE])
		return -EINVAL;
	target_inode = nla_get_u64(info->attrs[NET_DELAYACCT_A_INODE]);

	rcu_read_lock();
	for_each_process(task) {
		struct files_struct *files;
		struct fdtable *fdt;
		unsigned int fd;
		int ret;

		/* netns isolation: skip tasks outside the caller's
		 * network namespace (see issue 2.2.1).  Kernel threads
		 * have nsproxy == NULL and should also be skipped.
		 */
		if (!task->nsproxy ||
		    task->nsproxy->net_ns != current->nsproxy->net_ns)
			continue;

		task_lock(task);
		files = task->files;
		memcpy(comm, task->comm, TASK_COMM_LEN);
		if (files)
			atomic_inc(&files->count);
		task_unlock(task);
		if (!files)
			continue;

		spin_lock(&files->file_lock);
		fdt = files_fdtable(files);
		for (fd = 0; fd < fdt->max_fds; fd++) {
			struct file *file = fdt->fd[fd];
			struct sock *sk;
			u64 ino;

			if (!file)
				continue;
			sk = sock_from_file_safe(file);
			if (!sk)
				continue;
			if (!is_inet_tcp_udp(sk))
				continue;
			sock_count++;
			ino = file_inode(file)->i_ino;
			if (ino != target_inode)
				continue;
			match_count++;

			/* Grab references and exit RCU before the
			 * netlink reply which may sleep (GFP_KERNEL
			 * allocation inside genlmsg_new — see issues
			 * 2.1.1 and 2.1.2).  comm was already copied
			 * under task_lock above (see issue 2.1.6).
			 */
			get_file(file);
			sock_hold(sk);
			get_task_struct(task);

			spin_unlock(&files->file_lock);
			rcu_read_unlock();

			ret = net_delayacct_one_reply(info, 0, sk,
						      task_pid_nr(task),
						      comm, ino);
			sock_put(sk);
			fput(file);
			put_task_struct(task);
			put_files_struct(files);
			return ret;
		}
		spin_unlock(&files->file_lock);
		put_files_struct(files);
	}
	rcu_read_unlock();

	return -ENOENT;
}

static int net_delayacct_cmd_reset(struct sk_buff *skb,
				   struct genl_info *info)
{
	struct task_struct *task;

	rcu_read_lock();
	for_each_process(task) {
		struct files_struct *files;
		struct fdtable *fdt;
		unsigned int fd;

		/* netns isolation: skip tasks outside the caller's
		 * network namespace (see issue 2.2.1).
		 */
		if (!task->nsproxy ||
		    task->nsproxy->net_ns != current->nsproxy->net_ns)
			continue;

		task_lock(task);
		files = task->files;
		if (files)
			atomic_inc(&files->count);
		task_unlock(task);
		if (!files)
			continue;

		spin_lock(&files->file_lock);
		fdt = files_fdtable(files);
		for (fd = 0; fd < fdt->max_fds; fd++) {
			struct file *file = fdt->fd[fd];
			struct sock *sk;

			if (!file)
				continue;
			sk = sock_from_file_safe(file);
			if (!is_inet_tcp_udp(sk))
				continue;
			sock_hold(sk);
			spin_unlock(&files->file_lock);

			net_delayacct_reset(sk);
			sock_put(sk);

			spin_lock(&files->file_lock);
			fdt = files_fdtable(files);
		}
		spin_unlock(&files->file_lock);
		put_files_struct(files);
	}
	rcu_read_unlock();

	/* Send a simple reply so the userspace tool doesn't block on
	 * recvfrom forever.  genl doit handlers must explicitly send a
	 * reply; returning 0 alone does not generate one. */
	{
		struct sk_buff *msg;
		void *hdr;

		msg = genlmsg_new(NLMSG_DEFAULT_SIZE, GFP_KERNEL);
		if (!msg)
			return -ENOMEM;
		hdr = genlmsg_put_reply(msg, info, &net_delayacct_genl_family,
					0, info->genlhdr->cmd);
		if (!hdr) {
			nlmsg_free(msg);
			return -EMSGSIZE;
		}
		genlmsg_end(msg, hdr);
		return genlmsg_reply(msg, info);
	}
}

/*
 * Out-of-line implementations of the helpers that touch
 * sk->sk_net_delayacct or sk->sk_refcnt.  They cannot live in the
 * header because it is included from include/net/sock.h before
 * struct sock is fully defined.
 */
void net_delayacct_rx_end(struct sock *sk, struct sk_buff *skb)
{
	struct net_delayacct *n;
	u64 start = skb->delayacct_start;
	u64 delta;

	if (!start)
		return;

	delta = ktime_get_ns() - start;
	skb->delayacct_start = 0;

	n = &sk->sk_net_delayacct;
	spin_lock_bh(&n->lock);
	if (n->stats.rx_total_ns > U64_MAX - delta)
		pr_warn_once("net_delayacct: RX total_ns overflow on socket %p\n", sk);
	n->stats.rx_total_ns += delta;
	n->stats.rx_count++;
	if (delta < n->stats.rx_min_ns)
		n->stats.rx_min_ns = delta;
	if (delta > n->stats.rx_max_ns)
		n->stats.rx_max_ns = delta;
	spin_unlock_bh(&n->lock);
}

void net_delayacct_tx_start(struct sock *sk, struct sk_buff *skb)
{
	skb->delayacct_start = ktime_get_ns();
	/*
	 * Note on skb->sk lifetime: we intentionally do NOT call
	 * sock_hold(sk) here.  The skb is owned by the originating
	 * socket via skb->destructor (sock_wfree for TCP/UDP), which
	 * keeps sk->sk_wmem_alloc > 0 and thereby prevents the socket
	 * from being freed while the skb is in flight.  Adding an
	 * extra sock_hold() here would break refcount accounting
	 * under GSO: skb_segment() splits the parent skb into N
	 * segments via __alloc_skb + __copy_skb_header().  Because
	 * delayacct_start lives inside the sk_buff headers group
	 * (see skbuff_h-modification.patch), __copy_skb_header
	 * automatically copies it to every child segment.  skb->sk
	 * is also inherited, but only the parent ever called
	 * sock_hold().  The N sock_put() calls in tx_end would
	 * then over-decrement sk_refcnt and trigger premature
	 * socket free + NULL deref in __sk_destruct
	 * (see issue 2.2.3 dialogue).
	 */
}

void net_delayacct_tx_end(struct sock *sk, struct sk_buff *skb)
{
	struct net_delayacct *n;
	u64 start = skb->delayacct_start;
	u64 delta;

	if (!start || !sk)
		return;

	delta = ktime_get_ns() - start;
	skb->delayacct_start = 0;

	n = &sk->sk_net_delayacct;
	spin_lock_bh(&n->lock);
	if (n->stats.tx_total_ns > U64_MAX - delta)
		pr_warn_once("net_delayacct: TX total_ns overflow on socket %p\n", sk);
	n->stats.tx_total_ns += delta;
	n->stats.tx_count++;
	if (delta < n->stats.tx_min_ns)
		n->stats.tx_min_ns = delta;
	if (delta > n->stats.tx_max_ns)
		n->stats.tx_max_ns = delta;
	spin_unlock_bh(&n->lock);

	/* No sock_put() here: see the note in net_delayacct_tx_start().
	 * skb->sk lifetime is managed by skb->destructor (sock_wfree),
	 * which the originating socket set when it owned the skb.
	 */
}

void net_delayacct_get_stats(struct sock *sk,
			     struct net_delayacct_stats *out)
{
	struct net_delayacct *n = &sk->sk_net_delayacct;

	spin_lock_bh(&n->lock);
	*out = n->stats;
	spin_unlock_bh(&n->lock);
}

void net_delayacct_reset(struct sock *sk)
{
	struct net_delayacct *n = &sk->sk_net_delayacct;

	spin_lock_bh(&n->lock);
	memset(&n->stats, 0, sizeof(n->stats));
	/* min_ns must be U64_MAX so that the first sample is always smaller;
	 * max_ns starts at 0 so the first sample is always larger.
	 */
	n->stats.rx_min_ns = U64_MAX;
	n->stats.tx_min_ns = U64_MAX;
	spin_unlock_bh(&n->lock);
}

static int __init net_delayacct_mod_init(void)
{
	int ret;

	ret = genl_register_family(&net_delayacct_genl_family);
	if (ret) {
		pr_err("net_delayacct: failed to register genl family: %d\n",
		       ret);
		return ret;
	}
	pr_info("net_delayacct: framework registered v2 (family=%u)\n",
		net_delayacct_genl_family.id);
	return 0;
}

static void __exit net_delayacct_exit(void)
{
	genl_unregister_family(&net_delayacct_genl_family);
	pr_info("net_delayacct: framework unregistered\n");
}

module_init(net_delayacct_mod_init);
module_exit(net_delayacct_exit);

MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("Per-socket network delay accounting");
MODULE_AUTHOR("laiguo-liang <2909269677@qq.com>");
