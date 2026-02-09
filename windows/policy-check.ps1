$ErrorActionPreference = "Stop"

Write-Host "== SMB Client Configuration =="
Get-SmbClientConfiguration | Format-List | Out-Host

Write-Host "`n== SMB Mapped Connections (if any) =="
cmd /c "net use" | Out-Host

Write-Host "`n== WebClient Service (WebDAV) =="
Get-Service WebClient | Format-List | Out-Host

Write-Host "`n== Network Provider Order =="
$key = "HKLM:\SYSTEM\CurrentControlSet\Control\NetworkProvider\Order"
(Get-ItemProperty -Path $key -Name ProviderOrder).ProviderOrder | Out-Host
