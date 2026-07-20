// SPDX-License-Identifier: GPL-2.0-only
/* Copyright (c) 2026 h1y2g3l4y5 */
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
};

/* Forward declarations */
static int net_delayacct_cmd_get_by_pid(struct sk_buff *skb,
					struct genl_info *info);
static int net_delayacct_cmd_get_by_inode(struct sk_buff *skb,
					  struct genl_info *info);
static int net_delayacct_cmd_reset(struct sk_buff *skb,
				   struct genl_info *info);

static const struct genl_ops net_delayacct_ops[] = {
	{
		.cmd	= NET_DELAYACCT_CMD_GET_BY_PID,
		.doit	= net_delayacct_cmd_get_by_pid,
		.flags	= GENL_ADMIN_PERM,
	},
	{
		.cmd	= NET_DELAYACCT_CMD_GET_BY_INODE,
		.doit	= net_delayacct_cmd_get_by_inode,
		.flags	= GENL_ADMIN_PERM,
	},
	{
		.cmd	= NET_DELAYACCT_CMD_RESET,
		.doit	= net_delayacct_cmd_reset,
		.flags	= GENL_ADMIN_PERM,
	},
};

static struct genl_family net_delayacct_genl_family __ro_after_init = {
	.name		= "net_delayacct",
	.version	= 1,
	.maxattr	= NET_DELAYACCT_A_MAX,
	.netnsok	= true,
	.module		= THIS_MODULE,
	.ops		= net_delayacct_ops,
	.n_ops          = ARRAY_SIZE(net_delayacct_ops),
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
	lport  = ntohs(sk->sk_num);
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
	    nla_put_u64_64bit(skb, NET_DELAYACCT_A_TX_TOTAL_NS,
			      stats.tx_total_ns, 0) ||
	    nla_put_u64_64bit(skb, NET_DELAYACCT_A_TX_COUNT,
			      stats.tx_count, 0) ||
	    nla_put_u64_64bit(skb, NET_DELAYACCT_A_INODE, inode, 0) ||
	    nla_put_u32(skb, NET_DELAYACCT_A_PID, pid))
		return -EMSGSIZE;

	if (comm)
		return nla_put_string(skb, NET_DELAYACCT_A_COMM, comm);
	return 0;
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
 * net_delayacct_emit_done - send the NLMSG_DONE terminator for a dump
 * @info: genl_info from the request
 */
