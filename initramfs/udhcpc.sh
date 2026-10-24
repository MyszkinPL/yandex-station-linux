#!/bin/sh
# busybox udhcpc hook: configure the lease on $interface
case "$1" in
deconfig)
	ip addr flush dev "$interface"
	ip link set "$interface" up
	;;
bound|renew)
	ip addr flush dev "$interface"
	ip addr add "$ip/${mask:-24}" dev "$interface"
	[ -n "$router" ] && ip route replace default via "${router%% *}" dev "$interface"
	: > /etc/resolv.conf
	for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done
	echo "$ip" > /tmp/ip
	;;
esac
exit 0
