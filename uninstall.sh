#!/bin/sh

set -eu
[ "$(id -u)" = 0 ] || { echo 'Run as root on the router' >&2; exit 1; }
if [ -x /etc/init.d/irqbalance ]; then
	/etc/init.d/irqbalance stop
	/etc/init.d/irqbalance disable
fi
if uci -q get irqbalance.irqbalance >/dev/null; then
	uci set irqbalance.irqbalance.enabled=0
	uci commit irqbalance
fi
for attempt in 1 2 3 4 5; do
	if ! pidof irqbalance >/dev/null; then break; fi
	sleep 1
done
! pidof irqbalance >/dev/null || { echo 'irqbalance is still running; removal stopped' >&2; exit 1; }
/etc/init.d/napi-xps-fix disable
rm -f /usr/libexec/platform/packet-steering.sh
/etc/init.d/napi-xps-fix stop
rm -f /etc/init.d/napi-xps-fix /etc/config/napi_xps
sed -i '\|^/etc/init.d/napi-xps-fix$|d; \|^/usr/libexec/platform/packet-steering.sh$|d; \|^/etc/config/napi_xps$|d; \|^/etc/rc.d/S95napi-xps-fix$|d; \|^/etc/rc.d/K10napi-xps-fix$|d' /etc/sysupgrade.conf
/etc/init.d/packet_steering reload
echo 'NAPI/XPS profile removed; stock packet steering restored and irqbalance disabled.'
