// SPDX-License-Identifier: GPL-2.0-only
/*
 * get_sockdelays.c - userspace client for the per-socket network
 * delay accounting framework (CONFIG_NET_DELAYACCT).
 *
 * Communicates with the kernel module over Generic Netlink family
 * "net_delayacct".  Supports three subcommands:
 *
 *   get_sockdelays --pid <pid>     List per-socket stats for every
 *                                  TCP/UDP socket owned by <pid>.
 *   get_sockdelays --inode <n>     Show stats for the socket whose
 *                                  inode equals <n>.
 *   get_sockdelays --reset         Zero all per-socket statistics.
 *
 * Build: see the accompanying Makefile (links against libmnl).
 *
 * Copyright (c) 2026 h1y2g3l4y5
 */

#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <linux/genetlink.h>
#include <linux/netlink.h>
#include <libmnl/libmnl.h>

#include <linux/net-delayacct.h>

#define NET_DELAYACCT_GENL_NAME	"net_delayacct"
#define NL_BUF_SIZE		(32 * 1024)

static const char *prog_name = "get_sockdelays";

static void usage(FILE *out)
{
	fprintf(out,
		"Usage: %s [options]\n"
		"\n"
		"Query the in-kernel per-socket network delay accounting\n"
		"framework (CONFIG_NET_DELAYACCT) over Generic Netlink.\n"
		"\n"
		"Exactly one of the following actions is required:\n"
		"  -p, --pid <pid>       List stats for every TCP/UDP socket\n"
		"                        owned by <pid>.\n"
		"  -i, --inode <n>       Show stats for the socket with\n"
		"                        inode <n>.\n"
		"  -R, --reset           Zero all per-socket statistics.\n"
		"\n"
		"Output options:\n"
		"  -j, --json            Emit machine-readable JSON.\n"
		"\n"
		"Miscellaneous:\n"
		"  -h, --help            Show this help and exit.\n"
		"  -V, --version         Print version and exit.\n"
		"\n"
		"The kernel must have CONFIG_NET_DELAYACCT=y and the\n"
		"net-delayacct module loaded.  Root may be required to\n"
		"query other users' sockets.\n",
		prog_name);
}

static void version(void)
{
	printf("%s 1.0\n", prog_name);
}

/*
 * Resolve the Generic Netlink family id for "net_delayacct" using the
 * CTRL_CMD_GETFAMILY request.  Returns the family id (>0) on success,
 * or a negative errno on failure.
 */
static int resolve_family_id(struct mnl_socket *nl)
{
	char buf[MNL_SOCKET_BUFFER_SIZE];
	struct nlmsghdr *nlh;
	unsigned int seq;
	int ret;

	nlh = mnl_nlmsg_put_header(buf);
	nlh->nlmsg_type = GENL_ID_CTRL;
	nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
	nlh->nlmsg_seq = seq = time(NULL);

	struct genlmsghdr *genl = mnl_nlmsg_put_extra_header(nlh, sizeof(*genl));
	genl->cmd = CTRL_CMD_GETFAMILY;
	genl->version = 1;
	genl->reserved = 0;

	mnl_attr_put_strz(nlh, CTRL_ATTR_FAMILY_NAME, NET_DELAYACCT_GENL_NAME);

	if (mnl_socket_sendto(nl, nlh, nlh->nlmsg_len) < 0) {
		perror("mnl_socket_sendto");
		return -errno;
	}

	ret = mnl_socket_recvfrom(nl, buf, sizeof(buf));
	if (ret < 0) {
		perror("mnl_socket_recvfrom");
		return -errno;
	}

	/*
	 * Walk the reply; the family id is the first u16 attribute of
	 * CTRL_ATTR_FAMILY_ID.
	 */
	unsigned int payload_len = ret;
	if (payload_len < NLMSG_HDRLEN + GENL_HDRLEN)
		return -EBADMSG;

	nlh = (struct nlmsghdr *)buf;
	if (nlh->nlmsg_type == NLMSG_ERROR) {
		struct nlmsgerr *err = mnl_nlmsg_get_payload(nlh);
		fprintf(stderr,
			"%s: family '%s' not registered (kernel returns %d)\n",
			prog_name, NET_DELAYACCT_GENL_NAME, err->error);
		return err->error ? err->error : -ENOENT;
	}

	struct nlattr *attr;

	mnl_attr_for_each(attr, nlh, GENL_HDRLEN) {
		if (mnl_attr_type_valid(attr, CTRL_ATTR_MAX) < 0)
			continue;
		if (mnl_attr_get_type(attr) == CTRL_ATTR_FAMILY_ID) {
			if (mnl_attr_validate(attr, MNL_TYPE_U16) < 0)
				return -EINVAL;
			return mnl_attr_get_u16(attr);
		}
	}

	return -ENOENT;
}

