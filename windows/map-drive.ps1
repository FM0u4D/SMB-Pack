Param(
  [string]$SharePath = "\\web-vm\Public",
  [string]$DriveLetter = "Z",
  [string]$Username = "adminsmb"
)

$ErrorActionPreference = "Stop"

function Info($m){ Write-Host "• $m" }
function Ok($m){ Write-Host "✅ $m" }
function Bad($m){ Write-Host "❌ $m" }

# Normalize
if ($DriveLetter.Length -gt 1) { $DriveLetter = $DriveLetter.Substring(0,1) }
$DriveName = "$DriveLetter`:"
$Target = $SharePath

Info "Target: $Target"
Info "Drive:  $DriveName"

# 1) Remove existing mapping cleanly (if any)
try {
  $existing = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
  if ($existing) {
    Info "Removing existing PSDrive mapping..."
    Remove-PSDrive -Name $DriveLetter -Force -ErrorAction SilentlyContinue
  }
} catch {}

# Also clear net use mapping (covers legacy/persisted)
cmd /c "net use $DriveName /delete /y" | Out-Null

# 2) Prompt for password securely (no plain text stored)
$sec = Read-Host "Password for $Username" -AsSecureString
$cred = New-Object System.Management.Automation.PSCredential($Username, $sec)

# 3) Map (persist)
try {
  New-PSDrive -Name $DriveLetter -PSProvider FileSystem -Root $Target -Credential $cred -Persist | Out-Null
  Ok "Drive mapped: $DriveName -> $Target"
} catch {
  Bad "New-PSDrive failed. Falling back to net use..."
  # Fallback to net use (requires plain password; convert securely in-memory only)
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  )
  cmd /c "net use $DriveName $Target /user:$Username $plain" | Out-Null
  Ok "Drive mapped via net use: $DriveName -> $Target"
}

# 4) Validate access
Start-Sleep -Milliseconds 400
if (Test-Path "$DriveName\") {
  Ok "Validation: path reachable ($DriveName\)"
  Get-ChildItem "$DriveName\" -Force -ErrorAction SilentlyContinue | Select-Object -First 10 | Out-Host
} else {
  Bad "Validation failed: cannot access $DriveName\"
  Info "If localhost SMB is green, focus on VPN/client policy and stale sessions."
  exit 1
}
