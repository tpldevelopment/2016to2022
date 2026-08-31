<#
.SYNOPSIS
    Install all pending Microsoft updates. Deploy as a SEPARATE PDQ package
    AFTER Verify-Upgrade.ps1 confirms the server is on 2022.

.NOTES
    - Uses PSWindowsUpdate (installs it from PSGallery if missing).
    - -IgnoreReboot: let a PDQ Reboot step (or you) do the reboot, so PDQ
      doesn't lose the machine mid-step.
    - If servers get updates from WSUS/ConfigMgr only, this still works -
      PSWindowsUpdate uses whatever update source the box is pointed at.

    Exit codes: 0 = done (reboot may be needed), 20 = PSWindowsUpdate install failed
#>
$LogDir = 'C:\Windows\Temp\Win2022Upgrade'
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
Start-Transcript -Path "$LogDir\updates.log" -Append

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        }
        Install-Module PSWindowsUpdate -Force -Confirm:$false
    } catch {
        Write-Output "FAIL [20]: Could not install PSWindowsUpdate: $_"
        Stop-Transcript
        exit 20
    }
}
Import-Module PSWindowsUpdate

Write-Output '--- Pending updates ---'
Get-WindowsUpdate -MicrosoftUpdate | Format-Table KB, Size, Title -AutoSize

Write-Output '--- Installing ---'
Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot | Format-Table KB, Result, Title -AutoSize

if (Get-WURebootStatus -Silent) {
    Write-Output 'REBOOT REQUIRED to finish updates.'
} else {
    Write-Output 'No reboot required.'
}
Stop-Transcript
exit 0
