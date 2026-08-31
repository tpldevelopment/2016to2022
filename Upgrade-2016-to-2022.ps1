<#
.SYNOPSIS
    In-place upgrade: Windows Server 2016 Datacenter -> Server 2022 Datacenter.
    Designed to be pushed by PDQ Deploy (PowerShell step).

.NOTES
    - Copies extracted Server 2022 media from a share to local disk, then
      launches setup.exe DETACHED via a one-shot scheduled task.
    - The script exits as soon as setup is launched. PDQ "Success" means
      "upgrade launched", NOT "upgrade finished". The server reboots itself
      several times over the next 45-90 minutes.
    - Verify afterwards with Verify-Upgrade.ps1 (or PDQ Inventory OS scan).

    Exit codes:
      0  = upgrade launched OK (or already on 2022)
      10 = OS is not Server 2016 Datacenter
      11 = not enough free disk space
      12 = pending reboot detected (reboot first, then redeploy)
      13 = media share unreachable / setup.exe not found
      14 = media copy (robocopy) failed
      15 = could not find Datacenter index in install.wim/esd
      16 = failed to create/start the upgrade scheduled task
#>

# ==================== EDIT THESE ====================
$MediaSource = '\\FILESERVER\Deploy\Server2022'   # extracted ISO contents (setup.exe at root)
$LocalMedia  = 'C:\Temp\Server2022Media'
$MinFreeGB   = 60                                 # MS minimum is ~32GB; 60 is a safe floor
$ProductKey  = ''                                 # MAK key: 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX'. Leave '' for KMS/volume media.
# ====================================================

$LogDir = 'C:\Windows\Temp\Win2022Upgrade'
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
Start-Transcript -Path "$LogDir\launch.log" -Append

function Fail($code, $msg) {
    Write-Output "FAIL [$code]: $msg"
    Stop-Transcript
    exit $code
}

# --- Pre-flight: OS check ---
$os = Get-CimInstance Win32_OperatingSystem
Write-Output "Current OS: $($os.Caption) build $($os.BuildNumber)"

if ($os.Caption -match 'Server 2022') {
    Write-Output 'Already on Server 2022. Nothing to do.'
    Stop-Transcript
    exit 0
}
if ($os.Caption -notmatch 'Server 2016' -or $os.Caption -notmatch 'Datacenter') {
    Fail 10 "Expected Server 2016 Datacenter, found: $($os.Caption)"
}

# --- Pre-flight: disk space ---
$freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
Write-Output "Free space on C: ${freeGB}GB"
if ($freeGB -lt $MinFreeGB) {
    Fail 11 "Need ${MinFreeGB}GB free, have ${freeGB}GB"
}

# --- Pre-flight: pending reboot ---
$pending = $false
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending = $true }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true }
if ($pending) {
    Fail 12 'Pending reboot detected. Reboot this server, then redeploy.'
}

# --- Pre-flight: media reachable ---
if (-not (Test-Path "$MediaSource\setup.exe")) {
    Fail 13 "Cannot find setup.exe at $MediaSource"
}

# --- Copy media local (upgrade must survive loss of network) ---
Write-Output "Copying media: $MediaSource -> $LocalMedia"
robocopy $MediaSource $LocalMedia /MIR /R:2 /W:5 /NP /NFL /NDL | Out-Null
if ($LASTEXITCODE -ge 8) {
    Fail 14 "Robocopy failed with exit code $LASTEXITCODE"
}
Write-Output 'Media copy complete.'

# --- Find the Datacenter (Desktop Experience) image index ---
$wim = Get-ChildItem "$LocalMedia\sources" -Include 'install.wim','install.esd' -Recurse |
       Select-Object -First 1
if (-not $wim) { Fail 15 'No install.wim/install.esd found in media.' }

$images = Get-WindowsImage -ImagePath $wim.FullName
$target = $images | Where-Object {
    $_.ImageName -match 'Datacenter' -and $_.ImageName -match 'Desktop'
} | Select-Object -First 1
if (-not $target) { Fail 15 "No 'Datacenter (Desktop Experience)' image found. Images: $($images.ImageName -join '; ')" }
Write-Output "Using image index $($target.ImageIndex): $($target.ImageName)"

# --- Launch setup.exe detached via one-shot scheduled task ---
# If PDQ ran setup directly, the deployment would hang until the first
# reboot killed it. A SYSTEM scheduled task survives the PDQ session ending.
$setupArgs = '/auto upgrade /quiet /eula accept /imageindex {0} /dynamicupdate disable /compat ignorewarning /showoobe none /telemetry disable /copylogs {1}' -f $target.ImageIndex, $LogDir
if ($ProductKey) { $setupArgs += " /pkey $ProductKey" }

$taskName = 'Win2022InPlaceUpgrade'
schtasks /Delete /TN $taskName /F 2>$null | Out-Null

$action    = New-ScheduledTaskAction -Execute "$LocalMedia\setup.exe" -Argument $setupArgs
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 6)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 15
    $setupProc = Get-Process -Name 'setup','setupprep','setuphost' -ErrorAction SilentlyContinue
    if (-not $setupProc) {
        Fail 16 'Scheduled task started but no setup process is running. Check task history.'
    }
} catch {
    Fail 16 "Scheduled task error: $_"
}

Write-Output '=================================================='
Write-Output 'UPGRADE LAUNCHED. Server will reboot itself several'
Write-Output 'times over the next 45-90 minutes. Do not touch it.'
Write-Output "Setup logs: $LogDir and C:\`$WINDOWS.~BT\Sources\Panther"
Write-Output '=================================================='
Stop-Transcript
exit 0
