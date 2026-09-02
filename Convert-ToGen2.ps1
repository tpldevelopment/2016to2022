<#
.SYNOPSIS
    Convert a Hyper-V Gen1 VM to Gen2 via SCVMM using a COPY-FIRST staging
    workflow. The original VM and its disks are NEVER modified.

    Flow:
      0. Preflight (all read-only, runs before anything is touched)
      1. Graceful shutdown of the original VM
      2. Copy disks to <parent>\<name>-temp\ (VHD sources are converted to VHDX)
      3. Isolated Gen1 staging VM (no NIC) boots the COPIED boot disk;
         BitLocker suspended + mbr2gpt validate/convert run inside it;
         staging then SHUTS DOWN (never rebooted - a BIOS VM cannot boot GPT)
      4. Staging shell removed; Gen2 VM <name>-temp built on the converted
         copies with the original's CPU/RAM/NIC settings; Secure Boot on
      5. Start (optional), VMM refresh, email report

    Rollback at ANY point: the original Gen1 VM still exists with untouched
    MBR disks - start it and delete the -temp artifacts.

.USAGE
    .\Convert-ToGen2.ps1 -VMName VM01
    .\Convert-ToGen2.ps1 -VMName VM01 -WhatIf     # full preflight + plan, changes nothing

.PREREQS
    - A verified manual backup of the VM (do this first, always)
    - SCVMM console module on this box; WinRM/admin to the owning Hyper-V host
    - Guest OS 64-bit with mbr2gpt.exe (Server 2019+/Win10+)
    - NOT for clustered/HA VMs (script refuses; those need the HA-aware manual path)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName
)

# ==================== EDIT THESE ====================
$VMMServer  = 'SCVMM01.yourdomain.local'          # SCVMM management server
$SmtpServer = 'smtp.yourdomain.local'             # non-secure relay (site standard)
$SmtpPort   = 25
$MailFrom   = 'hyperv-automation@yourdomain.local'
$MailTo     = @('you@yourdomain.local')
$StartAfter = $true                               # start the -temp VM when built
# ====================================================

$ErrorActionPreference = 'Stop'
$NewName     = "$VMName-temp"
$StagingName = "$VMName-staging"

$log = New-Object System.Collections.Generic.List[string]
function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    $log.Add($line)
}
function Send-Report($subject) {
    try {
        Send-MailMessage -SmtpServer $SmtpServer -Port $SmtpPort `
            -From $MailFrom -To $MailTo -Subject $subject -Body ($log -join "`r`n") `
            -ErrorAction Stop -WarningAction SilentlyContinue
    } catch { Write-Warning "Email failed: $_" }
}

# One prompt: your own password. Used for PowerShell Direct into the guest/staging VM.
$guestCred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message "Password for $env:USERDOMAIN\$env:USERNAME"

