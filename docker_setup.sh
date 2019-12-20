#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright(c) 2019 Intel Corporation

set -e
# TCP port of bess-web monitor
gui_port=8000

# Driver options. Choose any one of the three
#
# "dpdk" set as default
# "af_xdp" uses AF_XDP sockets via DPDK's vdev for pkt I/O. This version is non-zc version. ZC version still needs to be evaluated.
# "af_packet" uses AF_PACKET sockets via DPDK's vdev for pkt I/O.
mode="dpdk"
#mode="af_xdp"
#mode="af_packet"

# Gateway interface(s)
#
# In the order of ("s1u" "sgi")
ifaces=("ens803f2" "ens803f3")

# Static IP addresses of gateway interface(s) in cidr format
#
# In the order of (s1u sgi)
ipaddrs=(198.18.0.1/30 198.19.0.1/30)

# MAC addresses of gateway interface(s)
#
# In the order of (s1u sgi)
macaddrs=(68:05:ca:33:2e:20 68:05:ca:33:2e:21)

# Static IP addresses of the neighbors of gateway interface(s)
#
# In the order of (n-s1u n-sgi)
nhipaddrs=(198.18.0.2 198.19.0.2)

# Static MAC addresses of the neighbors of gateway interface(s)
#
# In the order of (n-s1u n-sgi)
nhmacaddrs=(68:05:ca:31:fa:7a 68:05:ca:31:fa:7b)

# IPv4 route table entries in cidr format per port
#
# In the order of ("{r-s1u}" "{r-sgi}")
routes=("11.1.1.128/27 11.1.1.160/27 11.1.1.192/27 11.1.1.224/27" "13.1.1.128/27 13.1.1.160/27 13.1.1.192/27 13.1.1.224/27")

num_ifaces=${#ifaces[@]}
num_ipaddrs=${#ipaddrs[@]}

# Set up static route and neighbor table entries of the SPGW
function setup_trafficgen_routes() {
	for ((i = 0; i < num_ipaddrs; i++)); do
		sudo ip netns exec bess ip neighbor add "${nhipaddrs[$i]}" lladdr "${nhmacaddrs[$i]}" dev "${ifaces[$i % num_ifaces]}"
		routelist=${routes[$i]}
		for route in $routelist; do
			sudo ip netns exec bess ip route add "$route" via "${nhipaddrs[$i]}"
		done
	done
}

# Assign IP address(es) of gateway interface(s) within the network namespace
function setup_addrs() {
	for ((i = 0; i < num_ipaddrs; i++)); do
		sudo ip netns exec bess ip addr add "${ipaddrs[$i]}" dev "${ifaces[$i % $num_ifaces]}"
	done
}

# Set up mirror links to communicate with the kernel
#
# These vdev interfaces are used for ARP + ICMP updates.
# ARP/ICMP requests are sent via the vdev interface to the kernel.
# ARP/ICMP responses are captured and relayed out of the dpdk ports.
function setup_mirror_links() {
	for ((i = 0; i < num_ifaces; i++)); do
		sudo ip netns exec bess ip link add "${ifaces[$i]}" type veth peer name "${ifaces[$i]}"-vdev
		sudo ip netns exec bess ip link set "${ifaces[$i]}" up
		sudo ip netns exec bess ip link set "${ifaces[$i]}-vdev" up
		sudo ip netns exec bess ip link set dev "${ifaces[$i]}" address "${macaddrs[$i]}"
	done
	setup_addrs
}

# Set up interfaces in the network namespace. For non-"dpdk" mode(s)
function move_ifaces() {
	for ((i = 0; i < num_ifaces; i++)); do
		sudo ip link set "${ifaces[$i]}" netns bess up
	done
	setup_addrs
}

# Stop previous instances of bess-web, bess-cpiface, bess-routectl and bess before restarting
docker stop bess bess-routectl bess-web bess-cpiface || true
docker rm -f bess bess-routectl bess-web bess-cpiface || true
sudo rm -rf /var/run/netns/bess

# Build
./scripts/build.sh

[ "$mode" == 'dpdk' ] && DEVICES=${DEVICES:-'--device=/dev/vfio/48 --device=/dev/vfio/49 --device=/dev/vfio/vfio'} || DEVICES=''
[ "$mode" == 'af_xdp' ] && PRIVS='--privileged' || PRIVS='--cap-add NET_ADMIN'

# Run bessd
docker run --name bess -td --restart unless-stopped \
        --hostname `hostname` \
	--cpuset-cpus=12-13 \
	--ulimit memlock=-1 -v /dev/hugepages:/dev/hugepages \
	-v "$PWD/conf":/opt/bess/bessctl/conf \
	-v "$PWD/conf":/bin/conf \
	-p $gui_port:$gui_port \
	$PRIVS \
	$DEVICES \
	spgwu

sudo mkdir -p /var/run/netns
sandbox=$(docker inspect --format='{{.NetworkSettings.SandboxKey}}' bess)
sudo ln -s "$sandbox" /var/run/netns/bess

case $mode in
"dpdk") setup_mirror_links ;;
*)
	move_ifaces
	# Make sure that kernel does not send back icmp dest unreachable msg(s)
	sudo ip netns exec bess iptables -I OUTPUT -p icmp --icmp-type port-unreachable -j DROP
	;;
esac

# Setup trafficgen routes
setup_trafficgen_routes

docker logs bess

# Run bess-routectl
docker run --name bess-routectl -td --restart unless-stopped \
	-v "$PWD/conf/route_control.py":/route_control.py \
	--net container:bess --pid container:bess \
	--entrypoint /route_control.py \
	spgwu -i "${ifaces[@]}"

# Run bess-web
docker run --name bess-web -d --restart unless-stopped \
	--net container:bess \
	--entrypoint bessctl \
	spgwu http 0.0.0.0 $gui_port

# Run bess-cpiface
docker run --name bess-cpiface -td --restart unless-stopped \
	--net container:bess \
	--entrypoint zmq-cpiface \
	cpiface