struct dump_ctx {
	int json;
	int rec_count;
};

static const char *proto_str(__u8 proto)
{
	switch (proto) {
	case IPPROTO_TCP: return "tcp";
	case IPPROTO_UDP: return "udp";
	default:          return "?";
	}
}

static void format_addr(char *out, size_t outsz, __u8 family,
			const void *addr, __u16 port)
{
	char buf[INET6_ADDRSTRLEN];

	if (family == AF_INET) {
		inet_ntop(AF_INET, addr, buf, sizeof(buf));
		snprintf(out, outsz, "%s:%u", buf, port);
	} else if (family == AF_INET6) {
		inet_ntop(AF_INET6, addr, buf, sizeof(buf));
		snprintf(out, outsz, "[%s]:%u", buf, port);
	} else {
		snprintf(out, outsz, "?:%u", port);
	}
}

/*
 * Parse one netlink message carrying a net_delayacct socket dump.
 * Returns MNL_CB_OK on success, MNL_CB_ERROR on parse failure.
 */
static int parse_msg_cb(const struct nlmsghdr *nlh, void *data)
{
	struct dump_ctx *ctx = data;
	struct nlattr *attr;
	const char *comm = NULL;
	char laddr_str[INET6_ADDRSTRLEN + 16];
	char raddr_str[INET6_ADDRSTRLEN + 16];
	__u8 family = 0, proto = 0;
	__u16 lport = 0, rport = 0;
	__u32 pid = 0;
	uint64_t inode = 0, rx_total = 0, rx_count = 0, tx_total = 0, tx_count = 0;
	const void *laddr = NULL, *raddr = NULL;

	if (nlh->nlmsg_type == NLMSG_ERROR) {
		struct nlmsgerr *err = mnl_nlmsg_get_payload(nlh);
		fprintf(stderr, "%s: netlink error %d\n",
			prog_name, err->error);
		return MNL_CB_ERROR;
	}
	if (nlh->nlmsg_type == NLMSG_DONE) {
		fprintf(stderr, "%s: [diag] received NLMSG_DONE (seq=%u pid=%u)\n",
			prog_name, nlh->nlmsg_seq, nlh->nlmsg_pid);
		return MNL_CB_OK;
	}

	/* Diagnostic: print non-error, non-DONE messages */
	fprintf(stderr, "%s: [diag] received msg type=%u (seq=%u pid=%u len=%u)\n",
		prog_name, nlh->nlmsg_type, nlh->nlmsg_seq,
		nlh->nlmsg_pid, nlh->nlmsg_len);

	mnl_attr_for_each(attr, nlh, GENL_HDRLEN) {
		switch (mnl_attr_get_type(attr)) {
		case NET_DELAYACCT_A_TYPE:
			proto = mnl_attr_get_u8(attr); break;
		case NET_DELAYACCT_A_FAMILY:
			family = mnl_attr_get_u8(attr); break;
		case NET_DELAYACCT_A_LADDR:
			laddr = mnl_attr_get_payload(attr);
			laddr_len = mnl_attr_get_payload_len(attr);
			break;
		case NET_DELAYACCT_A_LPORT:
			lport = mnl_attr_get_u16(attr); break;
		case NET_DELAYACCT_A_RADDR:
			raddr = mnl_attr_get_payload(attr);
			raddr_len = mnl_attr_get_payload_len(attr);
			break;
		case NET_DELAYACCT_A_RPORT:
			rport = mnl_attr_get_u16(attr); break;
		case NET_DELAYACCT_A_COMM:
			comm = mnl_attr_get_str(attr); break;
		case NET_DELAYACCT_A_PID:
			pid = mnl_attr_get_u32(attr); break;
		case NET_DELAYACCT_A_RX_TOTAL_NS:
			rx_total = mnl_attr_get_u64(attr); break;
		case NET_DELAYACCT_A_RX_COUNT:
			rx_count = mnl_attr_get_u64(attr); break;
		case NET_DELAYACCT_A_TX_TOTAL_NS:
			tx_total = mnl_attr_get_u64(attr); break;
		case NET_DELAYACCT_A_TX_COUNT:
			tx_count = mnl_attr_get_u64(attr); break;
		case NET_DELAYACCT_A_INODE:
			inode = mnl_attr_get_u64(attr); break;
		}
	}

	format_addr(laddr_str, sizeof(laddr_str), family, laddr, lport);
	format_addr(raddr_str, sizeof(raddr_str), family, raddr, rport);

	if (ctx->json) {
		if (ctx->rec_count > 0)
			printf(",\n");
		printf("  {");
		printf("\"proto\":\"%s\",\"pid\":%u,\"inode\":%" PRIu64 ",",
		       proto_str(proto), pid, inode);
		printf("\"comm\":\"%s\",", comm ? comm : "");
		printf("\"local\":\"%s\",\"remote\":\"%s\",",
		       laddr_str, raddr_str);
		printf("\"rx\":{\"total_ns\":%" PRIu64 ",\"count\":%" PRIu64 "},",
		       rx_total, rx_count);
		printf("\"tx\":{\"total_ns\":%" PRIu64 ",\"count\":%" PRIu64 "}",
		       tx_total, tx_count);
		printf("}");
	} else {
		printf("proto=%-3s pid=%-7u inode=%-10" PRIu64 " comm=%-16s ",
		       proto_str(proto), pid, inode, comm ? comm : "");
		printf("local=%-26s remote=%-26s ", laddr_str, raddr_str);
		printf("rx=%" PRIu64 "ns/%" PRIu64 "pkts  tx=%" PRIu64 "ns/%" PRIu64 "pkts\n",
		       rx_total, rx_count, tx_total, tx_count);
	}
	ctx->rec_count++;
	return MNL_CB_OK;
}