try {
    Import-Module VirtualMachineManager -ErrorAction Stop
    Get-SCVMMServer -ComputerName $VMMServer -ErrorAction Stop | Out-Null
    Log "Connected to VMM: $VMMServer"

    # =========================================================================
    # PHASE 0 - PREFLIGHT (read-only; nothing below this line mutates anything
    # until the phase banner says so)
    # =========================================================================

    # Exactly one VM by this name (VMM names are not unique across hosts/clouds)
    $vms = @(Get-SCVirtualMachine -Name $VMName)
    if ($vms.Count -eq 0) { throw "VM '$VMName' not found in VMM." }
    if ($vms.Count -gt 1) {
        throw "VM name '$VMName' matches $($vms.Count) VMs in VMM ($(($vms | ForEach-Object { "$($_.ID) on $($_.VMHost)" }) -join '; ')). Names must resolve uniquely - rename or handle manually."
    }
    $vm = $vms[0]
    $hvHost = $vm.VMHost.Name
    Log "Resolved: '$VMName' ID $($vm.ID) on host $hvHost | Gen $($vm.Generation) | $($vm.VirtualMachineState) | vCPU $($vm.CPUCount) | RAM $($vm.Memory)MB"

    if ($vm.Generation -eq 2) { throw "'$VMName' is already Generation 2." }
    if ($vm.IsHighlyAvailable) {
        throw "'$VMName' is CLUSTERED/HA. This script does not recreate cluster roles or HA settings - convert HA VMs via the manual VMM path."
    }
    if (Get-SCVirtualMachine -Name $NewName)     { throw "'$NewName' already exists - clean up first." }
    if (Get-SCVirtualMachine -Name $StagingName) { throw "'$StagingName' already exists - clean up first." }
    if ($vm.VMCheckpoints.Count -gt 0) {
        throw "'$VMName' has $($vm.VMCheckpoints.Count) VMM checkpoint(s). Delete them, wait for the disk merge to finish, rerun."
    }

    # NIC spec from VMM (switch, VLAN, MAC). VMM VM-network-based adapters are
    # rebuilt by host vSwitch name - flagged in the report.
    $nicSpec = @($vm.VirtualNetworkAdapters | ForEach-Object {
        @{ Switch = "$($_.VirtualNetwork)"; VlanEnabled = $_.VLanEnabled; Vlan = $_.VLanID
           Mac = $_.MACAddress; MacStatic = ($_.MACAddressType -eq 'Static')
           VMNetwork = "$($_.VMNetwork)" } })
    foreach ($n in $nicSpec) {
        if ([string]::IsNullOrWhiteSpace($n.Switch)) {
            throw "A NIC on '$VMName' has no VirtualNetwork (VM-network-only binding: '$($n.VMNetwork)'). This script rebuilds NICs by host vSwitch name and cannot map that - handle this VM manually."
        }
        Log "NIC: switch '$($n.Switch)' VLAN $(if ($n.VlanEnabled) { $n.Vlan } else { 'none' }) MAC $($n.Mac) ($(if ($n.MacStatic) {'static'} else {'dynamic - guest may re-detect NIC'}))"
    }

    # Disk inventory FROM THE HOST (controller positions), plus chain + format
    # checks. Gen1 BIOS boots IDE 0:0 - that disk is the one mbr2gpt converts.
    $diskInfo = Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($name)
        $ErrorActionPreference = 'Stop'
        $drives = Get-VMHardDiskDrive -VMName $name
        foreach ($d in $drives) {
            $vhd = Get-VHD -Path $d.Path
            [pscustomobject]@{
                Path        = $d.Path
                Controller  = "$($d.ControllerType) $($d.ControllerNumber):$($d.ControllerLocation)"
                IsBoot      = ($d.ControllerType -eq 'IDE' -and $d.ControllerNumber -eq 0 -and $d.ControllerLocation -eq 0)
                Format      = "$($vhd.VhdFormat)"
                ParentPath  = $vhd.ParentPath
                FileSizeGB  = [math]::Round($vhd.FileSize / 1GB, 1)
            }
        }
    } -ArgumentList $VMName

    $diskInfo | ForEach-Object { Log "Disk: $($_.Controller) $($_.Path) [$($_.Format), $($_.FileSizeGB)GB$(if ($_.IsBoot) { ', BOOT' })]" }
    $boot = @($diskInfo | Where-Object IsBoot)
    if ($boot.Count -ne 1) {
        throw "Could not identify exactly one boot disk at IDE 0:0 (found $($boot.Count)). Nonstandard boot layout - handle manually."
    }
    $chained = @($diskInfo | Where-Object { $_.ParentPath })
    if ($chained.Count -gt 0) {
        throw "Differencing/checkpoint chain detected (parent set on: $(($chained.Path) -join ', ')). Merge chains before converting - copying a child without its parent produces a broken disk."
    }

    # Space check on the target volume - ENFORCED on real runs, not just -WhatIf
    $parentDir = Split-Path (Split-Path $boot[0].Path)
    $newDir    = Join-Path $parentDir $NewName
    $needGB    = [math]::Round(($diskInfo | Measure-Object FileSizeGB -Sum).Sum * 1.1, 1)  # +10% slack
    $freeGB = Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($p)
        $ErrorActionPreference = 'Stop'
        if (Test-Path $p) { throw "Target folder already exists: $p" }
        [math]::Round((Get-PSDrive $p.Substring(0,1)).Free / 1GB, 1)
    } -ArgumentList $newDir
    Log "Target: $newDir | need ~${needGB}GB, volume has ${freeGB}GB free"
    if ($freeGB -lt $needGB) { throw "Not enough space on the target volume (need ~${needGB}GB, have ${freeGB}GB)." }

    # BitLocker + mbr2gpt presence probe in the RUNNING guest - FAIL CLOSED:
    # any error here aborts; 'unknown' is never treated as 'off'.
    $blStatus = 'not checked (VM not running)'
    if ($vm.VirtualMachineState -eq 'Running') {
        $probe = Invoke-Command -ComputerName $hvHost -ScriptBlock {
            param($name, $cred)
            $ErrorActionPreference = 'Stop'
            Invoke-Command -VMName $name -Credential $cred -ScriptBlock {
                $ErrorActionPreference = 'Stop'
                if (-not (Test-Path "$env:windir\System32\mbr2gpt.exe")) {
                    throw 'mbr2gpt.exe not found - guest OS too old (needs 2019+/Win10+). Upgrade the OS first.'
                }
                $vols = @()
                if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
                    $vols = @(Get-BitLockerVolume | Where-Object { $_.ProtectionStatus -eq 'On' } |
                              ForEach-Object { "$($_.MountPoint) [$($_.KeyProtector.KeyProtectorType -join '+')]" })
                }
                [pscustomobject]@{ BitLockerOn = $vols; OS = (Get-CimInstance Win32_OperatingSystem).Caption }
            }
        } -ArgumentList $VMName, $guestCred
        $blStatus = if ($probe.BitLockerOn.Count) { "ON: $($probe.BitLockerOn -join ', ')" } else { 'off on all volumes' }
        Log "Guest probe OK: $($probe.OS) | mbr2gpt present | BitLocker $blStatus"
        if ($probe.BitLockerOn.Count) {
            Log "WARNING: BitLocker is ON. VERIFY RECOVERY KEYS ARE ESCROWED (AD/backup) before proceeding - protectors must be re-validated after conversion."
        }
    } else {
        Log "'$VMName' is $($vm.VirtualMachineState) - guest probe skipped; mbr2gpt/BitLocker will be checked in staging."
    }

    Log "PREFLIGHT PASSED."

    # ---- Dry run stops here -------------------------------------------------
    if (-not $PSCmdlet.ShouldProcess($VMName, "copy-first Gen2 conversion -> '$NewName'")) {
        foreach ($d in $diskInfo) {
            $act = if ($d.Format -eq 'VHD') { 'convert VHD->VHDX into' } else { 'copy to' }
            Log "WOULD $act $newDir : $($d.Path) ($($d.FileSizeGB)GB)"
        }
        Log "WOULD: shut down '$VMName' | stage+convert boot disk (isolated, no NIC) | build Gen2 '$NewName' ($($vm.CPUCount) vCPU, $($vm.Memory)MB, $($nicSpec.Count) NIC(s), Secure Boot on)$(if ($StartAfter) { ' | start it' })"
        Log "DRY RUN complete - nothing was changed, no email sent."
        exit 0
    }

    # =========================================================================
    # PHASE 1 - SHUT DOWN THE ORIGINAL (its disks are never modified after this)
    # =========================================================================
    if ($vm.VirtualMachineState -ne 'PowerOff') {
        Log "Shutting down '$VMName' gracefully..."
        Stop-SCVirtualMachine -VM $vm -Shutdown -ErrorAction Stop | Out-Null
        for ($i = 0; $i -lt 60 -and $vm.VirtualMachineState -ne 'PowerOff'; $i++) {
            Start-Sleep -Seconds 10
            $vm = Get-SCVirtualMachine -Name $VMName
        }
        if ($vm.VirtualMachineState -ne 'PowerOff') { throw "'$VMName' did not shut down within 10 minutes - aborting (nothing was changed)." }
        Log "'$VMName' is powered off."
    }

    # =========================================================================
    # PHASE 2 - COPY DISKS (VHD sources become VHDX); originals untouched
    # =========================================================================
    $copyPlan = $diskInfo | ForEach-Object {
        $leaf = if ($_.Format -eq 'VHD') { [IO.Path]::GetFileNameWithoutExtension($_.Path) + '.vhdx' } else { Split-Path $_.Path -Leaf }
        [pscustomobject]@{ Src = $_.Path; Dst = (Join-Path $newDir $leaf); Fmt = $_.Format; IsBoot = $_.IsBoot }
    }
    Log "Copying $($copyPlan.Count) disk(s) to $newDir ..."
    Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($plan, $dir)
        $ErrorActionPreference = 'Stop'
        New-Item -Path $dir -ItemType Directory | Out-Null
        foreach ($p in $plan) {
            if ($p.Fmt -eq 'VHD') { Convert-VHD -Path $p.Src -DestinationPath $p.Dst -VHDType Dynamic }
            else                  { Copy-Item -Path $p.Src -Destination $p.Dst }
            if (-not (Test-Path $p.Dst)) { throw "Copy verification failed: $($p.Dst) missing" }
        }
    } -ArgumentList $copyPlan, $newDir
    $bootCopy = ($copyPlan | Where-Object IsBoot).Dst
    Log "Copy complete. Boot disk copy: $bootCopy"

    # =========================================================================
    # PHASE 3 - STAGING: isolated Gen1 VM boots the COPY; mbr2gpt runs there;
    # staging SHUTS DOWN afterward (a BIOS VM cannot boot the GPT result)
    # =========================================================================
    Log "Creating isolated staging VM '$StagingName' (no network)..."
    $stageResult = Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($sName, $bootDisk, $dir, $cred)
        $ErrorActionPreference = 'Stop'
        $out = New-Object System.Collections.Generic.List[string]
        New-VM -Name $sName -Generation 1 -Path $dir -MemoryStartupBytes 4GB -VHDPath $bootDisk | Out-Null
        Get-VMNetworkAdapter -VMName $sName | Remove-VMNetworkAdapter     # fully isolated
        Start-VM -Name $sName
        $out.Add('Staging VM started (isolated).')

        # Wait for heartbeat
        $up = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 10
            if ("$((Get-VM -Name $sName).Heartbeat)" -like 'Ok*') { $up = $true; break }
        }
        if (-not $up) { throw "Staging VM never reached a healthy heartbeat (10 min) - copied disk may not boot. Original VM is intact." }
        $out.Add('Staging heartbeat OK - running conversion inside it.')

        $conv = Invoke-Command -VMName $sName -Credential $cred -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $r = New-Object System.Collections.Generic.List[string]
            # BitLocker: fail closed, all volumes
            if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
                foreach ($v in (Get-BitLockerVolume | Where-Object { $_.ProtectionStatus -eq 'On' })) {
                    Suspend-BitLocker -MountPoint $v.MountPoint | Out-Null
                    $chk = Get-BitLockerVolume -MountPoint $v.MountPoint
                    if ($chk.ProtectionStatus -eq 'On') { throw "BitLocker suspension FAILED on $($v.MountPoint) - aborting." }
                    $r.Add("BitLocker suspended on $($v.MountPoint).")
                }
            }
            $v = & "$env:windir\System32\mbr2gpt.exe" /validate /allowFullOS 2>&1
            $r.Add("validate: $($v -join ' | ')")
            if ($LASTEXITCODE -ne 0) { throw "mbr2gpt VALIDATE failed (exit $LASTEXITCODE). Copied disk unchanged; original VM intact." }
            $c = & "$env:windir\System32\mbr2gpt.exe" /convert /allowFullOS 2>&1
            $r.Add("convert: $($c -join ' | ')")
            if ($LASTEXITCODE -eq 100) {
                throw "mbr2gpt exit 100: disk IS converted to GPT but BCD restore FAILED - the copy is converted-but-unbootable. Repair BCD in staging or delete the copies and rerun. Original VM intact."
            }
            if ($LASTEXITCODE -ne 0) { throw "mbr2gpt CONVERT failed (exit $LASTEXITCODE). See C:\Windows\mbr2gpt.log in staging. Original VM intact." }
            $r.Add('Conversion complete (disk is GPT; firmware switch happens via the Gen2 VM).')
            $r
        }
        $conv | ForEach-Object { $out.Add($_) }

        # SHUT DOWN - never reboot: BIOS staging cannot boot the GPT disk
        Stop-VM -Name $sName -Force
        for ($i = 0; $i -lt 30 -and (Get-VM -Name $sName).State -ne 'Off'; $i++) { Start-Sleep -Seconds 5 }
        if ((Get-VM -Name $sName).State -ne 'Off') { throw "Staging VM did not power off." }
        Remove-VM -Name $sName -Force        # shell only; disks stay
        $out.Add('Staging shut down and shell removed.')
        $out
    } -ArgumentList $StagingName, $bootCopy, $newDir, $guestCred
    $stageResult | ForEach-Object { Log $_ }

    # =========================================================================
    # PHASE 4 - BUILD THE GEN2 VM on the converted copies
    # =========================================================================
    Log "Building Gen2 VM '$NewName'..."
    $spec = @{
        Name = $NewName; Dir = $newDir; BootDisk = $bootCopy
        OtherDisks = @($copyPlan | Where-Object { -not $_.IsBoot } | ForEach-Object { $_.Dst })
        CPU = $vm.CPUCount; MemoryMB = $vm.Memory
        DynMem = $vm.DynamicMemoryEnabled; DynMinMB = $vm.DynamicMemoryMinimumMB; DynMaxMB = $vm.DynamicMemoryMaximumMB
        Nics = $nicSpec
    }
    $buildResult = Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($s)
        $ErrorActionPreference = 'Stop'
        $out = New-Object System.Collections.Generic.List[string]
        # -Path = the new VM's own folder, so config lives beside its disks
        New-VM -Name $s.Name -Generation 2 -Path $s.Dir -MemoryStartupBytes ([int64]$s.MemoryMB * 1MB) -VHDPath $s.BootDisk | Out-Null
        Set-VMProcessor -VMName $s.Name -Count $s.CPU
        if ($s.DynMem) {
            Set-VMMemory -VMName $s.Name -DynamicMemoryEnabled $true `
                -MinimumBytes ([int64]$s.DynMinMB * 1MB) -MaximumBytes ([int64]$s.DynMaxMB * 1MB)
        }
        foreach ($d in $s.OtherDisks) { Add-VMHardDiskDrive -VMName $s.Name -Path $d }
        Get-VMNetworkAdapter -VMName $s.Name | Remove-VMNetworkAdapter
        foreach ($n in $s.Nics) {
            $nic = Add-VMNetworkAdapter -VMName $s.Name -SwitchName $n.Switch -Passthru
            if ($n.MacStatic -and $n.Mac) { Set-VMNetworkAdapter -VMNetworkAdapter $nic -StaticMacAddress ($n.Mac -replace '[:-]','') }
            if ($n.VlanEnabled) { Set-VMNetworkAdapterVlan -VMNetworkAdapter $nic -Access -VlanId $n.Vlan }
        }
        Set-VMFirmware -VMName $s.Name -EnableSecureBoot On
        $out.Add("Gen2 VM '$($s.Name)' built: $($s.CPU) vCPU, $($s.MemoryMB)MB, $(1 + $s.OtherDisks.Count) disk(s), $($s.Nics.Count) NIC(s), Secure Boot on.")
        $out
    } -ArgumentList $spec
    $buildResult | ForEach-Object { Log $_ }

    # =========================================================================
    # PHASE 5 - START + VMM REFRESH + REPORT
    # =========================================================================
    if ($StartAfter) {
        Invoke-Command -ComputerName $hvHost -ScriptBlock {
            param($n)
            $ErrorActionPreference = 'Stop'
            Start-VM -Name $n
        } -ArgumentList $NewName
        Log "'$NewName' started."
    }
    Get-SCVMHost -ComputerName $hvHost | Read-SCVMHost | Out-Null
    Log "VMM refreshed - '$NewName' should appear in the console."
    Log "NOT carried over (by design/limits): VMM cloud/owner/custom properties, port classifications, IP-pool assignments, checkpoint policy. Original '$VMName' left OFF as rollback."
    if ($blStatus -like 'ON*') { Log "BitLocker was ON - verify protectors re-enable cleanly in the Gen2 VM and recovery keys are escrowed." }
    Log "SUCCESS. Next: .\Verify-Gen2.ps1 -VMName $VMName"
    Send-Report "Gen2 conversion OK: $VMName -> $NewName"
}
catch {
    Log "FAILED: $_"
    Log "State: original '$VMName' is INTACT (possibly powered off - start it to roll back). Any '$NewName'/'$StagingName' artifacts in $newDir can be inspected or deleted."
    Send-Report "Gen2 conversion FAILED: $VMName"
    exit 1
}
