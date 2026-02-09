#!/usr/bin/env bash
set -Eeuo pipefail

# ==================================
# Samba Reset & Service Health Script
# ==================================
# Purpose:
#   Bring Samba back to a known good runtime state after changes.
#   This script is intentionally conservative:
#     - It does NOT rewrite smb.conf
#     - It does NOT change firewall rules
#     - It resets the services, then proves the server is listening
#       and (optionally) functional locally.
#
# Exit code contract (shared with validate.sh / run-demo.sh):
#   0 = healthy
#   1 = server config invalid
#   2 = security boundary violation (visibility only here)
#   3 = server functional failure (local smbclient)
#
# Usage:
#   ./server/reset-smb.sh
#
# Optional env overrides:
#   SMB_SHARE="Public"
#   SMB_USER="adminsmb"
#   SMB_HOST="127.0.0.1"
#   SMBCLIENT_PASS="password"     (optional; disables interactive prompt)
#   ALLOW_INTERACTIVE=0|1         (default: 0)
#   RELOAD_UFW=0|1                (default: 0; visibility-only)
#   SHOW_LOG_TAIL=0|1             (default: 0; tail Samba logs on failure)

# ---- exit codes -----------------------------------------------------------
EC_OK=0
EC_CONFIG=1
EC_BOUNDARY=2
EC_FUNCTIONAL=3

# ---- defaults -------------------------------------------------------------
SMB_SHARE="${SMB_SHARE:-Public}"
SMB_USER="${SMB_USER:-adminsmb}"
SMB_HOST="${SMB_HOST:-127.0.0.1}"

ALLOW_INTERACTIVE="${ALLOW_INTERACTIVE:-0}"
RELOAD_UFW="${RELOAD_UFW:-0}"
SHOW_LOG_TAIL="${SHOW_LOG_TAIL:-0}"

PASS_CNT=0
FAIL_CNT=0
EXIT_CODE=$EC_OK

# ---- helpers --------------------------------------------------------------
bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "• %s\n" "$*"; }
ok()   { printf "✅ %s\n" "$*"; PASS_CNT=$((PASS_CNT+1)); }

bad() {
  local msg="$1"
  local code="${2:-$EC_CONFIG}"
  printf "❌ %s\n" "$msg"
  FAIL_CNT=$((FAIL_CNT+1))
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

maybe_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_quiet() { "$@" >/dev/null 2>&1; }

section() {
  printf "\n"
  bold "== $* =="
}

tail_logs_if_enabled() {
  [[ "$SHOW_LOG_TAIL" -eq 1 ]] || return 0
  info "Samba logs (tail):"
  maybe_sudo bash -c 'ls -1 /var/log/samba/log.* 2>/dev/null | head -n 5 | xargs -r tail -n 40' || true
}

summary() {
  printf "\n"
  bold "== Summary =="
  info "Passed checks: $PASS_CNT"
  info "Failed checks: $FAIL_CNT"

  if [[ "$FAIL_CNT" -eq 0 ]]; then
    ok "Reset gate: GREEN"
    exit "$EC_OK"
  else
    bold "Reset gate: RED"
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
need_cmd systemctl || true
command -v smbclient >/dev/null 2>&1 && ok "smbclient present" || info "smbclient not installed (functional test skipped)"
command -v ufw >/dev/null 2>&1 && ok "ufw present" || info "ufw not installed (firewall visibility skipped)"

# =========================
# 2) Validate smb.conf parses
# =========================
section "2) Samba config parse (pre-reset)"
if run_quiet testparm -s; then
  ok "testparm -s parsed smb.conf (no fatal errors)"
else
  bad "testparm -s failed (smb.conf parse error) — refusing to restart blindly" "$EC_CONFIG"
  info "Fix smb.conf first, then rerun reset."
  tail_logs_if_enabled
  exit "$EC_CONFIG"
fi

# =========================
# 3) Restart services
# =========================
section "3) Restart Samba services"
# smbd is required
if maybe_sudo systemctl restart smbd; then
  ok "smbd restarted"
else
  bad "Failed to restart smbd" "$EC_CONFIG"
  tail_logs_if_enabled
fi

# nmbd may not exist if NetBIOS is disabled; treat as optional
if systemctl list-unit-files | grep -q '^nmbd\.service'; then
  if maybe_sudo systemctl restart nmbd; then
    ok "nmbd restarted"
  else
    bad "Failed to restart nmbd (optional depending on design)" "$EC_CONFIG"
    tail_logs_if_enabled
  fi
else
  info "nmbd not installed/enabled (ok if NetBIOS is intentionally disabled)"
  ok "nmbd skipped"
fi

# =========================
# 4) Confirm service is listening
# =========================
section "4) SMB listening state (TCP/445)"
if ss -lntp | grep -qE '[:.]445\b'; then
  ok "Port 445 is listening"
  ss -lntp | awk 'NR==1 || /:445\b/' || true
else
  bad "Port 445 not listening after restart" "$EC_CONFIG"
  info "Check: systemctl status smbd --no-pager"
  tail_logs_if_enabled
fi

# =========================
# 5) Firewall visibility (optional)
# =========================
section "5) Firewall visibility (non-enforcing)"
if command -v ufw >/dev/null 2>&1; then
  if [[ "$RELOAD_UFW" -eq 1 ]]; then
    info "Reloading UFW (no rule changes)."
    maybe_sudo ufw reload >/dev/null 2>&1 && ok "ufw reloaded" || bad "ufw reload failed" "$EC_BOUNDARY"
  fi
  info "UFW status (visibility):"
  maybe_sudo ufw status verbose || true
  ok "UFW status displayed"
else
  info "Skipping UFW (not installed)."
fi

# =========================
# 6) Optional local SMB functional test
# =========================
section "6) Local SMB functional test (optional but recommended)"
if command -v smbclient >/dev/null 2>&1; then
  if [[ -n "${SMBCLIENT_PASS:-}" ]]; then
    if run_quiet bash -c \
      "printf '%s\n' \"$SMBCLIENT_PASS\" | smbclient \"//${SMB_HOST}/${SMB_SHARE}\" -U \"${SMB_USER}\" -c 'ls'"; then
      ok "smbclient localhost test succeeded (ls)"
    else
      bad "smbclient localhost test failed (server functional failure)" "$EC_FUNCTIONAL"
      info "This typically indicates auth mapping or filesystem traversal/ownership mismatch."
      tail_logs_if_enabled
    fi
  else
    if [[ "$ALLOW_INTERACTIVE" -eq 1 ]]; then
      info "SMBCLIENT_PASS not set — interactive prompt enabled."
      if smbclient "//${SMB_HOST}/${SMB_SHARE}" -U "${SMB_USER}" -c "ls"; then
        ok "smbclient localhost test succeeded (ls)"
      else
        bad "smbclient localhost test failed (server functional failure)" "$EC_FUNCTIONAL"
        tail_logs_if_enabled
      fi
    else
      info "SMBCLIENT_PASS not set and ALLOW_INTERACTIVE=0 — skipping smbclient test."
      info "For CI: export SMBCLIENT_PASS to enable non-interactive functional validation."
      ok "Functional test skipped (non-interactive mode)"
    fi
  fi
else
  info "Skipping smbclient (not installed)."
  ok "Functional test skipped"
fi

# =========================
# 7) Post-reset config sanity (optional re-check)
# =========================
section "7) Samba config parse (post-reset)"
if run_quiet testparm -s; then
  ok "testparm -s still clean after restart"
else
  bad "testparm -s failed after restart (unexpected)" "$EC_CONFIG"
  tail_logs_if_enabled
fi

