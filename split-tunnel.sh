#!/usr/bin/env bash
set -Eeuo pipefail

# ===== Configuration =====
NS="${NS:-st}"
VETH_HOST="${VETH_HOST:-st-host}"
VETH_NS="${VETH_NS:-st-ns}"

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
ROUTES_DIR="${STATE_DIR}/${NS}.routes"

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
    if ns_exists || [[ -e "$STATE_FILE" || -e "$ROUTES_DIR" ]] ||
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

# Normalize IPv4 CIDRs so equivalent inputs share the same saved state.
normalize_cidr() {
    local address prefix a b c d octet number mask
    IFS=/ read -r address prefix <<< "$1"
    prefix="${prefix:-32}"
    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ &&
       "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
    prefix=$((10#$prefix))
    ((prefix <= 32)) || return 1
    IFS=. read -r a b c d <<< "$address"
    for octet in "$a" "$b" "$c" "$d"; do
        ((${#octet} <= 3 && 10#$octet <= 255)) || return 1
    done
    number=$(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
    mask=$(((0xffffffff << (32 - prefix)) & 0xffffffff))
    number=$((number & mask))
    printf '%d.%d.%d.%d/%d\n' \
        "$((number >> 24))" "$(((number >> 16) & 255))" \
        "$(((number >> 8) & 255))" "$((number & 255))" "$prefix"
}

route_snapshot() {
    ip -4 -o route show table main exact "$1" | LC_ALL=C sort
}

configure_route() {
    local cidr="$1" entry current temporary
    entry="${ROUTES_DIR}/${cidr//\//_}"
    current=$(route_snapshot "$cidr")
    mkdir -p "$ROUTES_DIR"
    if [[ ! -d "$entry" ]]; then
        temporary=$(mktemp -d "${ROUTES_DIR}/.pending.XXXXXX")
        printf '%s\n' "$cidr" > "$temporary/cidr"
        route_snapshot "$cidr" > "$temporary/before"
        ip -4 route save table main exact "$cidr" > "$temporary/original"
        mv "$temporary" "$entry"
    elif [[ -f "$entry/after" ]]; then
        if [[ "$current" != "$(cat "$entry/after")" ]]; then
            echo "Route changed outside this script: $cidr; saved state retained" >&2
            return 1
        fi
        # Preserve the first snapshot across repeated routes invocations.
        return 0
    elif [[ "$current" != "$(cat "$entry/before")" ]]; then
        echo "Incomplete route update for $cidr; saved state retained" >&2
        return 1
    fi

    ip -4 route replace "$cidr" via "$NS_IP" dev "$VETH_HOST" mtu 1214
    route_snapshot "$cidr" > "$entry/after.tmp"
    mv "$entry/after.tmp" "$entry/after"
}

restore_routes() {
    [[ -d "$ROUTES_DIR" ]] || return 0
    local entry cidr current before after remaining line
    local -a route_args
    for entry in "$ROUTES_DIR"/*; do
        [[ -d "$entry" ]] || continue
        cidr=$(cat "$entry/cidr") || return 1
        current=$(route_snapshot "$cidr") || return 1
        before=$(cat "$entry/before") || return 1
        if [[ "$current" == "$before" ]]; then
            rm -r "$entry" || return 1
            continue
        fi
        if [[ ! -f "$entry/after" ]]; then
            echo "Incomplete route update for $cidr; saved state retained" >&2
            return 1
        fi
        after=$(cat "$entry/after") || return 1
        remaining=$(LC_ALL=C comm -12 "$entry/before" "$entry/after") || return 1
        # Permit retry after deletion succeeded but restore failed.
        if [[ "$current" != "$after" &&
              ! ( -f "$entry/restoring" && "$current" == "$remaining" ) ]]; then
            echo "Route changed outside this script: $cidr; stop aborted, saved state retained" >&2
            return 1
        fi
        if [[ "$current" == "$after" ]]; then
            LC_ALL=C comm -13 "$entry/before" "$entry/after" > "$entry/added" || return 1
            touch "$entry/restoring" || return 1
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                read -r -a route_args <<< "$line"
                ip -4 route del "${route_args[@]}" || return 1
            done < "$entry/added"
        fi
        ip -4 route restore < "$entry/original" || return 1
        current=$(route_snapshot "$cidr") || return 1
        if [[ "$current" != "$before" ]]; then
            echo "Route restoration incomplete for $cidr; saved state retained" >&2
            return 1
        fi
        rm -r "$entry" || return 1
    done
    # Unpublished snapshots never preceded a route change.
    rm -rf "$ROUTES_DIR"
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
        local cidr
        cidr=$(normalize_cidr "$IPRANGE") || {
            echo "Invalid IPv4 CIDR: $IPRANGE" >&2
            return 1
        }
        IPRANGE="$cidr"
        configure_route "$IPRANGE"
        ip netns exec "$NS" "${IPT[@]}" -t nat -C POSTROUTING \
            -s "${HOST_IP}/32" -d "$IPRANGE" -o "$VETH_NS" \
            -j SNAT --to-source "$vpn_vip" 2>/dev/null || \
        ip netns exec "$NS" "${IPT[@]}" -t nat -I POSTROUTING 1 \
            -s "${HOST_IP}/32" -d "$IPRANGE" -o "$VETH_NS" \
            -j SNAT --to-source "$vpn_vip"
    done
}

stop() {
    # Keep the namespace and veth available if restoration fails.
    restore_routes || return 1

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

# Serialize state updates, including concurrent start/routes/stop invocations.
case "${1:-}" in
    start|routes|stop)
        mkdir -p "$STATE_DIR"
        exec 9>"${STATE_DIR}/.lock"
        flock -x 9
        ;;
esac

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
