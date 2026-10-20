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

`routes` saves the original IPv4 main-table routes for each destination under
`/run/netns-veth/${NS}.routes/` before replacing them. Repeated calls preserve
the first snapshot, including when equivalent CIDRs are supplied. Route
attributes are saved with `ip route save` and restored with `ip route restore`.
The script uses `flock` to serialize `start`, `routes`, and `stop` operations.

`stop` restores these routes before deleting the namespace or veth. Routes
that did not previously exist are removed. You do not need to supply
`SPLITTUNNEL_IPRANGELIST` again when stopping; use the same namespace and
interface configuration as when starting.

If a route differs from the recorded configuration, `stop` reports the
conflict and exits without overwriting that route or tearing down the
namespace. Saved state is also retained if restoration fails, so you can
resolve the cause and retry `stop`. Some earlier destinations may already
have been restored. An interruption between changing a route and recording
its resulting state requires manual inspection; the script retains the
snapshot and refuses automatic cleanup. Snapshots are kept in `/run` and do
not survive reboot. Routes changed by an older script version, before this
snapshot mechanism was introduced, cannot be restored automatically.

Run the offline lifecycle tests with:

```sh
python3 -m unittest discover -s tests -v
```

These tests mock networking commands and do not validate live kernel routing
or VPN connectivity.
