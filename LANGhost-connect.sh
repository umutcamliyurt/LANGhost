#!/bin/bash
set -euo pipefail

DISPATCHER_HOSTNAMES="/etc/NetworkManager/dispatcher.d/hostnames.txt"
LOG="/tmp/LANGhost.log"
STATE_DIR="/run/LANGhost"
mkdir -p "$STATE_DIR"

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }
die() { echo "[-] $*" >&2; log "ERROR: $*"; exit 1; }

[ "$EUID" -eq 0 ] || die "Run as root"
command -v nmcli >/dev/null 2>&1 || die "nmcli not found"
command -v tc >/dev/null 2>&1 || die "tc not found"

select_connection() {
    local entries line idx name uuid type device active choice selected
    mapfile -t entries < <(
        nmcli -t -f UUID,NAME,TYPE,DEVICE connection show 2>/dev/null | awk -F: '
            BEGIN { OFS="|" }
            $3=="802-11-wireless" || $3=="802-3-ethernet" || $3=="wifi" || $3=="ethernet" {
                active = ($4 != "--" && $4 != "") ? "active on " $4 : "inactive"
                print $1, $2, $3, $4, active
            }
        '
    )

    [ ${#entries[@]} -gt 0 ] || die "No supported NetworkManager connections found"

    echo "[*] Select a NetworkManager connection:" >&2
    for idx in "${!entries[@]}"; do
        IFS='|' read -r uuid name type device active <<< "${entries[$idx]}"
        printf '  [%d] %s (%s, UUID %s, %s)\n' "$((idx+1))" "$name" "$type" "$uuid" "$active" >&2
    done

    while true; do
        printf 'Enter selection number: ' >&2
        read -r choice
        [[ "$choice" =~ ^[0-9]+$ ]] || { echo "[-] Enter a number" >&2; continue; }
        if [ "$choice" -ge 1 ] && [ "$choice" -le "${#entries[@]}" ]; then
            selected="${entries[$((choice-1))]}"
            IFS='|' read -r uuid name type device active <<< "$selected"
            echo "$uuid"
            return 0
        fi
        echo "[-] Choice out of range" >&2
    done
}

persist_driver_binding() {
    local dev_path driver_path bus_id driver_name
    dev_path="$(readlink -f "/sys/class/net/$IFACE/device" 2>/dev/null || true)"
    [ -n "$dev_path" ] || return 0

    driver_path="$(readlink -f "$dev_path/driver" 2>/dev/null || true)"
    [ -n "$driver_path" ] || return 0

    bus_id="$(basename "$dev_path")"
    driver_name="$(basename "$driver_path")"

    printf '%s\n' "$bus_id" > "$STATE_DIR/$IFACE.driver_bus_id"
    printf '%s\n' "$driver_name" > "$STATE_DIR/$IFACE.driver_name"
    printf '%s\n' "$driver_path" > "$STATE_DIR/$IFACE.driver_path"
}

engage_driver_killswitch() {
    local dev_path driver_path bus_id driver_name unbind_path
    dev_path="$(readlink -f "/sys/class/net/$IFACE/device" 2>/dev/null || true)"
    [ -n "$dev_path" ] || { log "Driver kill-switch unavailable on $IFACE: no sysfs device path"; return 0; }

    driver_path="$(readlink -f "$dev_path/driver" 2>/dev/null || true)"
    [ -n "$driver_path" ] || { log "Driver kill-switch unavailable on $IFACE: no bound driver"; return 0; }

    bus_id="$(basename "$dev_path")"
    driver_name="$(basename "$driver_path")"
    unbind_path="$driver_path/unbind"

    persist_driver_binding

    if [ -w "$unbind_path" ]; then
        if printf '%s' "$bus_id" > "$unbind_path" 2>/dev/null; then
            echo 1 > "$STATE_DIR/$IFACE.driver_unbound"
            log "Driver kill-switch engaged on $IFACE: driver=$driver_name bus_id=$bus_id"
            return 0
        fi
        log "Driver kill-switch write failed on $IFACE: driver=$driver_name bus_id=$bus_id"
        return 1
    fi

    log "Driver kill-switch unavailable on $IFACE: $unbind_path not writable"
    return 1
}

TARGET="${1:-}"
PIN_IFACE="${2:-}"

if [ -z "$TARGET" ] || [ "$TARGET" = "--select" ] || [ "$TARGET" = "-s" ]; then
    UUID="$(select_connection)"
else
    UUID="$(nmcli -t -f UUID,NAME connection show 2>/dev/null | awk -F: -v t="$TARGET" '$1==t || $2==t {print $1; exit}')"
fi
[ -n "$UUID" ] || die "Connection '${TARGET:-selection}' not found"

CON_NAME="$(nmcli -g connection.id connection show "$UUID" 2>/dev/null || true)"
CON_TYPE="$(nmcli -g connection.type connection show "$UUID" 2>/dev/null || true)"
case "$CON_TYPE" in
    802-11-wireless|wifi|802-3-ethernet|ethernet) ;;
    *) die "Unsupported connection type: ${CON_TYPE:-unknown}" ;;
