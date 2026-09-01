<#
.SYNOPSIS
    Post-upgrade check. Deploy with PDQ after the server settles down.
    Exit 0 = on Server 2022. Exit 1 = still not upgraded.
#>
$os = Get-CimInstance Win32_OperatingSystem
Write-Output "OS:    $($os.Caption)"
Write-Output "Build: $($os.BuildNumber)"
Write-Output "Boot:  $($os.LastBootUpTime)"

# Compare auto-start services against the pre-upgrade baseline, if one exists
$baseline = 'C:\Temp\PreUpgrade-Services.json'
if (Test-Path $baseline) {
    $before = (Get-Content $baseline -Raw | ConvertFrom-Json) | Where-Object { $_.Status -eq 'Running' }
    $missing = foreach ($svc in $before) {
        $now = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if (-not $now) { "$($svc.Name) ($($svc.DisplayName)) - GONE after upgrade" }
        elseif ($now.Status -ne 'Running') { "$($svc.Name) ($($svc.DisplayName)) - was running, now $($now.Status)" }
    }
    if ($missing) {
        Write-Output 'SERVICE DIFF vs pre-upgrade baseline:'
        $missing | ForEach-Object { Write-Output "  -> $_" }
    } else {
        Write-Output 'Service diff: all previously-running auto services are running.'
    }
} else {
    Write-Output 'No pre-upgrade service baseline found (Preflight-Check.ps1 not run) - skipping service diff.'
}

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
