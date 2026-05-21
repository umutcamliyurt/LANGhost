<div align="center">

<br/>

# LANGhost
## Local area network anonymity hardening tool for Linux

<br/>

<img src="banner.png" width="500">

<br />

</div>

## Description

LANGhost is a Linux anonymity hardening layer for systems managed by NetworkManager. It minimizes identity leakage across multiple network surfaces during connection setup, enforces privacy-focused connection configurations, and implements a fail‑closed mechanism that terminates or isolates connectivity when runtime checks detect unsafe conditions.

## What it does
- Randomizes MAC policy before activation.
- Assigns a randomized DHCP hostname before activation.
- Applies a per-activation identity seed for NetworkManager-derived identifiers.
- Hardens DHCP identity behavior.
- Enables stronger IPv6 privacy behavior and stable-privacy address generation.
- Disables local discovery features that can expose system identity on managed links.
- Quarantines interfaces with `tc` drop filters during setup.
- Verifies runtime state after activation and triggers a kill switch on failure.

## Privacy hardening scope

The current design focuses on reducing exposure from:
- hardware MAC reuse on managed links
- DHCP hostname leakage
- DHCP client identifier reuse and lease pinning via stable IAID
- IPv6 interface/address persistence
- local discovery and neighbor-identification surfaces such as mDNS, LLMNR, and LLDP

## Components
- `/usr/local/sbin/LANGhost-connect` — wrapper that applies privacy settings, quarantines the interface, activates the connection, and verifies post-activation state.
- `/etc/NetworkManager/dispatcher.d/10-LANGhost` — dispatcher verifier that checks the live connection and triggers fail-closed containment if validation fails.
- `/usr/local/sbin/LANGhost-disable-killswitch` — recovery helper that removes quarantine and attempts to restore interface usability.
- `/etc/NetworkManager/dispatcher.d/hostnames.txt` — hostname pool used for DHCP hostname randomization.
- `/etc/NetworkManager/conf.d/90-LANGhost.conf` — NetworkManager configuration installed by the project.

## Privacy controls applied
When LANGhost prepares a managed connection, it configures NetworkManager to apply privacy-oriented settings such as:
- randomized cloned MAC behavior for supported Wi-Fi and Ethernet profiles
- randomized DHCP hostname selection
- rotating connection identity seed for derived identifiers
- MAC-derived DHCP client identifier so the client-id follows the already-randomized MAC
- per-session random DHCP IAID for both IPv4 and IPv6 to prevent lease pinning
- IPv6 stable-privacy address generation and temporary address preference
- disabled mDNS, LLMNR, and LLDP on the protected connection

## Benefits
- Reduces identifier leakage during connection startup.
- Lowers the chance of accidental hardware identity reuse.
- Hardens more than one identifier surface instead of relying on MAC randomization alone.
- Prevents DHCP lease pinning by randomizing both the DHCP hostname and IAID each session.
- Adds runtime verification so privacy settings are checked instead of merely requested.
- Fails closed to limit unsafe operation when expectations are not met.
- Standardizes repeatable, operator-visible hardening with logging and recovery.

## Kill switch behavior
If runtime verification fails, LANGhost attempts to fail closed by doing all of the following:
- applying `tc` ingress and egress drop filters
- disconnecting the device in NetworkManager
- bringing the interface down
- blocking Wi-Fi with `rfkill` when available
- unbinding the interface from its kernel driver through sysfs when supported

This is intended to contain unsafe connections quickly and prevent continued operation with an identity state that violated policy.

## Installation
Run:
```bash
sudo bash install.sh
```

This installs:
- `/etc/NetworkManager/dispatcher.d/10-LANGhost`
- `/etc/NetworkManager/dispatcher.d/hostnames.txt`
- `/usr/local/sbin/LANGhost-connect`
- `/usr/local/sbin/LANGhost-disable-killswitch`
- `/etc/NetworkManager/conf.d/90-LANGhost.conf`

The installer also enables randomized Wi-Fi scan MAC behavior and disables IPv6 DHCP hostname sending globally.

## Requirements
Required:
- Linux with NetworkManager
- `nmcli`
- `tc` from `iproute2`
- root privileges

Recommended:
- `ethtool` for validating permanent vs. live MAC state
- `rfkill` on Wi-Fi systems

## Usage
Preferred:
```bash
sudo LANGhost-connect <connection-name-or-uuid>
```

Also supported:
```bash
sudo LANGhost-connect
sudo LANGhost-connect --select
sudo LANGhost-connect <connection-name-or-uuid> <iface>
```

## Logs & diagnostics
Logs:
```bash
/tmp/LANGhost.log
```

Diagnostics examples:
```bash
cat /tmp/LANGhost.log
sudo tc -s qdisc show dev <iface>
sudo tc -s filter show dev <iface> ingress
sudo tc -s filter show dev <iface> egress
```

## Recovery
Disable the kill switch:
```bash
sudo LANGhost-disable-killswitch
```

Or for a specific interface:
```bash
sudo LANGhost-disable-killswitch wlp2s0
```

## Limitations
LANGhost improves anonymity hygiene on managed Linux connections, but it does not and cannot guarantee perfect anonymity.

Important limits include:
- Some hardware, firmware, driver, or radio-level behavior may occur outside the project’s control.
- Out-of-band management activity or lower-level wireless behavior may still expose identifiers.
- Traffic outside the protected NetworkManager-managed interface is not covered.
- Application-layer behavior, DNS choices, browser fingerprinting, and traffic analysis remain separate problems.
- Some privacy-oriented settings may reduce compatibility on networks that expect local discovery features or specific DHCP behavior.

The accurate claim is that LANGhost is a network anonymity hardening layer for Linux, not a formal anonymity guarantee.

## Best practices
- Use `LANGhost-connect` instead of raw `nmcli connection up` whenever fail-closed behavior matters.
- Test recovery on your hardware before relying on the setup remotely.
- Inspect `/tmp/LANGhost.log` during rollout.
- Validate behavior on both your Wi-Fi and Ethernet environments.
- Combine LANGhost with trusted DNS, endpoint hardening, and traffic-layer privacy controls for stronger overall privacy.

## Uninstallation
```bash
sudo rm -f /etc/NetworkManager/dispatcher.d/10-LANGhost \
/etc/NetworkManager/dispatcher.d/hostnames.txt \
/usr/local/sbin/LANGhost-connect \
/usr/local/sbin/LANGhost-disable-killswitch \
/etc/NetworkManager/conf.d/90-LANGhost.conf
sudo systemctl restart NetworkManager
```

## License

Distributed under the **MIT License**. See [`LICENSE`](LICENSE) for full terms.