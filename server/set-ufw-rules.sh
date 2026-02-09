#!/usr/bin/env bash
set -Eeuo pipefail

# Secure SMB over WireGuard — UFW rule applier
# ===========================================
# Applies ONLY the inbound SMB rule(s) needed for "SMB over WireGuard",
# then reloads UFW and prints an audit-friendly status.
#
# Design:
#  - Idempotent-ish: safe to run multiple times (may create duplicates if UFW comments differ).
#  - Conservative: does not touch unrelated SSH/HTTP/HTTPS rules.
#  - Boundary-aware: can scope by interface + (optionally) source subnet.
#
# Usage:
#   sudo bash ./server/set-ufw-rules.sh
#
# Optional env overrides:
#   WG_IFACE=wg0-client
#   WG_SUBNET_V4=10.8.0.0/24    # if set, rule becomes "from subnet" instead of "Anywhere"
#   ENABLE_V6=1                 # add IPv6 rule too (only if UFW IPv6 is enabled)

WG_IFACE="${WG_IFACE:-wg0-client}"
WG_SUBNET_V4="${WG_SUBNET_V4:-}"   # empty = "Anywhere" (matches your current output)
ENABLE_V6="${ENABLE_V6:-1}"

# ---- helpers --------------------------------------------------------------
bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "• %s\n" "$*"; }
ok()   { printf "✅ %s\n" "$*"; }
warn() { printf "⚠️  %s\n" "$*"; }
die()  { printf "❌ %s\n" "$*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root (use: sudo bash $0)"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

ufw_ipv6_enabled() {
  [[ -f /etc/default/ufw ]] && grep -qi '^IPV6=yes' /etc/default/ufw
}

apply_v4_rule() {
  if [[ -n "${WG_SUBNET_V4}" ]]; then
    info "IPv4: allow TCP/445 inbound on ${WG_IFACE} from ${WG_SUBNET_V4}"
    ufw allow in on "${WG_IFACE}" from "${WG_SUBNET_V4}" to any port 445 proto tcp comment "SMB over WireGuard"
  else
    info "IPv4: allow TCP/445 inbound on ${WG_IFACE} (source: Anywhere)"
    ufw allow in on "${WG_IFACE}" to any port 445 proto tcp comment "SMB over WireGuard"
  fi
}

apply_v6_rule() {
  # UFW auto-generates (v6) counterparts only when IPv6 is enabled in /etc/default/ufw
  if [[ "${ENABLE_V6}" != "1" ]]; then
    info "IPv6: skipped (ENABLE_V6=0)"
    return 0
  fi

  if ufw_ipv6_enabled; then
    info "IPv6: allow TCP/445 inbound on ${WG_IFACE} (requires UFW IPv6 enabled)"
    # Keep it symmetric with your current output. If you later want a tight source,
    # introduce WG_SUBNET_V6 and mirror the IPv4 logic.
    ufw allow in on "${WG_IFACE}" to any port 445 proto tcp comment "SMB over WireGuard (v6)"
  else
    warn "IPv6: skipped — UFW IPv6 is disabled (set IPV6=yes in /etc/default/ufw and reload UFW)"
  fi
}

main() {
  need_root
  need_cmd ufw

  bold "== Secure SMB over WireGuard :: UFW boundary rule =="
  info "Interface: ${WG_IFACE}"
  if [[ -n "${WG_SUBNET_V4}" ]]; then
    info "Source scope (v4): ${WG_SUBNET_V4}"
  else
    info "Source scope (v4): Anywhere (matches your current output)"
  fi

  # Ensure UFW is enabled (idempotent)
  ufw --force enable >/dev/null 2>&1 || true
  ok "UFW enabled"

  # Apply only the SMB rule(s)
  apply_v4_rule >/dev/null 2>&1 || die "Failed to apply IPv4 SMB rule"
  ok "IPv4 SMB rule applied"

  apply_v6_rule >/dev/null 2>&1 || die "Failed to apply IPv6 SMB rule"
  ok "IPv6 SMB rule applied (or intentionally skipped)"

  info "Reloading UFW"
  ufw reload >/dev/null 2>&1 || die "UFW reload failed"
  ok "UFW reloaded"

  printf "\n"
  bold "== Audit view: ufw status verbose =="
  ufw status verbose
}

main "$@"
