# Split Tunnel

Start the network namespace, then configure the VPN routes and SNAT rules:

```sh
./split-tunnel.sh start

ip netns exec splittunnel ipsec start

SPLITTUNNEL_IPRANGELIST=172.19.0.0/16 \
./split-tunnel.sh routes
```

`routes` sends each CIDR in the comma-separated `SPLITTUNNEL_IPRANGELIST`
through the namespace and configures SNAT to `SPLITTUNNEL_VIP`. If it is unset
or empty, `routes` uses the virtual IP reported by `swanctl --list-sas`. Run it
after starting ipsec. Use `./split-tunnel.sh stop` to tear down the namespace
and `./split-tunnel.sh status` to inspect it.
