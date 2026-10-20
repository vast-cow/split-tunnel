# Split Tunnel

Start the network namespace, then configure the VPN routes and SNAT rules:

```sh
./split-tunnel.sh create

./split-tunnel.sh exec ipsec start

./split-tunnel.sh config --iprange 172.19.0.0/16 --vip 192.0.2.10
```

`config --iprange CIDR[,CIDR...]` sends each destination range through the namespace, and `--vip IPv4` sets the SNAT virtual IP. These options override `SPLITTUNNEL_IPRANGELIST` and `SPLITTUNNEL_VIP` respectively; the environment variables remain supported. If no VIP is set, `config` uses the virtual IP reported by `swanctl --list-sas`. Run it after ipsec has established the VPN connection. Use `./split-tunnel.sh exec COMMAND [ARG ...]` to run any command inside the configured namespace (the namespace name follows `NS`, default `st`). Use `./split-tunnel.sh delete` to tear down the namespace
and `./split-tunnel.sh status` to inspect it.

`config` saves the original IPv4 main-table routes for each destination under
`/run/netns-veth/${NS}.routes/` before replacing them. Repeated calls preserve
the first snapshot, including when equivalent CIDRs are supplied. Route
attributes are saved with `ip route save` and restored with `ip route restore`.
The script uses `flock` to serialize `create`, `config`, and `delete` operations.

`delete` restores these routes before deleting the namespace or veth. Routes
that did not previously exist are removed. You do not need to supply
`SPLITTUNNEL_IPRANGELIST` again when deleting; use the same namespace and
interface configuration as when creating.

If a route differs from the recorded configuration, `delete` reports the
conflict and exits without overwriting that route or tearing down the
namespace. Saved state is also retained if restoration fails, so you can
resolve the cause and retry `delete`. Some earlier destinations may already
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
