.. SPDX-License-Identifier: GPL-2.0

This is a fragment showing how to register the new document in the
networking documentation index. Apply the change below to
``Documentation/networking/index.rst`` so that ``net-delayacct`` is
included in the generated toctree.

.. Add the following line to the toctree of Documentation/networking/index.rst

   net-delayacct

The entry must be placed inside an existing ``.. toctree::`` directive
of ``Documentation/networking/index.rst``, for example::

    .. toctree::
       :maxdepth: 1

       kapi
       z8530book
       msg_zerocopy
       net-delayacct

After the edit, rebuild the documentation with
``make htmldocs`` and verify the new page appears under
``Documentation/networking/``.
