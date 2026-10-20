#!/usr/bin/env bash
set -Eeuo pipefail

# ===== Configuration =====
NS="${NS:-splittunnel}"
VETH_HOST="${VETH_HOST:-splittunnel-host}"
VETH_NS="${VETH_NS:-splittunnel-ns}"

HOST_IP="${HOST_IP:-10.200.0.1}"
NS_IP="${NS_IP:-10.200.0.2}"
PREFIX="${PREFIX:-30}"

# Destination CIDR to allow communication from the netns
DEST_CIDR="${DEST_CIDR:-0.0.0.0/0}"

# VPN virtual IP override and comma-separated destination ranges
SPLITTUNNEL_VIP="${SPLITTUNNEL_VIP:-}"
SPLITTUNNEL_IPRANGELIST="${SPLITTUNNEL_IPRANGELIST:-}"
IPRANGES=()
if [[ -n "$SPLITTUNNEL_IPRANGELIST" ]]; then
    IFS=',' read -r -a IPRANGES <<< "$SPLITTUNNEL_IPRANGELIST"
fi

# Outgoing interface on the parent host
if [[ -z "${OUT_IF:-}" ]]; then
    OUT_IF=$(ip route get 8.8.8.8 | sed -n 's/.* dev \([^ ]*\).*/\1/p')
fi

# Identification comment for iptables
TAG="netns-${NS}"

STATE_DIR="/run/netns-veth"
STATE_FILE="${STATE_DIR}/${NS}.state"

IPT=(iptables -w)

require_root() {
    if (( EUID != 0 )); then
        echo "Please run as root" >&2
        exit 1
    fi
}

ns_exists() {
    ip netns list | awk '{print $1}' | grep -Fxq "$NS"
}

# Delete rules only if they exist
del_rule() {
    local table="$1"
    shift
    while "${IPT[@]}" -t "$table" -C "$@" 2>/dev/null; do
        "${IPT[@]}" -t "$table" -D "$@"
    done
}

forward_out=(
    FORWARD -i "$VETH_HOST" -o "$OUT_IF"
    -s "${NS_IP}/32" -d "$DEST_CIDR"
    -m comment --comment "$TAG"
    -j ACCEPT
)

forward_in=(
    FORWARD -i "$OUT_IF" -o "$VETH_HOST"
    -d "${NS_IP}/32" -s "$DEST_CIDR"
    -m conntrack --ctstate ESTABLISHED,RELATED
    -m comment --comment "$TAG"
    -j ACCEPT
)

forward_drop=(
    FORWARD -i "$VETH_HOST"
    -m comment --comment "$TAG"
    -j DROP
)

nat_rule=(
    POSTROUTING -s "${NS_IP}/32"
    -d "$DEST_CIDR" -o "$OUT_IF"
    -m comment --comment "$TAG"
    -j MASQUERADE
)

start() {
    if ns_exists || [[ -e "$STATE_FILE" ]] ||
       ip link show "$VETH_HOST" &>/dev/null; then
        echo "Existing netns or configuration found" >&2
        exit 1
    fi

    ip link show "$OUT_IF" >/dev/null

    mkdir -p "$STATE_DIR"

    # Save the current forwarding state
    local old_forward
    old_forward=$(sysctl -n net.ipv4.ip_forward)
    printf '%s\n' "$old_forward" > "$STATE_FILE"

    # Clean up in case of failure
    trap 'stop' ERR

    # Create the namespace
    ip netns add "$NS"

    # Create the veth pair
    ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
    ip link set "$VETH_NS" netns "$NS"

    # On the parent host
    ip addr add "${HOST_IP}/${PREFIX}" dev "$VETH_HOST"
    ip link set "$VETH_HOST" up

    # In the namespace
    ip -n "$NS" link set lo up
    ip -n "$NS" addr add "${NS_IP}/${PREFIX}" dev "$VETH_NS"
    ip -n "$NS" link set "$VETH_NS" up

    # Route only the specified CIDR through the parent
    ip -n "$NS" route add "$DEST_CIDR" via "$HOST_IP"

    # Enable IP forwarding
    sysctl -qw net.ipv4.ip_forward=1

    # FORWARD and NAT rules
    # Place DROP at the beginning, then insert the allow rules
    "${IPT[@]}" -I FORWARD 1 "${forward_drop[@]:1}"
    "${IPT[@]}" -I FORWARD 1 "${forward_in[@]:1}"
    "${IPT[@]}" -I FORWARD 1 "${forward_out[@]:1}"
    "${IPT[@]}" -t nat -I POSTROUTING 1 "${nat_rule[@]:1}"

    trap - ERR

    echo "netns started: $NS"
    status
}

configure_routes() {
    if ! ns_exists || ! ip link show "$VETH_HOST" &>/dev/null; then
        echo "Network namespace is not running" >&2
        exit 1
    fi
    local vpn_vip="$SPLITTUNNEL_VIP"
    if [[ -z "$vpn_vip" ]]; then
        vpn_vip=$(swanctl --list-sas | sed -nE 's/^[[:space:]]+local[[:space:]]+.*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\]$/\1/p')
        if [[ -z "$vpn_vip" ]]; then
            echo "Could not determine VPN virtual IP from swanctl --list-sas" >&2
            exit 1
        fi
    fi
    if ((${#IPRANGES[@]} == 0)); then
        echo "SPLITTUNNEL_IPRANGELIST must contain at least one CIDR" >&2
        exit 1
    fi

    for IPRANGE in "${IPRANGES[@]}"; do
        [[ -n "$IPRANGE" ]] || continue
        ip route replace "$IPRANGE" via "$NS_IP" dev "$VETH_HOST" mtu 1214
        ip netns exec "$NS" "${IPT[@]}" -t nat -C POSTROUTING \
            -s "${HOST_IP}/32" -d "$IPRANGE" -o "$VETH_NS" \
            -j SNAT --to-source "$vpn_vip" 2>/dev/null || \
        ip netns exec "$NS" "${IPT[@]}" -t nat -I POSTROUTING 1 \
            -s "${HOST_IP}/32" -d "$IPRANGE" -o "$VETH_NS" \
            -j SNAT --to-source "$vpn_vip"
    done
}

stop() {
    # Delete only the rules that belong to this script
    del_rule nat "${nat_rule[@]}"
    del_rule filter "${forward_out[@]}"
    del_rule filter "${forward_in[@]}"
    del_rule filter "${forward_drop[@]}"

    # Delete the netns-side veth when the namespace is deleted
    if ns_exists; then
        ip netns del "$NS"
    fi

    # If the parent-side veth still exists, delete it
    if ip link show "$VETH_HOST" &>/dev/null; then
        ip link del "$VETH_HOST"
    fi

    # Restore forwarding state
    if [[ -f "$STATE_FILE" ]]; then
        local old_forward
        old_forward=$(cat "$STATE_FILE")
        sysctl -qw net.ipv4.ip_forward="$old_forward"
        rm -f "$STATE_FILE"
    fi

    echo "netns stopped: $NS"
}

status() {
    echo "Namespace: $NS"
    if ns_exists; then
        ip -n "$NS" -br addr
        echo "--- routes ---"
        ip -n "$NS" route
    else
        echo "Stopped"
    fi
}

require_root

case "${1:-}" in
    start)  start ;;
    routes) configure_routes ;;
    stop)   stop ;;
    status) status ;;
    *)
        echo "Usage: $0 {start|routes|stop|status}"
        exit 1
        ;;
esac
