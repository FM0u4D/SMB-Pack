<#
.SYNOPSIS
	Map an SMB share to a drive letter with a clean, repeatable workflow.

.DESCRIPTION
	This script:
		- Clears any existing mapping for the chosen drive letter (PSDrive + net use)
		- Prompts for credentials securely
		- Maps the share (tries New-PSDrive first, then net use if needed)
		- Validates access by listing a few entries

	Designed to be CI-ready:
		- No secrets stored on disk
		- Deterministic output and exit codes
		- Clear failure hints without oversharing

.PARAMETER SharePath
	UNC path to the SMB share, e.g. \\web-vm\Public or \\10.8.0.3\Public

.PARAMETER DriveLetter
	Drive letter to map (default: Z)

.PARAMETER Username
	SMB username (default: adminsmb)

.PARAMETER Persist
	Persist mapping (default: enabled). Set -Persist:$false to avoid persistence.

.EXIT CODES
	0 = mapped + validated
	10 = mapping failed
	11 = mapped but validation failed

.EXAMPLES
	.\map-drive.ps1
	.\map-drive.ps1 -SharePath "\\10.8.0.3\Public" -DriveLetter "Y" -Username "adminsmb"
	.\map-drive.ps1 -Persist:$false
#>

[CmdletBinding()]
param(
	[Parameter(Mandatory = $false)]
	[ValidateNotNullOrEmpty()]
	[string]$SharePath = "\\web-vm\Public",

	[Parameter(Mandatory = $false)]
	[ValidatePattern('^[A-Za-z]$')]
	[string]$DriveLetter = "Z",

	[Parameter(Mandatory = $false)]
	[ValidateNotNullOrEmpty()]
	[string]$Username = "adminsmb",

	[Parameter(Mandatory = $false)]
	[bool]$Persist = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Exit code contract ---------------------------------------------------
$EC_OK = 0
$EC_MAP_FAIL = 10
$EC_VALIDATE_FAIL = 11

# ---- Output helpers -------------------------------------------------------
function Write-Info { param([Parameter(Mandatory)][string]$m) Write-Host ("• {0}" -f $m) }
function Write-Ok { param([Parameter(Mandatory)][string]$m) Write-Host ("✅ {0}" -f $m) -ForegroundColor Green }
function Write-Warning { param([Parameter(Mandatory)][string]$m) Write-Host ("⚠️  {0}" -f $m) -ForegroundColor Yellow }
function Write-ErrorMsg { param([Parameter(Mandatory)][string]$m) Write-Host ("❌ {0}" -f $m) -ForegroundColor Red }
function Write-Section { param([Parameter(Mandatory)][string]$m) Write-Host ""; Write-Host ("== {0} ==" -f $m) -ForegroundColor Cyan }

# ---- Normalize ------------------------------------------------------------
$DriveLetter = $DriveLetter.Substring(0, 1).ToUpperInvariant()
$DriveName = "${DriveLetter}:"
$Target = $SharePath

Write-Section "SMB drive mapping"
Write-Info ("Target:  {0}" -f $Target)
Write-Info ("Drive:   {0}" -f $DriveName)
Write-Info ("Persist: {0}" -f ($(if ($Persist) { "yes" } else { "no" })))

# ---- Helpers --------------------------------------------------------------
function Invoke-CmdQuiet {
	param([Parameter(Mandatory)][string]$Command)
	cmd.exe /c $Command | Out-Null
}

function Remove-ExistingMapping {
	param(
		[Parameter(Mandatory)][string]$Letter,
		[Parameter(Mandatory)][string]$Name
	)

	Write-Section "1) Clear existing mapping"

	try {
		$existing = Get-PSDrive -Name $Letter -ErrorAction SilentlyContinue
		if ($null -ne $existing) {
			Write-Info "Removing PSDrive mapping..."
			Remove-PSDrive -Name $Letter -Force -ErrorAction SilentlyContinue
			Write-Ok "PSDrive mapping cleared"
		}
		else {
			Write-Ok "No PSDrive mapping found"
		}
	}
 catch {
		Write-Warning ("PSDrive cleanup warning: {0}" -f $_.Exception.Message)
	}

	try {
		Write-Info "Removing net use mapping (if any)..."
		Invoke-CmdQuiet "net use $Name /delete /y"
		Write-Ok "net use mapping cleared (or none existed)"
	}
 catch {
		Write-Warning ("net use cleanup warning: {0}" -f $_.Exception.Message)
	}
}

function Get-UserCredential {
	param([Parameter(Mandatory)][string]$User)
	Write-Section "2) Credentials"
	$sec = Read-Host ("Password for {0}" -f $User) -AsSecureString
	return New-Object System.Management.Automation.PSCredential($User, $sec)
}

function ConvertTo-PlainText {
	param([Parameter(Mandatory)][Security.SecureString]$Secure)
	$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
	try {
		return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
	}
	finally {
		[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
	}
}

function New-MappingPsDrive {
	param(
		[Parameter(Mandatory)][string]$Letter,
		[Parameter(Mandatory)][string]$Root,
		[Parameter(Mandatory)][pscredential]$Credential,
		[Parameter(Mandatory)][bool]$PersistFlag
	)

	Write-Info "Mapping using New-PSDrive..."
	if ($PersistFlag) {
		New-PSDrive -Name $Letter -PSProvider FileSystem -Root $Root -Credential $Credential -Persist | Out-Null
	}
	else {
		New-PSDrive -Name $Letter -PSProvider FileSystem -Root $Root -Credential $Credential | Out-Null
	}
	Write-Ok ("Drive mapped: {0}: -> {1}" -f $Letter, $Root)
}

function New-MappingNetUse {
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][string]$Root,
		[Parameter(Mandatory)][string]$User,
		[Parameter(Mandatory)][Security.SecureString]$SecurePass,
		[Parameter(Mandatory)][bool]$PersistFlag
	)

	$plain = ConvertTo-PlainText -Secure $SecurePass
	Write-Info "Mapping using net use..."
	$persistArg = $(if ($PersistFlag) { "yes" } else { "no" })
	Invoke-CmdQuiet "net use $Name $Root /user:$User $plain /persistent:$persistArg"
	Write-Ok ("Drive mapped via net use: {0} -> {1}" -f $Name, $Root)
}

