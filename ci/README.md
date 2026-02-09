# CI Validation Layer — Secure SMB over WireGuard

This directory contains **CI-oriented validation logic** for the repository.  
It is designed for **self-hosted CI runners** operating on or alongside the SMB server.

The goal is **not to build or deploy**, but to **continuously enforce security posture** and detect configuration drift.

---

## Purpose

The CI layer validates that the SMB service remains:

- Functionally healthy
- Bound to the VPN boundary (WireGuard)
- Protected against accidental exposure
- Consistent with the documented security model

This mirrors **SOC operational controls**, not application CI.

---

## What CI Validates

CI executes **server-side security gates** only.

### 1) Samba Configuration Sanity
Validated via:
- `testparm -s`

Ensures:
- `smb.conf` parses cleanly
- No fatal syntax or semantic errors

Failure here indicates:
- Configuration corruption
- Unsafe or invalid Samba changes

---

### 2) Service State (smbd)
Validated via:
- `ss -lntp`

Ensures:
- `smbd` is listening on TCP/445
- Service is not stopped or bound incorrectly

Failure here indicates:
- Service outage
- Incorrect binding
- Broken restart/reload

---

### 3) Boundary Enforcement (VPN-only SMB)
Validated via:
- `ufw status verbose`

Ensures:
- UFW is active
- TCP/445 is **not** allowed from `Anywhere`
- TCP/445 is explicitly allowed only from the VPN subnet

Failure here indicates:
- **Security regression**
- Accidental public exposure of SMB

This is a **hard policy gate**.

---

### 4) Local Functional SMB Test
Validated via:
- `smbclient //127.0.0.1/<share>`

Ensures:
- Samba authentication works locally
- Filesystem traversal permissions are correct
- SMB is functional independent of VPN and Windows

Failure here indicates:
- Broken permissions
- Auth issues
- Filesystem traversal regression

---

## Exit Codes (Contract)

CI relies on **explicit exit codes**.


| Exit Code | Meaning |
|---------|--------|
| `0` | Healthy — all validation gates passed |
| `1` | Server configuration invalid (Samba, service, dependencies) |
| `2` | Boundary violation (TCP/445 not VPN-scoped) |
| `3` | Local SMB functional failure |

These exit codes are stable and safe to integrate into:
- GitHub Actions
- External CI systems
- SOC alerting pipelines

---

## Scripts Used by CI

CI does **not** introduce new logic.  
It reuses the same scripts used during manual incident analysis.

### `server/validate.sh`
Purpose:
- Sanity and visibility checks
- Non-destructive validation
- Diagnostic output for operators

Used for:
- Early failure detection
- Operational insight

---

### `run-demo.sh`
Purpose:
- Enforced policy gate
- Deterministic pass/fail semantics
- CI-friendly exit codes

Used for:
- Boundary enforcement
- Drift detection
- Security regression prevention

---

## Runner Requirements

This workflow **requires a self-hosted runner**.

Minimum runner capabilities:

- Linux host
- Samba installed
- `smbclient`, `ss`, `testparm`, `ufw` available
- Network visibility of the SMB server
- Permission to run commands via `sudo`

⚠️ GitHub-hosted runners **cannot** validate:
- Firewall state
- Listening ports
- Local SMB behavior

---

## CI Trigger Model

The workflow runs on:

- Changes to `server/**`
- Changes to `run-demo.sh`
- Scheduled execution every 6 hours (drift detection)

This ensures:
- Config changes are validated immediately
- Silent regressions are detected over time

---

## What CI Does NOT Do

CI intentionally does **not**:

- Validate Windows client behavior
- Establish VPN connections
- Modify firewall or permissions
- Apply fixes automatically

CI is **read-only and fail-fast** by design.

Remediation is a **human decision**, consistent with SOC practice.

---

## Extending the CI Layer (Safe Pattern)

If you add new security gates:

1. Implement them in `run-demo.sh`
2. Assign a unique exit code
3. Document the new code here
4. Keep scripts idempotent and non-destructive

Do **not**:
- Embed environment-specific secrets
- Auto-remediate from CI
- Hide failures behind warnings

---

## Design Principle

> CI is the **automated witness**, not the repair crew.

This CI layer exists to:
- Prove boundary enforcement
- Detect drift
- Create audit-ready evidence

Nothing more. Nothing less.
