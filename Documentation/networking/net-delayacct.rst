.. SPDX-License-Identifier: GPL-2.0

============================================
Per-socket Network Delay Accounting
============================================

Overview
========

``CONFIG_NET_DELAYACCT`` is a per-socket network delay accounting
framework for the Linux kernel. It is inspired by the existing
``CONFIG_DELAYACCT`` task-level delay accounting framework and its
``getdelays`` user-space tool, but shifts the accounting granularity
from the *task* down to the *socket*.

While ``CONFIG_DELAYACCT`` accumulates the time a task spends waiting
for CPU, I/O, memory reclaim or swap, ``CONFIG_NET_DELAYACCT``
accumulates the time a packet spends travelling through the kernel
networking stack on behalf of a given socket, in both the receive (RX)
and transmit (TX) directions. The accumulated counters are exposed to
user space through a generic netlink family and can be read by the
``get_sockdelays`` tool, allowing operators and developers to quantify
per-socket protocol-stack latency without resorting to
``tcpdump``/``ss``/eBPF.

This feature is built against Linux 6.6. When the Kconfig option is
disabled, every instrumentation point compiles away to an empty inline
function and no field is added to ``struct sock`` or ``struct
sk_buff``, so the binary is identical to a stock 6.6 kernel.

Enabling
========

``CONFIG_NET_DELAYACCT`` is selected through the kernel configuration.
It depends on ``CONFIG_NET`` and defaults to ``n``::

    Networking support  --->
      Networking options  --->
        [*] Per-socket network delay accounting (CONFIG_NET_DELAYACCT)

It can also be enabled from the command line::

    scripts/config --enable CONFIG_NET_DELAYACCT
    make olddefconfig
    make -j$(nproc) bzImage modules

Because every instrumentation site is guarded by ``#ifdef
CONFIG_NET_DELAYACCT``, distributions that ship the option disabled pay
zero overhead and observe no ABI change.

Concepts
========

RX latency
----------

Receive (RX) latency is defined as the time interval from the moment a
packet enters the protocol stack entry point to the moment the owning
process copies it out to user space:

* **start**: ``__netif_receive_skb_core`` in ``net/core/dev.c`` -- the
  common convergence point for all incoming traffic. The start
  timestamp is stamped onto ``skb->delayacct_start``.
* **end**: ``tcp_recvmsg`` (for TCP) in ``net/ipv4/tcp.c`` right
  before ``skb_copy_datagram_iter``, or ``__skb_recv_udp`` (for UDP)
  in ``net/ipv4/udp.c`` right before returning the dequeued skb.

::

    +-----------------------+        +-------------------------+
    | __netif_receive_skb_  |        | tcp_recvmsg /          |
    | core (net/core/dev.c) |  ...   | __skb_recv_udp          |
    |   rx_start(skb)       |        |   rx_end(sk, skb)      |
    +-----------+-----------+        +------------+------------+
                |                                 |
                +---------> skb->delayacct_start--+
                              delta = now - start

TX latency
----------

Transmit (TX) latency is defined as the time interval from the moment
a process calls ``send``/``sendmsg`` to the moment the packet reaches
the NIC driver:

* **start**: ``tcp_sendmsg_locked`` (for TCP) for each newly allocated
  skb, or ``udp_sendmsg`` (for UDP) after ``ip_make_skb`` and before
  ``udp_send_skb``. The start timestamp is stamped onto
  ``skb->delayacct_start``.
* **end**: ``dev_hard_start_xmit`` in ``net/core/dev.c`` right before
  calling ``ops->ndo_start_xmit``.

::

    +-----------------------+        +-------------------------+
    | tcp_sendmsg /         |        | dev_hard_start_xmit     |
    | udp_sendmsg           |  ...   | (net/core/dev.c)        |
    |   tx_start(skb)       |        |   tx_end(skb->sk, skb)  |
    +-----------+-----------+        +------------+------------+
                |                                 |
                +---------> skb->delayacct_start--+
                              delta = now - start

Per-socket accumulation
-----------------------

Each ``struct sock`` embeds an independent ``struct net_delayacct``
instance. For every accounted packet the end function computes
``delta = now - skb->delayacct_start`` and, under a per-socket
spinlock, adds ``delta`` to the running total and increments the packet
counter. The average latency is therefore::

    avg_rx_ns = rx_total_ns / rx_count      (rx_count > 0)
    avg_tx_ns = tx_total_ns / tx_count      (tx_count > 0)

