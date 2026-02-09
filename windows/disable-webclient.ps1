Param(
  [switch]$ReorderProviders
)

$ErrorActionPreference = "Stop"

function Info($m){ Write-Host "• $m" }
function Ok($m){ Write-Host "✅ $m" }
function Bad($m){ Write-Host "❌ $m" }

# 1) Disable WebClient service (WebDAV redirector)
try {
  $svc = Get-Service -Name "WebClient" -ErrorAction Stop
  Info "WebClient status: $($svc.Status) / StartType: $((Get-CimInstance Win32_Service -Filter "Name='WebClient'").StartMode)"
  
  if ($svc.Status -ne "Stopped") {
    Info "Stopping WebClient..."
    Stop-Service -Name "WebClient" -Force
  }

  Info "Disabling WebClient startup..."
  Set-Service -Name "WebClient" -StartupType Disabled

  Ok "WebClient disabled (reduces certificate/provider noise for SMB paths)"
} catch {
  Bad "WebClient service not found or access denied."
  throw
}

# 2) Optional: move/remove WebClient from Network Provider Order (advanced)
if ($ReorderProviders) {
  $key = "HKLM:\SYSTEM\CurrentControlSet\Control\NetworkProvider\Order"
  $name = "ProviderOrder"
  $backup = "$env:ProgramData\ProviderOrder.backup.$(Get-Date -Format yyyyMMdd-HHmmss).txt"

  $current = (Get-ItemProperty -Path $key -Name $name).$name
  Set-Content -Path $backup -Value $current
  Info "Backup saved: $backup"

  # Ensure LanmanWorkstation is first, and WebClient is last (or removed)
  $parts = $current.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

  # Remove duplicates
  $parts = $parts | Select-Object -Unique

  # Ensure LanmanWorkstation exists
  if (-not ($parts -contains "LanmanWorkstation")) {
    $parts = @("LanmanWorkstation") + $parts
  }

  # Move WebClient to end if present
  if ($parts -contains "WebClient") {
    $parts = $parts | Where-Object { $_ -ne "WebClient" }
    $parts = $parts + @("WebClient")
  }

  $new = ($parts -join ",")
  Set-ItemProperty -Path $key -Name $name -Value $new

  Ok "Provider order updated (LanmanWorkstation prioritized). Reboot recommended."
  Info "Old: $current"
  Info "New: $new"
}