/*
 * Send a GENL request and dump the multipart reply.  Returns 0 on
 * success, negative errno on failure.
 */
static int send_and_recv(struct mnl_socket *nl, struct nlmsghdr *nlh,
			 struct dump_ctx *ctx)
{
	unsigned int seq, portid;
	char buf[NL_BUF_SIZE];
	int ret;

	seq = nlh->nlmsg_seq;
	portid = mnl_socket_get_portid(nl);

	fprintf(stderr, "%s: [diag] send_and_recv: seq=%u portid=%u type=%u\n",
		prog_name, seq, portid, nlh->nlmsg_type);

	if (mnl_socket_sendto(nl, nlh, nlh->nlmsg_len) < 0) {
		perror("mnl_socket_sendto");
		return -errno;
	}

	while (1) {
		ret = mnl_socket_recvfrom(nl, buf, sizeof(buf));
		if (ret < 0) {
			perror("mnl_socket_recvfrom");
			return -errno;
		}
		fprintf(stderr, "%s: [diag] recvfrom returned %d bytes\n",
			prog_name, ret);
		ret = mnl_cb_run(buf, ret, seq, portid,
				 parse_msg_cb, ctx);
		fprintf(stderr, "%s: [diag] mnl_cb_run returned %d\n",
			prog_name, ret);
		if (ret <= MNL_CB_STOP)
			break;
	}
	return ret == MNL_CB_ERROR ? -EIO : 0;
}

static int do_query(struct mnl_socket *nl, int family_id,
		    __u8 cmd, __u32 pid_attr_type, __u64 key,
		    int json)
{
	char buf[NL_BUF_SIZE];
	struct nlmsghdr *nlh;
	struct dump_ctx ctx = { .json = json, .rec_count = 0 };

	nlh = mnl_nlmsg_put_header(buf);
	nlh->nlmsg_type = family_id;
	nlh->nlmsg_flags = NLM_F_REQUEST;
	nlh->nlmsg_seq = time(NULL);

	struct genlmsghdr *genl = mnl_nlmsg_put_extra_header(nlh, sizeof(*genl));
	genl->cmd = cmd;
	genl->version = 1;
	genl->reserved = 0;

	if (pid_attr_type == NET_DELAYACCT_A_PID)
		mnl_attr_put_u32(nlh, NET_DELAYACCT_A_PID, (__u32)key);
	else if (pid_attr_type == NET_DELAYACCT_A_INODE)
		mnl_attr_put_u64(nlh, NET_DELAYACCT_A_INODE, key);

	if (json)
		printf("[\n");

	int ret = send_and_recv(nl, nlh, &ctx);

	if (json) {
		printf("\n]\n");
	} else if (ret == 0 && ctx.rec_count == 0) {
		printf("(no matching sockets)\n");
	}

	return ret;
}

