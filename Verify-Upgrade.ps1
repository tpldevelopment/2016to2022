<#
.SYNOPSIS
    Post-upgrade check. Deploy with PDQ after the server settles down.
    Exit 0 = on Server 2022. Exit 1 = still not upgraded.
#>
$os = Get-CimInstance Win32_OperatingSystem
Write-Output "OS:    $($os.Caption)"
Write-Output "Build: $($os.BuildNumber)"
Write-Output "Boot:  $($os.LastBootUpTime)"

# Server 2022 = build 20348
if ([int]$os.BuildNumber -ge 20348) {
    Write-Output 'RESULT: Upgrade confirmed - Server 2022.'
    # clean up media + one-shot task
    schtasks /Delete /TN 'Win2022InPlaceUpgrade' /F 2>$null | Out-Null
    Remove-Item 'C:\Temp\Server2022Media' -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}
Write-Output 'RESULT: NOT upgraded yet. Check C:\$WINDOWS.~BT\Sources\Panther\setupact.log'
exit 1