The kernel does not export a precomputed average; it only exports the
totals and counts, leaving division (and divide-by-zero handling) to
user space.

Statistics
==========

Each socket maintains the following four counters, all 64-bit and
naturally aligned inside ``struct net_delayacct_stats``:

.. list-table::
   :widths: 22 18 60
   :header-rows: 1

   * - Field
     - Type
     - Meaning
   * - ``rx_total_ns``
     - u64
     - Cumulative RX delay in nanoseconds across all accounted packets
       on this socket.
   * - ``rx_count``
     - u64
     - Number of RX packets accounted on this socket.
   * - ``tx_total_ns``
     - u64
     - Cumulative TX delay in nanoseconds across all accounted packets
       on this socket.
   * - ``tx_count``
     - u64
     - Number of TX packets accounted on this socket.

When a counter is zero the average is undefined; user space must print
``N/A`` rather than performing a division.

Interface
=========

The statistics are exposed through a generic netlink family named
``net_delayacct`` (version 1). The family is visible in
``/proc/net/genetlink`` once the module is initialised.

Commands
--------

.. list-table::
   :widths: 28 22 50
   :header-rows: 1

   * - Command
     - Request attribute
     - Description
   * - ``NET_DELAYACCT_CMD_GET_BY_PID``
     - ``PID`` (u32)
     - Return one netlink message per socket held by the target task.
       Replies use ``NLM_F_MULTI`` and are terminated by ``NLMSG_DONE``.
   * - ``NET_DELAYACCT_CMD_GET_BY_INODE``
     - ``INODE`` (u64)
     - Return the single socket whose sockfs inode matches. The reply
       is a single message (or an empty ``NLMSG_DONE`` if no match).
   * - ``NET_DELAYACCT_CMD_RESET``
     - (none)
     - Zero the statistics of every socket in every network namespace.

Attributes
----------

Each reply message carries the following attributes:

.. list-table::
   :widths: 30 14 56
   :header-rows: 1

   * - Attribute
     - Type
     - Meaning
   * - ``TYPE``
     - u8
     - L4 protocol: ``IPPROTO_TCP`` or ``IPPROTO_UDP``.
   * - ``LADDR``
     - 4B or 16B
     - Local address (IPv4 in 4 bytes, IPv6 in 16 bytes).
   * - ``LPORT``
     - u16
     - Local port, host byte order.
   * - ``RADDR``
     - 4B or 16B
     - Remote address.
   * - ``RPORT``
     - u16
     - Remote port, host byte order.
   * - ``COMM``
     - string
     - Command name of the owning task (``TASK_COMM_LEN``).
   * - ``PID``
     - u32
     - PID of the owning task.
   * - ``RX_TOTAL_NS``
     - u64
     - Cumulative RX delay.
   * - ``RX_COUNT``
     - u64
     - RX packet count.
   * - ``TX_TOTAL_NS``
     - u64
     - Cumulative TX delay.
   * - ``TX_COUNT``
     - u64
     - TX packet count.
   * - ``INODE``
     - u64
     - sockfs inode number, matching what ``readlink
       /proc/<pid>/fd/<n>`` reports as ``socket:[<inode>]``.

A multi-socket reply is structured as::

    +--------------------------+
    | nlmsghdr  (NLM_F_MULTI)  |
    +--------------------------+
    | genlmsghdr               |
    +--------------------------+
    | NLA: TYPE / LADDR / ...  |   <- socket #1
    +--------------------------+
    | nlmsghdr  (NLM_F_MULTI)  |
    +--------------------------+
    | genlmsghdr               |
    +--------------------------+
    | NLA: TYPE / LADDR / ...  |   <- socket #2
    +--------------------------+
            ...
    +--------------------------+
    | nlmsghdr  (NLMSG_DONE)   |
    +--------------------------+
    | int error = 0            |
    +--------------------------+

get_sockdelays tool
===================

The user-space tool ``get_sockdelays`` (located under ``tools/net/``)
queries the ``net_delayacct`` family and formats the results. Its
command-line interface mirrors the style of ``getdelays``.

Usage
-----

::

    get_sockdelays [-p <pid>] [-i <inode>] [-r] [-n] [-h]

