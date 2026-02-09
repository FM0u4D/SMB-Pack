<#
.SYNOPSIS
  Disable the WebClient (WebDAV) service to reduce SMB certificate/provider noise.
  Optionally reorder Network Provider Order to prioritize LanmanWorkstation.

.DESCRIPTION
  Some Windows environments can surface misleading prompts/behavior when WebClient
  (WebDAV redirector) participates in network provider resolution. This script:
   - Stops + disables the WebClient service (idempotent)
   - Optionally adjusts ProviderOrder so LanmanWorkstation is prioritized
   - Creates a timestamped backup of the original ProviderOrder value

.PARAMETER ReorderProviders
  If set, updates:
    HKLM:\SYSTEM\CurrentControlSet\Control\NetworkProvider\Order\ProviderOrder

.EXIT CODES
  0 = success
  4 = failure

.NOTES
  - Disabling WebClient is safe in many lab setups, but it affects WebDAV usage.
  - ProviderOrder changes are advanced; reboot recommended after change.
  - Run as Administrator for service + registry modifications.

.EXAMPLES
  .\disable-webclient.ps1
  .\disable-webclient.ps1 -ReorderProviders -Force
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
	[Parameter(Mandatory = $false)]
	[switch]$ReorderProviders,

	[Parameter(Mandatory = $false)]
	[switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Exit code contract ---------------------------------------------------
$EC_OK = 0
$EC_FAIL = 4

# ---- Output helpers -------------------------------------------------------
function Write-Info { param([Parameter(Mandatory)][string]$m) Write-Host ("• {0}" -f $m) }
function Write-Ok { param([Parameter(Mandatory)][string]$m) Write-Host ("✅ {0}" -f $m) -ForegroundColor Green }
function Write-Warn { param([Parameter(Mandatory)][string]$m) Write-Host ("⚠️  {0}" -f $m) -ForegroundColor Yellow }
function Write-Bad { param([Parameter(Mandatory)][string]$m) Write-Host ("❌ {0}" -f $m) -ForegroundColor Red }
function Write-Section { param([Parameter(Mandatory)][string]$m) Write-Host ""; Write-Host ("== {0} ==" -f $m) -ForegroundColor Cyan }

function Test-IsAdministrator {
	$id = [Security.Principal.WindowsIdentity]::GetCurrent()
	$p = New-Object Security.Principal.WindowsPrincipal($id)
	return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$hadError = $false
$isAdmin = Test-IsAdministrator

try {
	Write-Section "WebClient / Provider Order controls"

	if (-not $isAdmin) {
		Write-Warn "Not running as Administrator. Service + registry actions will likely fail."
	}
	else {
		Write-Ok "Running as Administrator"
	}

	# =========================================================================
	# 1) Disable WebClient service (WebDAV redirector)
	# =========================================================================
	Write-Section "1) Disable WebClient service"

	if (-not $Force -and -not $PSCmdlet.ShouldProcess("WebClient service", "Stop + Disable")) {
		Write-Warn "Skipped disabling WebClient (confirmation declined)."
	}
	else {
		$svc = Get-Service -Name "WebClient" -ErrorAction Stop

		$startMode = (Get-CimInstance Win32_Service -Filter "Name='WebClient'" -ErrorAction Stop).StartMode
		Write-Info ("Current: Status={0} StartType={1}" -f $svc.Status, $startMode)

		if ($svc.Status -ne "Stopped") {
			Write-Info "Stopping WebClient..."
			Stop-Service -Name "WebClient" -Force -ErrorAction Stop
		}

		Write-Info "Disabling WebClient startup..."
		Set-Service -Name "WebClient" -StartupType Disabled -ErrorAction Stop

		Write-Ok "WebClient disabled (reduces WebDAV/provider noise on network paths)"
	}

	# =========================================================================
	# 2) Optional: reorder Network Provider Order (advanced)
	# =========================================================================
	if ($ReorderProviders) {
		Write-Section "2) Provider order (advanced)"

		$keyPath = "HKLM:\SYSTEM\CurrentControlSet\Control\NetworkProvider\Order"
		$valueName = "ProviderOrder"

		if (-not (Test-Path $keyPath)) {
			throw "Registry key not found: $keyPath"
		}

		$current = (Get-ItemProperty -Path $keyPath -Name $valueName -ErrorAction Stop).$valueName
		if ([string]::IsNullOrWhiteSpace($current)) {
			throw "ProviderOrder is empty/unreadable."
		}

		$backupDir = Join-Path $env:ProgramData "SecureSMB-WG"
		New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
		$backupPath = Join-Path $backupDir ("ProviderOrder.backup.{0}.txt" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
		Set-Content -Path $backupPath -Value $current -Encoding UTF8
		Write-Info ("Backup saved: {0}" -f $backupPath)

		# Parse -> trim -> drop blanks -> unique (preserve order)
		$rawParts = $current.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

		$seen = New-Object System.Collections.Generic.HashSet[string]
		$parts = New-Object System.Collections.Generic.List[string]
		foreach ($p in $rawParts) {
			if ($seen.Add($p)) { [void]$parts.Add($p) }
		}

		# Ensure LanmanWorkstation is first
		$parts = $parts | Where-Object { $_ -ne "LanmanWorkstation" }
		$parts = @("LanmanWorkstation") + $parts

		# Keep WebClient last if present (or omit if already disabled and you want it out)
		$hasWebClient = $parts -contains "WebClient"
		if ($hasWebClient) {
			$parts = $parts | Where-Object { $_ -ne "WebClient" }
			$parts = @($parts) + @("WebClient")
		}

		$new = ($parts -join ",")

		if ($new -eq $current) {
			Write-Ok "ProviderOrder already optimal (no change needed)."
		}
		else {
			if (-not $Force -and -not $PSCmdlet.ShouldProcess($keyPath, "Set ProviderOrder")) {
				Write-Warn "Skipped ProviderOrder update (confirmation declined)."
			}
			else {
				Set-ItemProperty -Path $keyPath -Name $valueName -Value $new -ErrorAction Stop
				Write-Ok "ProviderOrder updated (LanmanWorkstation prioritized). Reboot recommended."
				Write-Info ("Old: {0}" -f $current)
				Write-Info ("New: {0}" -f $new)
			}
		}
	}
	else {
		Write-Section "2) Provider order (advanced)"
		Write-Warn "Skipped (use -ReorderProviders)"
	}

	Write-Ok "Done"
}
catch {
	$hadError = $true
	Write-Bad $_.Exception.Message
}

if ($hadError) { exit $EC_FAIL }
exit $EC_OK
