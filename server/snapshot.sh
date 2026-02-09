#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# SMB State Snapshot Script
# =========================
# Captures a point-in-time snapshot of the SMB server state.
#
# This script is READ-ONLY:
#   - It does NOT modify configuration
#   - It does NOT change permissions
#
# Intended use:
#   - Before changes
#   - After incidents
#   - As evidence for troubleshooting / validation
#
# Usage:
#   sudo ./server/snapshot.sh

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

TS="$(date +%F-%H%M%S)"
BASE_DIR="/root/smb-snapshots"
SNAP_DIR="$BASE_DIR/$TS"

mkdir -p "$SNAP_DIR"

# -------------------------
# Metadata (high signal)
# -------------------------
{
  echo "Timestamp: $(date -Is)"
  echo "Hostname : $(hostname)"
  echo "Kernel   : $(uname -r)"
  echo "Uptime   : $(uptime -p)"
} > "$SNAP_DIR/meta.txt"

# -------------------------
# Samba configuration
# -------------------------
cp /etc/samba/smb.conf "$SNAP_DIR/smb.conf.bak" 2>/dev/null || true
testparm -s > "$SNAP_DIR/testparm.txt" 2>/dev/null || true

# -------------------------
# Network / service state
# -------------------------
ss -lntp > "$SNAP_DIR/ss-listeners.txt" 2>/dev/null || true
ufw status verbose > "$SNAP_DIR/ufw.txt" 2>/dev/null || true

# -------------------------
# Filesystem visibility
# -------------------------
# Assumes default lab paths under /srv/samba
ls -la /srv /srv/samba /srv/samba/public /srv/samba/direction \
  > "$SNAP_DIR/ls.txt" 2>/dev/null || true

# -------------------------
# ACL snapshot (optional)
# -------------------------
getfacl -R /srv/samba > "$SNAP_DIR/acl.txt" 2>/dev/null || true

echo "[OK] SMB snapshot saved to $SNAP_DIR"
