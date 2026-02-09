$ErrorActionPreference = "Stop"

function Info($m){ Write-Host "• $m" }
function Ok($m){ Write-Host "✅ $m" }

Info "Clearing SMB mapped drives and sessions..."
cmd /c "net use * /delete /y" | Out-Null
Ok "net use sessions cleared"

Info "Flushing DNS cache..."
ipconfig /flushdns | Out-Null
Ok "DNS cache flushed"

Info "Restarting Workstation service (LanmanWorkstation) to reset SMB client state..."
# This can briefly impact network shares; it's the cleanest reset without reboot.
Restart-Service -Name "LanmanWorkstation" -Force
Ok "Workstation service restarted"

Info "Done."