esac

IFACE="$PIN_IFACE"
if [ -z "$IFACE" ]; then
    IFACE="$(nmcli -g GENERAL.DEVICES connection show "$UUID" 2>/dev/null | head -n1)"
fi
if [ -z "$IFACE" ] || [ "$IFACE" = "--" ]; then
    IFACE="$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | awk -F: -v t="$CON_TYPE" '
        ($2=="wifi" && (t=="802-11-wireless" || t=="wifi") && $3!="unavailable") {print $1; exit}
        ($2=="ethernet" && (t=="802-3-ethernet" || t=="ethernet") && $3!="unavailable") {print $1; exit}
    ')"
fi
[ -n "$IFACE" ] || die "Could not resolve interface for $UUID; pass iface as second argument"

[ -f "$DISPATCHER_HOSTNAMES" ] || die "Missing $DISPATCHER_HOSTNAMES"
HOSTNAME="$(grep -v '^#' "$DISPATCHER_HOSTNAMES" | grep -v '^$' | shuf -n1)"
[ -n "$HOSTNAME" ] || die "No usable hostname entries found"

SESSION_SEED="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
[ -n "$SESSION_SEED" ] || SESSION_SEED="$(date +%s)-$$-$RANDOM"
SESSION_IAID="$(printf '%08x' $((RANDOM * 65536 + RANDOM)))"
printf '%s\n' "$HOSTNAME" > "$STATE_DIR/$IFACE.hostname"
printf '%s\n' "$SESSION_SEED" > "$STATE_DIR/$IFACE.session_seed"
printf '%s\n' "$SESSION_IAID" > "$STATE_DIR/$IFACE.session_iaid"
: > "$STATE_DIR/$IFACE.armed"
rm -f "$STATE_DIR/$IFACE.killswitched"

quarantine() {
    tc qdisc replace dev "$IFACE" clsact >/dev/null 2>&1 || true
    tc filter replace dev "$IFACE" egress pref 1 matchall action drop >/dev/null 2>&1 || true
    tc filter replace dev "$IFACE" ingress pref 1 matchall action drop >/dev/null 2>&1 || true
    log "Quarantine applied on $IFACE"
}

release() {
    tc filter del dev "$IFACE" egress pref 1 >/dev/null 2>&1 || true
    tc filter del dev "$IFACE" ingress pref 1 >/dev/null 2>&1 || true
    tc qdisc del dev "$IFACE" clsact >/dev/null 2>&1 || true
    rm -f "$STATE_DIR/$IFACE.tc"
    log "Quarantine released on $IFACE"
}

fail_closed() {
    log "FAIL-CLOSED during connect on $IFACE: $*"
    quarantine
    nmcli device disconnect "$IFACE" >/dev/null 2>&1 || true
    ip link set "$IFACE" down >/dev/null 2>&1 || true
    if command -v rfkill >/dev/null 2>&1 && [[ "$IFACE" == wl* || "$IFACE" == wlan* ]]; then
        rfkill block wifi >/dev/null 2>&1 || true
    fi
    engage_driver_killswitch || true
    echo "[-] $*" >&2
    echo "[*] Recovery: sudo /usr/local/sbin/LANGhost-disable-killswitch $IFACE" >&2
    exit 1
}

get_prop() {
    local key="$1"
    nmcli -g "$key" connection show "$UUID" 2>/dev/null || true
}

value_in() {
    local value="$1"; shift || true
    local candidate
    for candidate in "$@"; do
        [ "$value" = "$candidate" ] && return 0
    done
    return 1
}

