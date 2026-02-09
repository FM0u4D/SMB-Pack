#!/usr/bin/env bash
set -euo pipefail

# set-ufw-rules.sh
# Purpose: apply ONLY the SMB-over-WireGuard firewall rule(s), reload UFW, then show status.
# Usage:
#   sudo bash ./server/set-ufw-rules.sh
# Optional env vars:
#   WG_IFACE=wg0-client
#   WG_SUBNET_V4=10.8.0.0/24   (if set, rule becomes "from subnet" instead of "Anywhere")
#   ENABLE_V6=1                (add the IPv6 rule too; requires UFW IPv6 enabled)

WG_IFACE="${WG_IFACE:-wg0-client}"
WG_SUBNET_V4="${WG_SUBNET_V4:-}"   # leave empty to match your current "Anywhere" output
ENABLE_V6="${ENABLE_V6:-1}"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "❌ Run as root (use: sudo bash $0)" >&2
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ufw_ipv6_enabled() {
  # UFW typically stores IPv6=yes/no in /etc/default/ufw
  if [[ -f /etc/default/ufw ]]; then
    grep -qi '^IPV6=yes' /etc/default/ufw
  else
    return 1
  fi
}

main() {
  need_root

  if ! have_cmd ufw; then
    echo "❌ ufw not found. Install it first: apt install ufw" >&2
    exit 1
  fi

  echo "▶ Applying UFW rules for: SMB over WireGuard"
  echo "   Interface: ${WG_IFACE}"
  if [[ -n "${WG_SUBNET_V4}" ]]; then
    echo "   Source v4: ${WG_SUBNET_V4} (tighter than 'Anywhere')"
  else
    echo "   Source v4: Anywhere (matches your current output)"
  fi

  # Make sure UFW is enabled (idempotent; won't break if already active)
  ufw --force enable >/dev/null

  # 1) IPv4 rule (match your current style: "445/tcp on wg0-client ALLOW IN Anywhere")
  if [[ -n "${WG_SUBNET_V4}" ]]; then
    ufw allow in on "${WG_IFACE}" from "${WG_SUBNET_V4}" to any port 445 proto tcp comment "SMB over WireGuard"
  else
    ufw allow in on "${WG_IFACE}" to any port 445 proto tcp comment "SMB over WireGuard"
  fi

  # 2) IPv6 rule (optional; only meaningful if UFW IPv6 is enabled)
  if [[ "${ENABLE_V6}" == "1" ]]; then
    if ufw_ipv6_enabled; then
      # If you want a tight IPv6 source rule, set it in the future (WG_SUBNET_V6) and mirror logic.
      ufw allow in on "${WG_IFACE}" to any port 445 proto tcp comment "SMB over WireGuard (v6)"
    else
      echo "⚠ Skipping IPv6 rule: UFW IPv6 is not enabled (IPV6=yes in /etc/default/ufw)."
    fi
  fi

  echo "▶ Reloading UFW..."
  ufw reload >/dev/null

  echo "✅ Done. Current firewall status:"
  ufw status verbose
}

main "$@"