function Test-Mapping {
	param([Parameter(Mandatory)][string]$DriveRoot)

	Write-Section "4) Validate access"
	Start-Sleep -Milliseconds 350

	if (Test-Path ($DriveRoot + "\")) {
		Write-Ok ("Validation: reachable ({0}\)" -f $DriveRoot)
		try {
			Get-ChildItem ($DriveRoot + "\") -Force -ErrorAction SilentlyContinue |
			Select-Object -First 10 |
			Format-Table -AutoSize | Out-Host
		}
		catch {
			Write-Warning ("Listing warning: {0}" -f $_.Exception.Message)
		}
		return $true
	}

	Write-ErrorMsg ("Validation failed: cannot access {0}\" -f $DriveRoot)
	Write-Info "If the server-side localhost test is green, focus shifts to VPN/client policy or stale sessions."
	return $false
}

# ---- Run ------------------------------------------------------------------
try {
	Remove-ExistingMapping -Letter $DriveLetter -Name $DriveName

	$cred = Get-UserCredential -User $Username

	Write-Section "3) Map drive"
	$mapped = $false

	try {
		New-MappingPsDrive -Letter $DriveLetter -Root $Target -Credential $cred -PersistFlag $Persist
		$mapped = $true
	}
	catch {
		Write-Warning ("New-PSDrive failed: {0}" -f $_.Exception.Message)
		Write-Info "Falling back to net use (password kept in-memory only)."
		try {
			New-MappingNetUse -Name $DriveName -Root $Target -User $Username -SecurePass $cred.Password -PersistFlag $Persist
			$mapped = $true
		}
		catch {
			Write-ErrorMsg ("net use failed: {0}" -f $_.Exception.Message)
			$mapped = $false
		}
	}

	if (-not $mapped) { exit $EC_MAP_FAIL }

	if (-not (Test-Mapping -DriveRoot $DriveName)) { exit $EC_VALIDATE_FAIL }

	Write-Ok "Mapping completed and verified"
	exit $EC_OK
}
catch {
	Write-ErrorMsg $_.Exception.Message
	exit $EC_MAP_FAIL
}
