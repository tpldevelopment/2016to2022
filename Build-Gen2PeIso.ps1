<#
.SYNOPSIS
    ONE-TIME build of gen2convert.iso - a WinPE boot ISO that automatically
    runs mbr2gpt against the only attached disk, then powers off.
    Convert-ToGen2.ps1 boots its staging VM from this ISO; no credentials,
    no host setting changes, no interaction.

.PREREQS (on the box you run this from - e.g. your admin box)
    - Windows ADK + the "WinPE add-on" installed (both free):
        winget install Microsoft.WindowsADK
        winget install Microsoft.ADKPEAddon
    - Run elevated.

.OUTPUT
    C:\gen2pe\gen2convert.iso  - copy it somewhere every Hyper-V host can
    read (e.g. a CSV path) and put that path in config.json as "PeIsoPath".
#>

$ErrorActionPreference = 'Stop'
$work = 'C:\gen2pe'
$adk  = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit"
$env2 = "$adk\Deployment Tools\DandISetEnv.bat"

if (-not (Test-Path $env2)) { throw "ADK Deployment Tools not found ($env2). Install the ADK + WinPE add-on first (see .PREREQS)." }
if (-not (Test-Path "$adk\Windows Preinstallation Environment")) { throw 'WinPE add-on not found. Install Microsoft.ADKPEAddon.' }
if (Test-Path $work) { throw "$work already exists - delete it to rebuild." }

Write-Host '1/5 Creating WinPE working copy...'
cmd /c "`"$env2`" && copype amd64 $work" | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$work\media\sources\boot.wim")) { throw "copype failed (exit $LASTEXITCODE)." }

Write-Host '2/5 Mounting boot.wim...'
$mount = "$work\mount"
New-Item -Path $mount -ItemType Directory -Force | Out-Null
dism /Mount-Image /ImageFile:"$work\media\sources\boot.wim" /Index:1 /MountDir:"$mount" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "dism mount failed (exit $LASTEXITCODE)." }

try {
    Write-Host '3/5 Injecting mbr2gpt + autorun script...'
    # mbr2gpt: take this machine's copy (2019+/Win10+). PE may already have
    # one; overwriting with a known-good copy is harmless.
    Copy-Item "$env:windir\System32\mbr2gpt.exe" "$mount\Windows\System32\mbr2gpt.exe" -Force

    # startnet.cmd = what PE runs at boot. Exactly one disk is attached by
    # the conversion script, so /disk:0 is deterministic. Logs are copied
    # onto the disk's Windows volume for post-mortem, then PE powers off.
    @'
@echo off
wpeinit
echo === gen2convert PE %date% %time% === > X:\convert.log
mbr2gpt /validate /disk:0 >> X:\convert.log 2>&1
if errorlevel 1 (
    echo VALIDATE FAILED errorlevel %errorlevel% >> X:\convert.log
    goto :save
)
mbr2gpt /convert /disk:0 >> X:\convert.log 2>&1
if errorlevel 1 (
    echo CONVERT FAILED errorlevel %errorlevel% >> X:\convert.log
) else (
    echo CONVERT OK >> X:\convert.log
    echo OK > X:\convert.ok
)
:save
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist %%D:\Windows (
        copy /y X:\convert.log %%D:\gen2convert-pe.log > nul
        if exist X:\convert.ok copy /y X:\convert.ok %%D:\gen2convert-ok.marker > nul
        copy /y X:\Windows\setupact.log %%D:\gen2convert-setupact.log > nul 2>&1
        copy /y X:\Windows\setuperr.log %%D:\gen2convert-setuperr.log > nul 2>&1
    )
)
wpeutil shutdown
'@ | Set-Content "$mount\Windows\System32\startnet.cmd" -Encoding ASCII
}
finally {
    Write-Host '4/5 Committing boot.wim...'
    dism /Unmount-Image /MountDir:"$mount" /Commit | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dism unmount/commit failed (exit $LASTEXITCODE) - do NOT use any ISO built from this run." }
}

Write-Host '5/5 Building ISO...'
cmd /c "`"$env2`" && MakeWinPEMedia /ISO $work $work\gen2convert.iso" | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$work\gen2convert.iso")) { throw "MakeWinPEMedia failed (exit $LASTEXITCODE)." }

Write-Host ''
Write-Host "DONE: $work\gen2convert.iso"
Write-Host 'Next: copy it to storage every Hyper-V host can read (e.g. a CSV path),'
Write-Host 'then add to config.json:  "PeIsoPath": "<path as seen from the HOST>"'
