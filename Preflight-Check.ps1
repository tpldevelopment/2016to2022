<#
.SYNOPSIS
    Pre-upgrade readiness checklist. REPORT-ONLY - changes nothing except
    writing a service baseline file for post-upgrade comparison.
    Deploy via PDQ to any candidate box before scheduling its upgrade.

.NOTES
    Checks:
      1. Free disk space on C: (>= 60GB)
      2. Edition (Datacenter vs Standard) + OS version
      3. Automatic services that are NOT currently running
      4. Snapshot reminder (VM detected or physical) - manual step

    Saves baseline: C:\Temp\PreUpgrade-Services.json (auto-start services +
    run state) so Verify-Upgrade can diff services after the upgrade.

    Exit codes:
      0  = READY (all checks pass; snapshot still manual)
      21 = low disk
      22 = not Server 2016 Datacenter
      23 = ready except auto-start services not running (review list)
#>

$MinFreeGB = 60
$result = [ordered]@{}
$failCode = 0

Write-Output '===== PRE-UPGRADE CHECKLIST ====='
Write-Output "Host: $env:COMPUTERNAME   Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Output ''

# --- 1. Disk space ---
$freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
$diskOK = $freeGB -ge $MinFreeGB
$result['Disk'] = "$freeGB GB free (need $MinFreeGB)"
Write-Output ("[{0}] 1. Disk: {1}" -f ($(if ($diskOK) {'PASS'} else {'FAIL'})), $result['Disk'])
if (-not $diskOK) { $failCode = 21 }

# --- 2. Edition / version ---
$os = Get-CimInstance Win32_OperatingSystem
$isDC   = $os.Caption -match 'Datacenter'
$is2016 = $os.Caption -match 'Server 2016'
$result['OS'] = $os.Caption
Write-Output ("[{0}] 2. Edition: {1}" -f ($(if ($isDC -and $is2016) {'PASS'} else {'FAIL'})), $os.Caption)
if (-not ($isDC -and $is2016)) {
    if ($os.Caption -match 'Standard') { Write-Output '         -> STANDARD edition: this kit targets Datacenter. Different pkey/plan needed.' }
    if ($os.Caption -match 'Server 2022') { Write-Output '         -> Already 2022: nothing to do.' }
    if ($failCode -eq 0) { $failCode = 22 }
}

# --- 3. Auto-start services ---
$auto = Get-Service | Where-Object { $_.StartType -eq 'Automatic' }
$stopped = $auto | Where-Object { $_.Status -ne 'Running' }
# Ignore services designed to exit when idle (trigger-start/delayed ones that show stopped)
$ignore = 'edgeupdate|gupdate|MapsBroker|RemoteRegistry|sppsvc|TrustedInstaller|WbioSrvc|wuauserv|BITS|CDPSvc|tiledatamodelsvc|dosvc'
$stoppedReal = $stopped | Where-Object { $_.Name -notmatch $ignore }
Write-Output ("[{0}] 3. Auto-start services: {1} total, {2} not running ({3} after ignoring idle-exit services)" -f `
    ($(if ($stoppedReal.Count -eq 0) {'PASS'} else {'WARN'})), $auto.Count, $stopped.Count, $stoppedReal.Count)
if ($stoppedReal.Count -gt 0) {
    $stoppedReal | ForEach-Object { Write-Output "         -> NOT RUNNING: $($_.Name) ($($_.DisplayName))" }
    if ($failCode -eq 0) { $failCode = 23 }
}

# Baseline for post-upgrade diff (all auto services + state)
New-Item -Path 'C:\Temp' -ItemType Directory -Force | Out-Null
$auto | Select-Object Name, DisplayName, Status |
    ConvertTo-Json | Set-Content 'C:\Temp\PreUpgrade-Services.json'
Write-Output '         Baseline saved: C:\Temp\PreUpgrade-Services.json'

# --- 4. Snapshot (manual) ---
$model = (Get-CimInstance Win32_ComputerSystem)
$isVM = $model.Model -match 'Virtual|VMware'
Write-Output ("[TODO] 4. Snapshot: {0} ({1} {2}) - take a snapshot/checkpoint BEFORE deploying the upgrade package" -f `
    ($(if ($isVM) {'VM - snapshot from the hypervisor'} else {'PHYSICAL - ensure a backup/image exists'})), $model.Manufacturer, $model.Model)

Write-Output ''
if ($failCode -eq 0) {
    Write-Output 'RESULT: READY (pending manual snapshot).'
} else {
    Write-Output "RESULT: NOT READY (exit $failCode)."
}
exit $failCode
