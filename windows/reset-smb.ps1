<#
.SYNOPSIS
  Reset Windows SMB client state for a specific share (or optionally all mappings).

.DESCRIPTION
  This script removes SMB mappings, optionally clears cached credentials, purges Kerberos tickets,
  flushes DNS, and (optionally) restarts SMB client services and disables WebClient (WebDAV noise).
  Designed to be repo/CI friendly with deterministic exit codes.

.EXIT CODES
  0 = reset completed successfully
  4 = reset failed (one or more steps failed)

.EXAMPLES
  # Minimal reset for a single mapping
  .\reset-smb.ps1 -Server "web-vm" -Share "Public" -DriveLetter Z

  # Full reset path (recommended when troubleshooting "shape-shifting" SMB failures)
  .\reset-smb.ps1 -Server "web-vm" -Share "Public" -DriveLetter Z `
    -ClearCredentials -PurgeKerberos -FlushDns -RestartWorkstation -DisableWebClient -Force

  # Remove ALL SMB mappings (dangerous; use only in lab)
  .\reset-smb.ps1 -RemoveAllMappings -Force
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$Server = "web-vm",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$Share = "Public",

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter = "Z",

    [Parameter(Mandatory = $false)]
    [switch]$RemoveAllMappings,

    [Parameter(Mandatory = $false)]
    [switch]$ClearCredentials,

    [Parameter(Mandatory = $false)]
    [switch]$PurgeKerberos,

    [Parameter(Mandatory = $false)]
    [switch]$FlushDns,

    [Parameter(Mandatory = $false)]
    [switch]$RestartWorkstation,

    [Parameter(Mandatory = $false)]
    [switch]$DisableWebClient,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Exit code contract ---------------------------------------------------
$EC_OK = 0
$EC_RESET_FAIL = 4

# ---- Formatting helpers ---------------------------------------------------
function Write-Section {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ""
    Write-Host ("== {0} ==" -f $Text) -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ("✅ {0}" -f $Text) -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ("⚠️  {0}" -f $Text) -ForegroundColor Yellow
}

function Write-Fail {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ("❌ {0}" -f $Text) -ForegroundColor Red
}

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory = $false)][string[]]$Arguments = @()
    )
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -NoNewWindow -PassThru
    return $p.ExitCode
}

# ---- Derived values -------------------------------------------------------
$drivePath = "{0}:" -f $DriveLetter.ToUpper()
$targetUNC = "\\{0}\{1}" -f $Server, $Share

$hadError = $false
$isAdmin = Test-IsAdministrator

try {
    Write-Section "Reset SMB client state"
    Write-Host ("Target: {0}" -f $targetUNC)
    Write-Host ("Drive : {0}" -f $drivePath)
    if (-not $isAdmin) {
        Write-Warn "Not running as Administrator. Some optional actions may be skipped (service changes / WebClient)."
    }
    else {
        Write-Ok "Running as Administrator"
    }

    # ------------------------------------------------------------------------
    # 1) Remove SMB mappings
    # ------------------------------------------------------------------------
    Write-Section "1) Remove SMB mappings"

    if ($RemoveAllMappings) {
        if (-not $Force -and -not $PSCmdlet.ShouldProcess("ALL SMB mappings", "Remove")) {
            Write-Warn "Skipped removing all mappings."
        }
        else {
            # net use * /delete is the most reliable for old mappings
            $ec = Invoke-External -FilePath "cmd.exe" -Arguments @("/c", "net use * /delete /y")
            if ($ec -eq 0) { Write-Ok "Removed ALL SMB mappings (net use * /delete)" }
            else { throw "Failed to remove all mappings (net use exit code $ec)" }
        }
    }
    else {
        # Try modern cmdlets first (works on newer Windows)
        $removed = $false

        try {
            $existing = Get-SmbMapping -ErrorAction Stop | Where-Object {
                $_.LocalPath -eq $drivePath -or $_.RemotePath -eq $targetUNC
            }

            foreach ($m in $existing) {
                if (-not $Force -and -not $PSCmdlet.ShouldProcess($m.RemotePath, "Remove SMB mapping")) {
                    continue
                }
                Remove-SmbMapping -LocalPath $m.LocalPath -Force -UpdateProfile -ErrorAction Stop
                Write-Ok ("Removed SMB mapping: {0} -> {1}" -f $m.LocalPath, $m.RemotePath)
                $removed = $true
            }
        }
        catch {
            # Fallback to net use below
        }

        if (-not $removed) {
            # Fallback: net use Z: /delete
            $cmd = "net use {0} /delete /y" -f $drivePath
            $ec = Invoke-External -FilePath "cmd.exe" -Arguments @("/c", $cmd)
            if ($ec -eq 0) {
                Write-Ok ("Removed mapping via net use: {0}" -f $drivePath)
            }
            else {
                # If nothing existed, net use may return non-zero; treat "not found" as non-fatal
                Write-Warn ("No mapping removed for {0} (net use exit code {1}). This can be OK if nothing was mapped." -f $drivePath, $ec)
            }
        }
    }

    # ------------------------------------------------------------------------
    # 2) Clear cached credentials (optional)
    # ------------------------------------------------------------------------
    if ($ClearCredentials) {
        Write-Section "2) Clear cached credentials (cmdkey)"

        $cmdkeyList = & cmdkey.exe /list 2>$null
        if (-not $cmdkeyList) {
            Write-Warn "cmdkey returned no entries (or access denied)."
        }
        else {
            # Targets that commonly store SMB creds (server name, and sometimes UNC-ish variants)
            $targetsToDelete = New-Object System.Collections.Generic.HashSet[string]
            [void]$targetsToDelete.Add($Server)
            [void]$targetsToDelete.Add("MicrosoftAccount:{0}" -f $Server) | Out-Null

            # Parse "Target: xxx" lines and delete those containing server
            foreach ($line in $cmdkeyList) {
                if ($line -match '^\s*Target:\s*(.+)\s*$') {
                    $t = $Matches[1].Trim()
                    if ($t -match [regex]::Escape($Server)) {
                        [void]$targetsToDelete.Add($t)
                    }
                }
            }

            $deletedAny = $false
            foreach ($t in $targetsToDelete) {
                if (-not $Force -and -not $PSCmdlet.ShouldProcess($t, "Delete cached credential")) {
                    continue
                }
                $ec = Invoke-External -FilePath "cmdkey.exe" -Arguments @("/delete:$t")
                if ($ec -eq 0) {
                    Write-Ok ("Deleted credential: {0}" -f $t)
                    $deletedAny = $true
                }
            }

            if (-not $deletedAny) {
                Write-Warn "No matching credentials were deleted (none found for this server, or skipped)."
            }
        }
    }
    else {
        Write-Section "2) Clear cached credentials"
        Write-Warn "Skipped (use -ClearCredentials)"
    }

    # ------------------------------------------------------------------------
    # 3) Purge Kerberos tickets (optional)
    # ------------------------------------------------------------------------
    if ($PurgeKerberos) {
        Write-Section "3) Purge Kerberos tickets (klist purge)"
        if (-not $Force -and -not $PSCmdlet.ShouldProcess("Kerberos ticket cache", "Purge")) {
            Write-Warn "Skipped Kerberos purge."
        }
        else {
            $ec = Invoke-External -FilePath "klist.exe" -Arguments @("purge")
            if ($ec -eq 0) { Write-Ok "Kerberos tickets purged" }
            else { throw "klist purge failed (exit code $ec)" }
        }
    }
    else {
        Write-Section "3) Purge Kerberos tickets"
        Write-Warn "Skipped (use -PurgeKerberos)"
    }

    # ------------------------------------------------------------------------
    # 4) Flush DNS (optional)
    # ------------------------------------------------------------------------
    if ($FlushDns) {
        Write-Section "4) Flush DNS (ipconfig /flushdns)"
        $ec = Invoke-External -FilePath "ipconfig.exe" -Arguments @("/flushdns")
        if ($ec -eq 0) { Write-Ok "DNS cache flushed" }
        else { throw "ipconfig /flushdns failed (exit code $ec)" }
    }
    else {
        Write-Section "4) Flush DNS"
        Write-Warn "Skipped (use -FlushDns)"
    }

    # ------------------------------------------------------------------------
    # 5) Restart SMB client service (optional; admin)
    # ------------------------------------------------------------------------
    if ($RestartWorkstation) {
        Write-Section "5) Restart Workstation service (LanmanWorkstation)"
        if (-not $isAdmin) {
            Write-Warn "Skipped: requires Administrator."
        }
        else {
            if (-not $Force -and -not $PSCmdlet.ShouldProcess("LanmanWorkstation", "Restart service")) {
                Write-Warn "Skipped restarting LanmanWorkstation."
            }
            else {
                Restart-Service -Name "LanmanWorkstation" -Force -ErrorAction Stop
                Write-Ok "LanmanWorkstation restarted"
            }
        }
    }
    else {
        Write-Section "5) Restart Workstation service"
        Write-Warn "Skipped (use -RestartWorkstation)"
    }

    # ------------------------------------------------------------------------
    # 6) Disable WebClient (optional; admin)
    # ------------------------------------------------------------------------
    if ($DisableWebClient) {
        Write-Section "6) Disable WebClient (WebDAV provider noise)"
        if (-not $isAdmin) {
            Write-Warn "Skipped: requires Administrator."
        }
        else {
            if (-not $Force -and -not $PSCmdlet.ShouldProcess("WebClient", "Stop + Disable service")) {
                Write-Warn "Skipped disabling WebClient."
            }
            else {
                try {
                    Stop-Service -Name "WebClient" -Force -ErrorAction SilentlyContinue
                }
                catch { }
                Set-Service -Name "WebClient" -StartupType Disabled -ErrorAction Stop
                Write-Ok "WebClient disabled"
            }
        }
    }
    else {
        Write-Section "6) Disable WebClient"
        Write-Warn "Skipped (use -DisableWebClient)"
    }

    # ------------------------------------------------------------------------
    # 7) Final state snapshot
    # ------------------------------------------------------------------------
    Write-Section "7) Snapshot (mappings + relevant services)"

    try {
        $maps = Get-SmbMapping -ErrorAction Stop
        if ($maps) {
            $maps | Select-Object LocalPath, RemotePath, Status | Format-Table -AutoSize
            Write-Ok "Displayed current SMB mappings"
        }
        else {
            Write-Warn "No SMB mappings present"
        }
    }
    catch {
        Write-Warn "Get-SmbMapping not available on this system (older Windows)."
    }

    foreach ($svcName in @("LanmanWorkstation", "WebClient")) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction Stop
            Write-Host ("{0,-18} : {1} (StartType: {2})" -f $svc.Name, $svc.Status, $svc.StartType)
        }
        catch {
            Write-Warn ("Service not found: {0}" -f $svcName)
        }
    }

    Write-Ok "Reset completed"
}
catch {
    $hadError = $true
    Write-Fail $_.Exception.Message
}

if ($hadError) {
    exit $EC_RESET_FAIL
}

exit $EC_OK
