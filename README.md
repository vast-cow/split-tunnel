# Split Tunnel

```
./netns.sh start

ip netns exec splittunnel ipsec start

ip -n ns-test a
VIRTUALIP=192.168.249.15
IPRANGES=(
  "172.19.0.0/16"
)

for IPRANGE in "${IPRANGES[@]}"; do
  ip route add "${IPRANGE}" via 10.200.0.2 dev splittunnel-host mtu 1214

  ip netns exec splittunnel \
    iptables -t nat -I POSTROUTING 1 \
      -s 10.200.0.1/32 \
      -d "${IPRANGE}" \
      -o splittunnel-ns \
      -j SNAT --to-source "${VIRTUALIP}"
done
```