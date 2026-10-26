#!/bin/sh
# Reapply the selected NAPI/XPS/IRQ profile after stock packet steering.
set -e
/usr/libexec/network/packet-steering.uc "$@"
if /etc/init.d/napi-xps-fix enabled; then
	/etc/init.d/napi-xps-fix reload
fi
