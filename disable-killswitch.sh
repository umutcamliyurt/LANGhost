#!/bin/bash
set -euo pipefail

LOG="/tmp/LANGhost.log"
STATE_DIR="/run/LANGhost"

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

[ "$EUID" -eq 0 ] || { echo "[-] Run as root"; exit 1; }

rebind_driver() {
    local iface="$1" bus_id driver_name driver_path bind_path

    bus_id="$(cat "$STATE_DIR/$iface.driver_bus_id" 2>/dev/null || true)"
    driver_name="$(cat "$STATE_DIR/$iface.driver_name" 2>/dev/null || true)"
    driver_path="$(cat "$STATE_DIR/$iface.driver_path" 2>/dev/null || true)"

    [ -n "$bus_id" ] || return 0

    if [ -z "$driver_path" ] && [ -n "$driver_name" ] && [ -d "/sys/bus/pci/drivers/$driver_name" ]; then
        driver_path="/sys/bus/pci/drivers/$driver_name"
    fi
    if [ -z "$driver_path" ] && [ -n "$driver_name" ] && [ -d "/sys/bus/usb/drivers/$driver_name" ]; then
        driver_path="/sys/bus/usb/drivers/$driver_name"
    fi

    bind_path="${driver_path:+$driver_path/bind}"
    if [ -n "$bind_path" ] && [ -w "$bind_path" ]; then
        if printf '%s' "$bus_id" > "$bind_path" 2>/dev/null; then
            echo "[*] Rebound driver for $iface ($driver_name / $bus_id)"
            log "Driver rebind succeeded on $iface: driver=${driver_name:-unknown} bus_id=$bus_id"
            rm -f "$STATE_DIR/$iface.driver_unbound"
            return 0
        fi
        echo "[!] Driver rebind failed for $iface ($driver_name / $bus_id)" >&2
        log "Driver rebind failed on $iface: driver=${driver_name:-unknown} bus_id=$bus_id"
        return 1
    fi

    echo "[!] No writable driver bind path for $iface; rebind may require reboot or manual driver reload" >&2
    log "Driver rebind unavailable on $iface: driver=${driver_name:-unknown} bus_id=$bus_id"
    return 1
}

TARGETS=()
if [ "$#" -gt 0 ]; then
    TARGETS=("$@")
else
    while IFS= read -r dev; do
        [ -n "$dev" ] && TARGETS+=("$dev")
    done < <(ls /sys/class/net 2>/dev/null | grep -E '^(wlan|wlp|wl|eth|enp|en)')
fi

for IFACE in "${TARGETS[@]}"; do
    echo "[*] Releasing kill-switch state on $IFACE"
    tc filter del dev "$IFACE" egress pref 1 >/dev/null 2>&1 || true
    tc filter del dev "$IFACE" ingress pref 1 >/dev/null 2>&1 || true
    tc qdisc del dev "$IFACE" clsact >/dev/null 2>&1 || true
    rebind_driver "$IFACE" || true
    ip link set "$IFACE" up >/dev/null 2>&1 || true
    rm -f \
        "$STATE_DIR/$IFACE.tc" \
        "$STATE_DIR/$IFACE.hostname" \
        "$STATE_DIR/$IFACE.session_seed" \
        "$STATE_DIR/$IFACE.armed" \
        "$STATE_DIR/$IFACE.killswitched" \
        "$STATE_DIR/$IFACE.driver_bus_id" \
        "$STATE_DIR/$IFACE.driver_name" \
        "$STATE_DIR/$IFACE.driver_path"
done

if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock wifi >/dev/null 2>&1 || true
fi

if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager >/dev/null 2>&1 || true
fi

log "Manual override: disable-killswitch invoked for interfaces: ${TARGETS[*]:-auto}"
echo "[+] LANGhost kill-switch disabled for: ${TARGETS[*]:-auto-detected interfaces}"
echo "[*] Reconnect with: nmcli device connect <iface>"
