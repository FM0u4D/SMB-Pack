#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================
# Apply Permission Alignment
# ==========================
# Ensures parent traversal + sane share permissions for Samba shares.
#
# Scope (by default):
#   /srv/samba/{public,direction}
#
# Usage:
#   sudo ./server/apply-perms.sh
#
# Optional env overrides:
#   SMB_USER="adminsmb"
#   SMB_GROUP="adminsmb"
#   BASE="/srv/samba"
#   PUBLIC="public"
#   DIRECTION="direction"

SMB_USER="${SMB_USER:-adminsmb}"
SMB_GROUP="${SMB_GROUP:-adminsmb}"
BASE="${BASE:-/srv/samba}"
PUBLIC="${PUBLIC:-public}"
DIRECTION="${DIRECTION:-direction}"

must_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: run as root (sudo $0)" >&2
    exit 1
  fi
}

must_root

# Create share directories if missing
mkdir -p "$BASE/$PUBLIC" "$BASE/$DIRECTION"

# ---------------------------------
# Parent traversal (critical gate)
# ---------------------------------
# All parents in the path must be executable (x),
# otherwise SMB auth may succeed but access will fail.
#
# Do NOT silence failures here.

chmod 755 "$(dirname "$BASE")"
chmod 755 "$BASE"

# ---------------------------------
# Ownership alignment
# ---------------------------------
chown -R "${SMB_USER}:${SMB_GROUP}" "$BASE/$PUBLIC" "$BASE/$DIRECTION"

# ---------------------------------
# Permission model
# ---------------------------------
# Public: group-writable
find "$BASE/$PUBLIC" -type d -exec chmod 775 {} \;
find "$BASE/$PUBLIC" -type f -exec chmod 664 {} \;

# Direction: tighter access
find "$BASE/$DIRECTION" -type d -exec chmod 770 {} \;
find "$BASE/$DIRECTION" -type f -exec chmod 660 {} \;

# ---------------------------------
# Verification snapshot
# ---------------------------------
echo
echo "Permission alignment complete. Current state:"
ls -ld "$(dirname "$BASE")" "$BASE" "$BASE/$PUBLIC" "$BASE/$DIRECTION"

echo
echo "OK: ownership and mode bits aligned under $BASE"
