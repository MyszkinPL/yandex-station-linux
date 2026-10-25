#!/bin/sh
# busybox udhcpc hook: configure the lease on $interface. udhcpc runs for as
# long as the Station does: renew keeps the address in place (no flush, so
# connections live on), the DNS servers go into the root filesystem too
# ($NEWROOT, from init) where the services read them.
case "$1" in
deconfig)
	# udhcpc's own output is gone once it runs in the background
	echo "udhcpc: no lease on $interface" > /dev/kmsg
	ip addr flush dev "$interface"
	ip link set "$interface" up
	;;
bound|renew)
	echo "udhcpc: $1 $ip on $interface, lease ${lease:-?} s" > /dev/kmsg
	if ! ip -4 addr show dev "$interface" | grep -q "inet $ip/"; then
		ip addr flush dev "$interface"
		ip addr add "$ip/${mask:-24}" dev "$interface"
	fi
	[ -n "$router" ] && ip route replace default via "${router%% *}" dev "$interface"
	: > /etc/resolv.conf
	for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done
	[ -n "$NEWROOT" ] && cp /etc/resolv.conf "$NEWROOT/etc/resolv.conf"
	echo "$ip" > /tmp/ip
	;;
esac
exit 0
