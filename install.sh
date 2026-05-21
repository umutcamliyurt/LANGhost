#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCHER_DIR="/etc/NetworkManager/dispatcher.d"
DISPATCH_SCRIPT="10-LANGhost"
HOSTNAMES_FILE="hostnames.txt"
CONNECT_SCRIPT="LANGhost-connect.sh"
DISABLE_SCRIPT="disable-killswitch.sh"
NM_CONF_DIR="/etc/NetworkManager/conf.d"
NM_CONF_FILE="$NM_CONF_DIR/90-LANGhost.conf"

[ "$EUID" -eq 0 ] || { echo "[-] Run as root"; exit 1; }
command -v nmcli >/dev/null 2>&1 || { echo "[-] nmcli not found"; exit 1; }
command -v tc >/dev/null 2>&1 || { echo "[-] tc not found (install iproute2)"; exit 1; }

install -d -m 755 "$DISPATCHER_DIR" "$NM_CONF_DIR" /usr/local/sbin

install -m 755 "$SCRIPT_DIR/$DISPATCH_SCRIPT" "$DISPATCHER_DIR/$DISPATCH_SCRIPT"
install -m 644 "$SCRIPT_DIR/$HOSTNAMES_FILE" "$DISPATCHER_DIR/$HOSTNAMES_FILE"
install -m 755 "$SCRIPT_DIR/$CONNECT_SCRIPT" /usr/local/sbin/LANGhost-connect
install -m 755 "$SCRIPT_DIR/$DISABLE_SCRIPT" /usr/local/sbin/LANGhost-disable-killswitch

cat > "$NM_CONF_FILE" <<CONF
[device]
wifi.scan-rand-mac-address=yes

[connection]
ipv6.dhcp-send-hostname=false
CONF

echo "[*] Reloading NetworkManager..."
systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager

echo "[+] Installed. Use the wrapper for fail-closed connects:"
echo "    sudo LANGhost-connect <connection-name-or-uuid> [iface]"
echo "[*] Emergency recovery:"
echo "    sudo LANGhost-disable-killswitch [iface]"
echo "[*] Logs:"
echo "    cat /tmp/LANGhost.log"
