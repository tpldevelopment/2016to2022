<#
.SYNOPSIS
    Steps 2-5a of the Gen2 conversion, automated: BitLocker check/suspend,
    mbr2gpt validate + convert inside the guest (via PowerShell Direct),
    reboot, wait for it to come back. Emails a report.

    !!! RUN YOUR MANUAL BACKUP FIRST (step 1). This script converts the disk. !!!

    After this succeeds, run:  .\Convert-ToGen2.ps1 -VMName <name>

.USAGE
    .\Prepare-Gen2.ps1 -VMName VM01
    (prompts for guest admin credentials)

    .\Prepare-Gen2.ps1 -VMName VM01 -WhatIf
    Dry run: connects, checks BitLocker state, runs mbr2gpt /validate
    (read-only) in the guest, reports what WOULD happen. Converts nothing,
    reboots nothing, no email.

.PREREQS
    - SCVMM console module on this box; WinRM/admin to the owning Hyper-V host
    - Guest must be running, 64-bit, Server 2019+/Win10+ (needs mbr2gpt.exe)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName
)

# ==================== EDIT THESE ====================
$VMMServer  = 'SCVMM01.yourdomain.local'
$SmtpServer = 'smtp.yourdomain.local'
$SmtpPort   = 25
$MailFrom   = 'hyperv-automation@yourdomain.local'
$MailTo     = @('you@yourdomain.local')
# ====================================================

$log = New-Object System.Collections.Generic.List[string]
function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    $log.Add($line)
}
function Send-Report($subject) {
    try {
        Send-MailMessage -SmtpServer $SmtpServer -Port $SmtpPort `
            -From $MailFrom -To $MailTo -Subject $subject -Body ($log -join "`r`n")
    } catch { Write-Warning "Email failed: $_" }
}

# One prompt: your own password. Same account is used for the in-guest steps.
$guestCred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message "Password for $env:USERDOMAIN\$env:USERNAME"

try {
    Import-Module VirtualMachineManager -ErrorAction Stop
    Get-SCVMMServer -ComputerName $VMMServer -ErrorAction Stop | Out-Null

    $vm = Get-SCVirtualMachine -Name $VMName -ErrorAction Stop
    if ($vm.Generation -eq 2) { throw "'$VMName' is already Generation 2." }
    if ($vm.VirtualMachineState -ne 'Running') { throw "'$VMName' must be RUNNING for in-guest conversion (state: $($vm.VirtualMachineState))." }
    $hvHost = $vm.VMHost.Name
    $doIt = $PSCmdlet.ShouldProcess($VMName, 'mbr2gpt /convert + reboot')
    Log "'$VMName' on host $hvHost - $(if ($doIt) { 'starting in-guest conversion' } else { 'DRY RUN (validate only)' }) via PowerShell Direct."

    $result = Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($name, $cred, $doIt)
        Invoke-Command -VMName $name -Credential $cred -ScriptBlock {
            param($doIt)
            $out = New-Object System.Collections.Generic.List[string]

            # BitLocker: check; suspend only on a real run
            $blv = Get-BitLockerVolume -MountPoint C: -ErrorAction SilentlyContinue
            if ($blv -and $blv.ProtectionStatus -eq 'On') {
                if ($doIt) {
                    Suspend-BitLocker -MountPoint C: | Out-Null
                    $out.Add('BitLocker: was ON - suspended for conversion (re-arms on reboot).')
                } else {
                    $out.Add('BitLocker: ON - WOULD suspend for conversion.')
                }
            } else {
                $out.Add('BitLocker: off/not present - nothing to do.')
            }

            # mbr2gpt present?
            if (-not (Test-Path "$env:windir\System32\mbr2gpt.exe")) {
                throw 'mbr2gpt.exe not found - guest OS too old (needs 2019+/Win10+). Upgrade the OS first.'
            }

            # Validate (read-only, runs in both modes)
            $v = & "$env:windir\System32\mbr2gpt.exe" /validate /allowFullOS 2>&1
            $out.Add("validate: $($v -join ' | ')")
            if ($LASTEXITCODE -ne 0) {
                throw "mbr2gpt VALIDATE FAILED (exit $LASTEXITCODE) - disk not converted. See C:\Windows\mbr2gpt.log in the guest."
            }
            if (-not $doIt) {
                $out.Add('WOULD run: mbr2gpt /convert /allowFullOS, then reboot. (validation passed - real run should succeed)')
                return $out
            }

            # Convert
            $c = & "$env:windir\System32\mbr2gpt.exe" /convert /allowFullOS 2>&1
            $out.Add("convert: $($c -join ' | ')")
            if ($LASTEXITCODE -ne 0) {
                throw "mbr2gpt CONVERT FAILED (exit $LASTEXITCODE) - see C:\Windows\mbr2gpt.log in the guest."
            }
            $out.Add('Conversion complete - disk is now GPT/UEFI.')
            $out
        } -ArgumentList $doIt
    } -ArgumentList $VMName, $guestCred, $doIt
    $result | ForEach-Object { Log $_ }

    if (-not $doIt) {
        Log "DRY RUN complete - nothing was changed, no email sent."
        exit 0
    }

    # Reboot (step 5a) and wait for the guest to come back
    Log "Rebooting '$VMName' to confirm it still boots..."
    Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($name, $cred)
        Invoke-Command -VMName $name -Credential $cred -ScriptBlock { Restart-Computer -Force }
        # wait for heartbeat: down, then back up
        Start-Sleep -Seconds 20
        for ($i = 0; $i -lt 60; $i++) {
            $hb = (Get-VM -Name $name).Heartbeat
            if ("$hb" -like 'Ok*') { return "Heartbeat OK after ~$((20 + $i*10))s" }
            Start-Sleep -Seconds 10
        }
        throw "'$name' did not report a healthy heartbeat within 10 min of reboot - check console."
    } -ArgumentList $VMName, $guestCred | ForEach-Object { Log $_ }

    Log "SUCCESS - '$VMName' converted and rebooted clean. Next: .\Convert-ToGen2.ps1 -VMName $VMName"
    Send-Report "Gen2 prep OK: $VMName (mbr2gpt done)"
}
catch {
    Log "FAILED: $_"
    Send-Report "Gen2 prep FAILED: $VMName"
    exit 1
}