.. list-table::
   :widths: 14 86
   :header-rows: 1

   * - Option
     - Description
   * - ``-p <pid>``
     - Query every socket held by the process ``<pid>`` and print one
       line per socket.
   * - ``-i <inode>``
     - Query a single socket by its sockfs inode number (the value
       shown by ``readlink /proc/<pid>/fd/<n>``).
   * - ``-r``
     - Reset the statistics of all sockets.
   * - ``-n``
     - Print latency values in nanoseconds. The default unit is
       microseconds.
   * - ``-h``
     - Print usage and exit.

Output format
-------------

The default output is a fixed-width table with one socket per line.
Latency columns show the *average* per-packet latency; ``N/A`` is
printed when the corresponding count is zero::

    TYPE  LADDR          LPORT  RADDR          RPORT  COMM       PID    AVG_RX(us)  AVG_TX(us)  RX#   TX#

Example
-------

Querying an nginx worker and a redis-server process (defaults to
microseconds)::

    # get_sockdelays -p 1234
    TYPE  LADDR          LPORT  RADDR          RPORT  COMM       PID    AVG_RX(us)  AVG_TX(us)  RX#   TX#
    TCP   10.0.0.1       443    192.168.1.5    54321  nginx      1234   12         8           1024  1024
    TCP   10.0.0.1       443    192.168.1.6    54322  nginx      1234   15         9           2048  2048

To obtain raw nanoseconds instead, pass ``-n``::

    # get_sockdelays -p 1234 -n
    TYPE  LADDR          LPORT  RADDR          RPORT  COMM       PID    AVG_RX(ns)  AVG_TX(ns)  RX#   TX#
    TCP   10.0.0.1       443    192.168.1.5    54321  nginx      1234   12340      8021        1024  1024
    TCP   10.0.0.1       443    192.168.1.6    54322  nginx      1234   15002      9044        2048  2048

Performance
===========

The per-packet overhead of a matched start/end pair is dominated by
two ``ktime_get_ns()`` reads plus a short spinlock critical section:

.. list-table::
   :widths: 50 50
   :header-rows: 1

   * - Operation
     - Cost (x86_64, TSC ~3 GHz)
   * - ``ktime_get_ns()`` (TSC read)
     - 10 - 20 ns
   * - spinlock lock/unlock (uncontended)
     - ~10 ns
   * - two 64-bit additions + one assignment
     - ~5 ns
   * - skb field read/write (cache hot)
     - ~2 ns
   * - **single start or end site**
     - **~25 - 40 ns**
   * - **matched start+end per packet**
     - **~50 - 80 ns**

At 10 Gbps with 64-byte frames (14.88 Mpps) the extra CPU is roughly
``14.88e6 * 80 ns ~= 1.19 s`` of CPU per second. On an 8-core machine
this is about **1.2% total CPU** (lower per-core once spread out).

Mitigations:

* The option is **off by default**; distributions that do not select
  it see zero overhead.
* All instrumentation is ``#ifdef``-guarded; with the option disabled
  the call sites become empty inline functions and ``struct sock`` /
  ``struct sk_buff`` regain their original sizes, so the compiled
  binary matches a stock 6.6 kernel.
* A ``static_branch`` may be layered on top so that, even when the
  option is compiled in, the disabled fast path is a single unlikely
  jump.

Limitations
===========

* Only **IPv4 and IPv6** addresses are reported.
* Only **TCP** (``SOCK_STREAM``) and **UDP** (``SOCK_DGRAM``) sockets
  are accounted. ``AF_UNIX``, ``AF_NETLINK``, ``AF_PACKET``,
  ``SOCK_RAW`` and other families are not covered.
* **GSO segmentation**: a single GSO skb that the driver later splits
  into multiple MTU-sized frames is counted as **one** packet, not as
  many. This matches the accounting granularity of the start point.
* ``GET_BY_INODE`` walks the task list and is O(N*M) in the number of
  tasks and file descriptors. It is intended for ad-hoc diagnosis by
  ``get_sockdelays``, not for high-frequency polling.
* Sockets shared between tasks (``CLONE_FILES`` or fd passing) are
  accounted once on the socket; querying each sharing PID returns the
  same accumulated values.
* Multicast / ``skb_shared()`` paths are not specially handled.

See Also
========

:doc:`/accounting/delay-accounting`

:doc:`/accounting/taskstats`

* ss(8)
* tcpdump(8)