static int do_reset(struct mnl_socket *nl, int family_id)
{
	char buf[NL_BUF_SIZE];
	struct nlmsghdr *nlh;
	struct dump_ctx ctx = {};

	nlh = mnl_nlmsg_put_header(buf);
	nlh->nlmsg_type = family_id;
	nlh->nlmsg_flags = NLM_F_REQUEST;
	nlh->nlmsg_seq = time(NULL);

	struct genlmsghdr *genl = mnl_nlmsg_put_extra_header(nlh, sizeof(*genl));
	genl->cmd = NET_DELAYACCT_CMD_RESET;
	genl->version = 1;
	genl->reserved = 0;

	if (send_and_recv(nl, nlh, &ctx) < 0) {
		fprintf(stderr, "%s: reset failed\n", prog_name);
		return 1;
	}
	printf("all per-socket statistics reset\n");
	return 0;
}

int main(int argc, char **argv)
{
	enum { OPT_NONE, OPT_PID, OPT_INODE, OPT_RESET } action = OPT_NONE;
	unsigned long pid = 0, inode = 0;
	int json = 0;
	int opt;
	int family_id;
	struct mnl_socket *nl;
	int rc = 0;

	static const char *short_opts = "hp:i:RjV";
	static const struct option long_opts[] = {
		{ "help",    no_argument,       NULL, 'h' },
		{ "pid",     required_argument, NULL, 'p' },
		{ "inode",   required_argument, NULL, 'i' },
		{ "reset",   no_argument,       NULL, 'R' },
		{ "json",    no_argument,       NULL, 'j' },
		{ "version", no_argument,       NULL, 'V' },
		{ NULL, 0, NULL, 0 },
	};

	while ((opt = getopt_long(argc, argv, short_opts, long_opts, NULL)) != -1) {
		switch (opt) {
		case 'h':
			usage(stdout);
			return 0;
		case 'V':
			version();
			return 0;
		case 'p':
			action = OPT_PID;
			pid = strtoul(optarg, NULL, 10);
			break;
		case 'i':
			action = OPT_INODE;
			inode = strtoul(optarg, NULL, 10);
			break;
		case 'R':
			action = OPT_RESET;
			break;
		case 'j':
			json = 1;
			break;
		default:
			usage(stderr);
			return 2;
		}
	}

	if (action == OPT_NONE) {
		fprintf(stderr, "%s: no action specified\n", prog_name);
		usage(stderr);
		return 2;
	}

	nl = mnl_socket_open(NETLINK_GENERIC);
	if (!nl) {
		perror("mnl_socket_open");
		return 1;
	}
	if (mnl_socket_bind(nl, 0, MNL_SOCKET_AUTOPID) < 0) {
		perror("mnl_socket_bind");
		mnl_socket_close(nl);
		return 1;
	}

	family_id = resolve_family_id(nl);
	if (family_id < 0) {
		fprintf(stderr,
			"%s: cannot find Generic Netlink family '%s'\n"
			"        (is the net-delayacct module loaded?)\n",
			prog_name, NET_DELAYACCT_GENL_NAME);
		mnl_socket_close(nl);
		return 1;
	}

	switch (action) {
	case OPT_PID:
		rc = do_query(nl, family_id, NET_DELAYACCT_CMD_GET_BY_PID,
			      NET_DELAYACCT_A_PID, pid, json);
		break;
	case OPT_INODE:
		rc = do_query(nl, family_id, NET_DELAYACCT_CMD_GET_BY_INODE,
			      NET_DELAYACCT_A_INODE, inode, json);
		break;
	case OPT_RESET:
		rc = do_reset(nl, family_id);
		break;
	default:
		break;
	}

	mnl_socket_close(nl);
	return rc < 0 ? 1 : rc;
}
