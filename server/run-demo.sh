#!/usr/bin/env bash
# Secure SMB over WireGuard — server-side validation entrypoint
#
# Exit codes (shared contract):
#   0 = healthy
#   1 = server config invalid
#   2 = 445 not scoped to VPN (security regression)
#   3 = local smbclient fails (server functional fail)

set -u -o pipefail

# ---- exit codes -----------------------------------------------------------
EC_OK=0
EC_CONFIG=1
EC_BOUNDARY=2
EC_FUNCTIONAL=3

# ---- configurable defaults -----------------------------------------------
SMB_SHARE="${SMB_SHARE:-Public}"
SMB_USER="${SMB_USER:-adminsmb}"
SMB_HOST="${SMB_HOST:-127.0.0.1}"
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0/24}"

# ---- helpers --------------------------------------------------------------
ok()   { printf "✅ %s\n" "$*"; }
fail() { printf "❌ %s\n" "$1" >&2; exit "$2"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing dependency: $1" "$EC_CONFIG"
}

echo "== Secure SMB over WireGuard :: Server-side demo =="
echo "Scope: Samba config, service state, local SMB, VPN boundary"
echo

# =========================
# Dependency checks
# =========================
for c in testparm ss smbclient; do
  need_cmd "$c"
done

if ! command -v ufw >/dev/null 2>&1; then
  fail "ufw not installed — cannot verify VPN-only boundary enforcement" "$EC_BOUNDARY"
fi

# =========================
# 1) Samba config validity
# =========================
echo "-- Checking Samba configuration --"
if ! testparm -s >/dev/null 2>&1; then
  fail "Samba configuration invalid (testparm failed)" "$EC_CONFIG"
fi
ok "Samba configuration parses cleanly"

# =========================
# 2) smbd listening state
# =========================
echo
echo "-- Checking smbd listening on TCP/445 --"
if ! ss -lntp | grep -qE '[:.]445\b'; then
  fail "smbd is not listening on TCP/445" "$EC_CONFIG"
fi
ok "smbd is listening on TCP/445"

# =========================
# 3) VPN boundary enforcement
# =========================
echo
echo "-- Checking VPN-only boundary for TCP/445 --"

if ! ufw status verbose | grep -q "Status: active"; then
  fail "UFW is not active — boundary cannot be trusted" "$EC_BOUNDARY"
fi

if ufw status verbose | grep -qE "445/tcp.*ALLOW.*Anywhere"; then
  fail "TCP/445 is allowed from Anywhere (security regression)" "$EC_BOUNDARY"
fi

if ! ufw status verbose | grep -qE "445/tcp.*ALLOW.*${VPN_SUBNET}"; then
  fail "No explicit ALLOW for TCP/445 from VPN subnet (${VPN_SUBNET})" "$EC_BOUNDARY"
fi

ok "TCP/445 correctly scoped to VPN boundary"

# =========================
# 4) Local SMB functional test
# =========================
echo
echo "-- Running local SMB functional test --"

if [[ -n "${SMBCLIENT_PASS:-}" ]]; then
  if ! bash -c \
    "printf '%s\n' \"$SMBCLIENT_PASS\" | smbclient \"//${SMB_HOST}/${SMB_SHARE}\" -U \"${SMB_USER}\" -c 'ls'" \
    >/dev/null 2>&1; then
    fail "Local smbclient test failed (server functional failure)" "$EC_FUNCTIONAL"
  fi
else
  echo "• SMBCLIENT_PASS not set — interactive prompt expected"
  if ! smbclient "//${SMB_HOST}/${SMB_SHARE}" -U "${SMB_USER}" -c "ls"; then
    fail "Local smbclient test failed (server functional failure)" "$EC_FUNCTIONAL"
  fi
fi

ok "Local SMB access works (server functional)"

# =========================
# Success
# =========================
echo
ok "Server is healthy and ready for client-side validation"
exit "$EC_OK"
