#!/bin/sh

set -eu
[ "$(id -u)" = 0 ] || { echo 'Run as root on the router' >&2; exit 1; }
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo 'Usage: install.sh manual|irqbalance [threaded|softirq]' >&2; exit 2; }
mode=$1
processing=${2:-threaded}
case "$mode" in manual|irqbalance) ;; *) echo 'Choose manual or irqbalance' >&2; exit 2 ;; esac
case "$processing" in threaded|softirq) ;; *) echo 'Choose threaded or softirq processing' >&2; exit 2 ;; esac
if [ "$processing" = softirq ] && [ "$mode" != manual ]; then
	echo 'The softirq profile requires manual IRQ placement' >&2
	exit 2
fi
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Validate the layout and required controller before changing the running profile.
sh /etc/rc.common "$dir/napi-xps-fix" check "$mode" "$processing"
if [ "$mode" = irqbalance ]; then
	[ -x /etc/init.d/irqbalance ] && [ -x /usr/sbin/irqbalance ] || {
		echo 'irqbalance is not installed; install it separately before selecting this mode' >&2
		exit 1
	}
fi
[ -z "$(uci changes)" ] || { echo 'Commit or revert pending UCI changes before installing' >&2; exit 1; }

# Serialize installers; keep a temporary copy of every file/link being replaced.
lock=/tmp/napi-xps-install.lock
mkdir "$lock" 2>/dev/null || { echo 'Another installation is in progress' >&2; exit 1; }
umask 077
backup=
changed=0
previous_threaded=$(cat /sys/class/net/eth0/threaded)
daemon_was_running=0
pidof irqbalance >/dev/null && daemon_was_running=1
managed_files() {
	printf '%s\n' /etc/init.d/napi-xps-fix /usr/libexec/platform/packet-steering.sh \
		/etc/config/napi_xps /etc/config/irqbalance /etc/config/network /etc/sysupgrade.conf
	for file in /etc/rc.d/*napi-xps-fix /etc/rc.d/*irqbalance; do
		[ ! -e "$file" ] && [ ! -L "$file" ] || printf '%s\n' "$file"
	done
}
stop_daemon() {
	if [ -x /etc/init.d/irqbalance ]; then
		/etc/init.d/irqbalance stop
		/etc/init.d/irqbalance disable
	fi
	for attempt in 1 2 3 4 5; do
		if ! pidof irqbalance >/dev/null; then return 0; fi
		sleep 1
	done
	echo 'irqbalance is still running; refusing competing IRQ controllers' >&2
	return 1
}
finish() {
	result=$?
	trap - EXIT HUP INT TERM
	if [ "$result" -ne 0 ] && [ "$changed" = 1 ]; then
		set +e
		echo 'Installation failed; restoring the previous profile.' >&2
		stop_daemon
		rm -f /usr/libexec/platform/packet-steering.sh
		sh /etc/rc.common "$dir/napi-xps-fix" release_irqs
		managed_files | while IFS= read -r file; do rm -f "$file"; done
		tar -C / -xf "$backup/files.tar"
		# Restore the previous NAPI mode before reloading its service.
		printf '%s\n' "$previous_threaded" > /sys/class/net/eth0/threaded
		if [ "$daemon_was_running" = 1 ] && ! pidof irqbalance >/dev/null; then /etc/init.d/irqbalance start; fi
		/etc/init.d/packet_steering reload
		if [ -x /etc/init.d/napi-xps-fix ] && /etc/init.d/napi-xps-fix enabled; then
			/etc/init.d/napi-xps-fix reload
		fi
	fi
	[ -z "$backup" ] || rm -rf "$backup"
	rmdir "$lock"
	exit "$result"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
backup=$(mktemp -d /tmp/napi-xps-backup.XXXXXX)
managed_files | while IFS= read -r file; do
	[ ! -e "$file" ] && [ ! -L "$file" ] || printf '%s\n' "${file#/}"
done > "$backup/files"
tar -C / -cf "$backup/files.tar" -T "$backup/files"
changed=1

stop_daemon

# Detach the hook and procd service without invoking a stop that could rewrite IRQs.
rm -f /usr/libexec/platform/packet-steering.sh
ubus call service delete '{"name":"napi-xps-fix"}' >/dev/null 2>&1 || true
cp "$dir/napi-xps-fix" /etc/init.d/napi-xps-fix
mkdir -p /usr/libexec/platform
cp "$dir/packet-steering.sh" /usr/libexec/platform/packet-steering.sh
chmod 755 /etc/init.d/napi-xps-fix /usr/libexec/platform/packet-steering.sh
/etc/init.d/napi-xps-fix disable
cat > /etc/config/napi_xps <<CONFIG
config profile 'main'
	option irq_mode '$mode'
	option processing '$processing'
CONFIG

if [ "$mode" = irqbalance ]; then
	# Release the previous manual constraints before the daemon takes ownership.
	/etc/init.d/napi-xps-fix release_irqs
	cat > /etc/config/irqbalance <<'CONFIG'
config irqbalance 'irqbalance'
	option enabled '1'
	option deepestcache '2'
	option interval '10'
	option debug '0'
CONFIG
	/etc/init.d/irqbalance enable
	/etc/init.d/irqbalance start
	for attempt in 1 2 3 4 5; do
		if pidof irqbalance >/dev/null; then break; fi
		sleep 1
	done
	pidof irqbalance >/dev/null
elif uci -q get irqbalance.irqbalance >/dev/null; then
	uci set irqbalance.irqbalance.enabled=0
	uci commit irqbalance
fi
uci set 'network.@globals[0].packet_steering=1'
uci set 'network.@globals[0].steering_flows=0'
uci commit network
/etc/init.d/napi-xps-fix enable
/etc/init.d/packet_steering reload
/etc/init.d/napi-xps-fix reload
/etc/init.d/napi-xps-fix verify

touch /etc/sysupgrade.conf
for file in /etc/init.d/napi-xps-fix /usr/libexec/platform/packet-steering.sh \
	/etc/config/napi_xps /etc/rc.d/S95napi-xps-fix /etc/rc.d/K10napi-xps-fix; do
	grep -qxF "$file" /etc/sysupgrade.conf || echo "$file" >> /etc/sysupgrade.conf
done
/etc/init.d/napi-xps-fix show
echo "NAPI/XPS installed: $mode IRQs, $processing processing."