verify() {
    local current_mac perm_mac live_hostname stable_id llmnr mdns lldp
    local ip4_client_id ip4_iaid ip6_addr_gen ip6_privacy ip6_duid ip6_iaid

    current_mac="$(cat /sys/class/net/"$IFACE"/address 2>/dev/null || true)"
    [ -n "$current_mac" ] || fail_closed "Unable to read current MAC"

    if command -v ethtool >/dev/null 2>&1; then
        perm_mac="$(ethtool -P "$IFACE" 2>/dev/null | awk '/Permanent address:/ {print tolower($3)}')"
        if [ -n "$perm_mac" ] && [ "${current_mac,,}" = "$perm_mac" ]; then
            fail_closed "Live MAC equals permanent MAC ($current_mac)"
        fi
    fi

    live_hostname="$(get_prop ipv4.dhcp-hostname)"
    [ "$live_hostname" = "$HOSTNAME" ] || fail_closed "Profile DHCP hostname mismatch ($live_hostname != $HOSTNAME)"

    stable_id="$(get_prop connection.stable-id)"
    [ "$stable_id" = "$SESSION_SEED" ] || fail_closed "Stable identity seed mismatch ($stable_id != $SESSION_SEED)"

    ip4_client_id="$(get_prop ipv4.dhcp-client-id)"
    value_in "$ip4_client_id" mac || fail_closed "IPv4 DHCP client-id policy is not mac ($ip4_client_id)"

    ip4_iaid="$(get_prop ipv4.dhcp-iaid)"
    [ -n "$ip4_iaid" ] || fail_closed "IPv4 DHCP IAID is not set"

    ip6_addr_gen="$(get_prop ipv6.addr-gen-mode)"
    value_in "$ip6_addr_gen" stable-privacy 1 || fail_closed "IPv6 addr-gen-mode is not stable-privacy ($ip6_addr_gen)"

    ip6_privacy="$(get_prop ipv6.ip6-privacy)"
    value_in "$ip6_privacy" 2 prefer-temp-addr || fail_closed "IPv6 privacy extensions are not set to prefer temporary addresses ($ip6_privacy)"

    ip6_duid="$(get_prop ipv6.dhcp-duid)"
    value_in "$ip6_duid" stable-uuid || fail_closed "IPv6 DHCP DUID policy is not stable-uuid ($ip6_duid)"

    ip6_iaid="$(get_prop ipv6.dhcp-iaid)"
    [ -n "$ip6_iaid" ] || fail_closed "IPv6 DHCP IAID is not set"

    llmnr="$(get_prop connection.llmnr)"
    value_in "$llmnr" 0 no || fail_closed "LLMNR is not disabled ($llmnr)"

    mdns="$(get_prop connection.mdns)"
    value_in "$mdns" 0 no || fail_closed "mDNS is not disabled ($mdns)"

    lldp="$(get_prop connection.lldp)"
    value_in "$lldp" 0 disable || fail_closed "LLDP is not disabled ($lldp)"
}

log "Preparing safe connect: UUID=$UUID NAME=${CON_NAME:-unknown} IFACE=$IFACE TYPE=$CON_TYPE HOSTNAME=$HOSTNAME SESSION_SEED=$SESSION_SEED SESSION_IAID=$SESSION_IAID"
echo "[*] Connecting profile: ${CON_NAME:-$UUID}"
echo "[*] Interface: $IFACE"
echo "[*] Random DHCP hostname: $HOSTNAME"
echo "[*] Session identity seed: $SESSION_SEED"
echo "[*] Session DHCP IAID: $SESSION_IAID"
persist_driver_binding
quarantine
nmcli device disconnect "$IFACE" >/dev/null 2>&1 || true
ip link set "$IFACE" down >/dev/null 2>&1 || true

case "$CON_TYPE" in
    802-11-wireless|wifi)
        nmcli connection modify "$UUID" 802-11-wireless.cloned-mac-address random
        ;;
    802-3-ethernet|ethernet)
        nmcli connection modify "$UUID" 802-3-ethernet.cloned-mac-address random
        ;;
esac
nmcli connection modify "$UUID" connection.stable-id "$SESSION_SEED"
nmcli connection modify "$UUID" connection.llmnr no
nmcli connection modify "$UUID" connection.mdns no
nmcli connection modify "$UUID" connection.lldp disable
nmcli connection modify "$UUID" ipv4.dhcp-send-hostname yes
nmcli connection modify "$UUID" ipv4.dhcp-hostname "$HOSTNAME"
nmcli connection modify "$UUID" ipv4.dhcp-client-id mac
nmcli connection modify "$UUID" ipv4.dhcp-iaid "$SESSION_IAID"
nmcli connection modify "$UUID" ipv6.addr-gen-mode stable-privacy
nmcli connection modify "$UUID" ipv6.ip6-privacy 2
nmcli connection modify "$UUID" ipv6.dhcp-send-hostname no
nmcli connection modify "$UUID" ipv6.dhcp-duid stable-uuid
nmcli connection modify "$UUID" ipv6.dhcp-iaid "$SESSION_IAID"

ip link set "$IFACE" up >/dev/null 2>&1 || true
release

if ! nmcli connection up "$UUID" ifname "$IFACE"; then
    fail_closed "Connection activation failed"
fi

verify
log "Safe connect complete on $IFACE: connection=${CON_NAME:-$UUID} hostname=$HOSTNAME"
echo "[+] Connected with randomized identity"
echo "    connection: ${CON_NAME:-$UUID}"
echo "    iface:      $IFACE"
echo "    uuid:       $UUID"
echo "    host:       $HOSTNAME"