<#
.SYNOPSIS
  Snapshot SMB client posture on Windows (read-only).

.DESCRIPTION
    Prints the key client-side signals that commonly affect SMB behavior:
        - SMB client configuration
        - Active/persisted mappings (net use)
        - WebClient (WebDAV redirector) status
        - Network Provider Order (provider priority)

.NOTES
    This script makes NO changes. Safe to run multiple times.
    Recommended: run in an elevated PowerShell for full registry visibility.

.EXIT CODES
    0  = success
    20 = partial (one or more sections could not be read)
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$EC_OK = 0
$EC_PARTIAL = 20
$hadPartial = $false

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ""
    Write-Host ("== {0} ==" -f $Title) -ForegroundColor Cyan
}

function Write-Info {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("• {0}" -f $Message)
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("✅ {0}" -f $Message) -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("⚠️  {0}" -f $Message) -ForegroundColor Yellow
}

function Write-Fail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ("❌ {0}" -f $Message) -ForegroundColor Red
}

function Invoke-Section {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Block
    )

    Write-Section $Name
    try {
        & $Block
        Write-Ok "Collected"
    }
    catch {
        $script:hadPartial = $true
        Write-Warn ("Skipped/limited: {0}" -f $_.Exception.Message)
    }
}

# 1) SMB Client Configuration
Invoke-Section "SMB Client Configuration" {
    if (-not (Get-Command Get-SmbClientConfiguration -ErrorAction SilentlyContinue)) {
        throw "Get-SmbClientConfiguration not available on this system."
    }
    Get-SmbClientConfiguration | Format-List | Out-Host
}

# 2) Mapped connections (net use)
Invoke-Section "SMB Mapped Connections (net use)" {
    # net use can return non-zero if there are no connections; still print output
    cmd.exe /c "net use" | Out-Host
}

# 3) WebClient service (WebDAV)
Invoke-Section "WebClient Service (WebDAV redirector)" {
    $svc = Get-Service -Name "WebClient" -ErrorAction Stop
    $startMode = (Get-CimInstance Win32_Service -Filter "Name='WebClient'").StartMode
    $obj = [pscustomobject]@{
        Name      = $svc.Name
        Status    = $svc.Status
        StartType = $startMode
    }
    $obj | Format-List | Out-Host
}

# 4) Network Provider Order (provider priority)
Invoke-Section "Network Provider Order" {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Control\NetworkProvider\Order"
    $val = (Get-ItemProperty -Path $key -Name "ProviderOrder" -ErrorAction Stop).ProviderOrder
    Write-Info ("ProviderOrder = {0}" -f $val)
}

if ($hadPartial) {
    Write-Fail "Completed with partial visibility (some sections could not be read)."
    exit $EC_PARTIAL
}

Write-Ok "Completed successfully."
exit $EC_OK
