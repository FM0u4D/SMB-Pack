#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# SMB Lab Validation Script
# =========================
# Verifies (server-side only):
#  - Samba config parses (testparm)
#  - smbd is listening on TCP/445
#  - local functional test via smbclient (localhost)
#  - firewall posture visibility (ufw; non-enforcing)
#
# Exit code contract (shared with run-demo.sh):
#   0 = healthy
#   1 = server config invalid
#   2 = security boundary violation (visibility only here)
#   3 = server functional failure (local smbclient)
#
# Usage:
#   ./server/validate.sh
#
# Optional env overrides:
#   SMB_SHARE="Public"
#   SMB_USER="adminsmb"
#   SMB_HOST="127.0.0.1"
#   SMBCLIENT_PASS="password"   (optional; prompts if unset)

# ---- exit codes -----------------------------------------------------------
EC_OK=0
EC_CONFIG=1
EC_BOUNDARY=2
EC_FUNCTIONAL=3

EXIT_CODE=$EC_OK
PASS_CNT=0
FAIL_CNT=0

# ---- defaults -------------------------------------------------------------
SMB_SHARE="${SMB_SHARE:-Public}"
SMB_USER="${SMB_USER:-adminsmb}"
SMB_HOST="${SMB_HOST:-127.0.0.1}"

# ---- helpers --------------------------------------------------------------
bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "• %s\n" "$*"; }
ok()   { printf "✅ %s\n" "$*"; PASS_CNT=$((PASS_CNT+1)); }

bad() {
  local msg="$1"
  local code="${2:-$EC_CONFIG}"

  printf "❌ %s\n" "$msg"
  FAIL_CNT=$((FAIL_CNT+1))

  # Preserve most severe failure
  if (( code > EXIT_CODE )); then
    EXIT_CODE="$code"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    bad "Missing dependency: $1" "$EC_CONFIG"
    return 1
  }
  ok "$1 present"
  return 0
}

run() {
  "$@" >/dev/null 2>&1
}

maybe_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

section() {
  printf "\n"
  bold "== $* =="
}

summary() {
  printf "\n"
  bold "== Summary =="
  info "Passed checks: $PASS_CNT"
  info "Failed checks: $FAIL_CNT"

  if [[ "$FAIL_CNT" -eq 0 ]]; then
    ok "Validation gate: GREEN"
    exit "$EC_OK"
  else
    bold "Validation gate: RED"
    exit "$EXIT_CODE"
  fi
}

trap summary EXIT

# =========================
# 1) Dependencies
# =========================
section "1) Dependencies"
need_cmd testparm || true
need_cmd ss || true
need_cmd smbclient || true
command -v ufw >/dev/null 2>&1 \
  && ok "ufw present" \
  || info "ufw not installed (firewall visibility skipped)"

# =========================
# 2) Samba config parses
# =========================
section "2) Samba config parses"
if run testparm -s; then
  ok "testparm -s parsed smb.conf (no fatal errors)"
else
  bad "testparm -s failed (smb.conf parse error)" "$EC_CONFIG"
  info "Run: sudo testparm -s  (to see exact error)"
fi

# =========================
# 3) smbd listening on 445
# =========================
section "3) SMB service listening (TCP/445)"
if ss -lntp | grep -qE '[:.]445\b'; then
  ok "Port 445 is listening"
  ss -lntp | awk 'NR==1 || /:445\b/' || true
else
  bad "Port 445 not listening (smbd down or misbound)" "$EC_CONFIG"
  info "Run: sudo systemctl status smbd --no-pager"
fi

# =========================
# 4) Local SMB functional test
# =========================
section "4) Local SMB functional test (localhost)"

if [[ -n "${SMBCLIENT_PASS:-}" ]]; then
  if run bash -c \
    "printf '%s\n' \"$SMBCLIENT_PASS\" | smbclient \"//${SMB_HOST}/${SMB_SHARE}\" -U \"${SMB_USER}\" -c 'ls'"; then
    ok "smbclient localhost test succeeded (ls)"
  else
    bad "smbclient localhost test failed (functional failure)" "$EC_FUNCTIONAL"
    info "Try manually: smbclient //127.0.0.1/${SMB_SHARE} -U ${SMB_USER}"
  fi
else
  info "SMBCLIENT_PASS not provided — prompting interactively."
  if smbclient "//${SMB_HOST}/${SMB_SHARE}" -U "${SMB_USER}" -c "ls"; then
    ok "smbclient localhost test succeeded (ls)"
  else
    bad "smbclient localhost test failed (functional failure)" "$EC_FUNCTIONAL"
    info "Check: share exists, user exists, traversal bits, ownership."
  fi
fi

# =========================
# 5) Firewall posture (visibility)
# =========================
section "5) Firewall posture (visibility only)"

if command -v ufw >/dev/null 2>&1; then
  info "UFW status (should reflect VPN-only intent):"
  maybe_sudo ufw status verbose || true
  ok "UFW status displayed"
else
  info "Skipping UFW (not installed)."
fi

# =========================
# 6) Permissions visibility
# =========================
section "6) Permissions visibility (non-enforcing)"

for p in /srv /srv/samba /srv/samba/public /srv/samba/direction; do
  if [[ -e "$p" ]]; then
    info "ls -ld $p"
    ls -ld "$p" || true
  else
    info "Path missing (ok if unused): $p"
  fi
done
ok "Permissions visibility printed"