static int net_delayacct_emit_done(struct genl_info *info)
{
	struct sk_buff *msg;

	msg = nlmsg_new(NLMSG_GOODSIZE, GFP_KERNEL);
	if (!msg)
		return -ENOMEM;

	nlmsg_put(msg, info->snd_portid, info->snd_seq, NLMSG_DONE,
		  0, NLM_F_MULTI);
	return genlmsg_reply(msg, info);
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
 * sock_from_file_safe - resolve a &struct file to a &struct sock
 * @file: file pointer (must be S_IFSOCK)
 *
 * TODO: sock_from_file() is available on recent kernels; on 6.6 we
 * fall back to SOCKET_I(file_inode(file))->sk which is always
 * available via <net/sock.h>.
 */
static struct sock *sock_from_file_safe(struct file *file)
{
	struct inode *inode;
	struct socket *sock;

	if (!file)
		return NULL;
	inode = file_inode(file);
	if (!S_ISSOCK(inode->i_mode))
		return NULL;

	sock = SOCKET_I(inode);
	if (!sock) {
		pr_info_ratelimited("net_delayacct: sock_from_file_safe: SOCKET_I returned NULL for inode %lu\n",
				    inode->i_ino);
		return NULL;
	}
	if (!sock->sk) {
		pr_info_ratelimited("net_delayacct: sock_from_file_safe: sock->sk is NULL for inode %lu\n",
				    inode->i_ino);
		return NULL;
	}
	return sock->sk;
}

/* Iterate every socket fd of @task and emit a reply for each
 * TCP/UDP inet socket.  Returns 0 on success or a negative errno.
 * Caller must NOT hold task_lock or files_lock (this function takes
 * them internally).
 */
static int net_delayacct_iter_task_sockets(struct task_struct *task,
					   struct genl_info *info,
					   bool emit_done)
{
	struct files_struct *files;
	struct fdtable *fdt;
	const char *comm;
	u32 pid;
	unsigned int fd;
	int ret = 0;
	int emitted = 0;

	pid = task_pid_nr(task);
	comm = NULL;	/* task->comm is only safe under task_lock */

	task_lock(task);
	comm = task->comm;
	files = task->files;
	if (files)
		atomic_inc(&files->count);
	task_unlock(task);

	if (!files)
		goto out;

	spin_lock(&files->file_lock);
	fdt = files_fdtable(files);
	pr_info("net_delayacct: iter_task_sockets pid=%u max_fds=%u\n",
		pid, fdt->max_fds);
	for (fd = 0; fd < fdt->max_fds; fd++) {
		struct file *file = fdt->fd[fd];
		struct sock *sk;

		if (!file)
			continue;
		sk = sock_from_file_safe(file);
		if (!sk)
			continue;
		if (!is_inet_tcp_udp(sk)) {
			pr_info("net_delayacct: iter fd=%u inode=%llu family=%u proto=%u SKIPPED\n",
				fd, (unsigned long long)sock_inode_for(sk),
				sk->sk_family, sk->sk_protocol);
			continue;
		}

		pr_info("net_delayacct: iter fd=%u inode=%llu family=%u proto=%u FOUND\n",
			fd, (unsigned long long)sock_inode_for(sk),
			sk->sk_family, sk->sk_protocol);

		/* Hold a reference while we drop file_lock to send. */
		get_file(file);
		sock_hold(sk);
		spin_unlock(&files->file_lock);

		ret = net_delayacct_one_reply(info, NLM_F_MULTI, sk,
					      pid, comm,
					      sock_inode_for(sk));
		sock_put(sk);
		fput(file);
		if (ret)
			goto out_files;
		emitted++;

		spin_lock(&files->file_lock);
		fdt = files_fdtable(files);
	}
	spin_unlock(&files->file_lock);

out_files:
	put_files_struct(files);
out:
	/* For GET_BY_PID, always emit DONE to terminate the multipart
	 * dump even if zero sockets were found (the user-space tool
	 * waits for it).
	 */
	if (emit_done && ret == 0)
		ret = net_delayacct_emit_done(info);
	return ret;
}

static int net_delayacct_cmd_get_by_pid(struct sk_buff *skb,
					struct genl_info *info)
{
	struct pid *pidp;
	struct task_struct *task;
	u32 pid;
	int ret;

	if (!info->attrs[NET_DELAYACCT_A_PID])
		return -EINVAL;

	pid = nla_get_u32(info->attrs[NET_DELAYACCT_A_PID]);

	pr_info("net_delayacct: cmd_get_by_pid: querying pid=%u\n", pid);

	rcu_read_lock();
	pidp = find_get_pid(pid);
	if (!pidp) {
		rcu_read_unlock();
		return -ESRCH;
	}
	task = pid_task(pidp, PIDTYPE_PID);
	if (!task) {
		put_pid(pidp);
		rcu_read_unlock();
		return -ESRCH;
	}
	get_task_struct(task);
	rcu_read_unlock();

	ret = net_delayacct_iter_task_sockets(task, info, true);

	put_task_struct(task);
	put_pid(pidp);
	return ret;
}

static int net_delayacct_cmd_get_by_inode(struct sk_buff *skb,
					  struct genl_info *info)
{
	u64 target_inode;
	struct task_struct *task;

	if (!info->attrs[NET_DELAYACCT_A_INODE])
		return -EINVAL;
	target_inode = nla_get_u64(info->attrs[NET_DELAYACCT_A_INODE]);

	rcu_read_lock();
	for_each_process(task) {
		struct files_struct *files;
		struct fdtable *fdt;
		unsigned int fd;
		int ret;

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
			u64 ino;

			if (!file)
				continue;
			sk = sock_from_file_safe(file);
			if (!is_inet_tcp_udp(sk))
				continue;
			ino = sock_inode_for(sk);
			if (ino != target_inode)
				continue;

			get_file(file);
			sock_hold(sk);
			spin_unlock(&files->file_lock);

			ret = net_delayacct_one_reply(info, 0, sk,
						      task_pid_nr(task),
						      task->comm, ino);
			sock_put(sk);
			fput(file);
			put_files_struct(files);
			rcu_read_unlock();
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

	return 0;
}

/*
 * Out-of-line implementations of the helpers that touch
 * sk->sk_net_delayacct.  They cannot live in the header because it is
 * included from include/net/sock.h before struct sock is fully
 * defined.
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
	spin_lock(&n->lock);
	n->stats.rx_total_ns += delta;
	n->stats.rx_count++;
	spin_unlock(&n->lock);
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
	spin_lock(&n->lock);
	n->stats.tx_total_ns += delta;
	n->stats.tx_count++;
	spin_unlock(&n->lock);
}

void net_delayacct_get_stats(struct sock *sk,
			     struct net_delayacct_stats *out)
{
	struct net_delayacct *n = &sk->sk_net_delayacct;

	spin_lock(&n->lock);
	*out = n->stats;
	spin_unlock(&n->lock);
}

void net_delayacct_reset(struct sock *sk)
{
	struct net_delayacct *n = &sk->sk_net_delayacct;

	spin_lock(&n->lock);
	memset(&n->stats, 0, sizeof(n->stats));
	spin_unlock(&n->lock);
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
	pr_info("net_delayacct: framework registered (family=%u)\n",
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
MODULE_AUTHOR("h1y2g3l4y5 <h1y2g3l4y5@example.com>");
