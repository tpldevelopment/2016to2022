<#
.SYNOPSIS
    Convert a Hyper-V Gen1 VM to Gen2 via SCVMM using a COPY-FIRST staging
    workflow. The original VM and its disks are NEVER modified.

    Flow:
      0. Preflight (read-only: VMM + host + guest checks, space, name/switch
         collisions, copy plan) - runs before anything is touched
      1. Graceful shutdown of the original VM
      2. Copy disks to <VM parent folder>\<name>-temp\
         (.vhd sources: copy first, then convert the UNATTACHED copy to VHDX)
      3. Isolated Gen1 staging VM (no NIC) boots the COPIED boot disk;
         BitLocker suspended (fail-closed) + mbr2gpt validate/convert inside;
         staging then SHUTS DOWN (never rebooted - BIOS cannot boot GPT).
         Staging shell is ALWAYS powered off and removed, even on failure.
      4. Gen2 VM <name>-temp built on the converted copies; Secure Boot on
      5. Start (optional), VMM refresh + presence check, email report

    Rollback at ANY point: the original Gen1 VM still exists with untouched
    MBR disks. NEVER start it while <name>-temp is running (same hostname/
    IP/MAC) - the failure handler reports both VMs' states for this reason.

.USAGE
    .\Convert-ToGen2.ps1 -VMName VM01
    .\Convert-ToGen2.ps1 -VMName VM01 -WhatIf     # preflight + plan, changes nothing

.PREREQS
    - A verified manual backup of the VM (always, first)
    - SCVMM console module on this box; WinRM/admin to the owning Hyper-V host
    - Guest OS 64-bit with mbr2gpt.exe (Server 2019+/Win10+)
    - NOT for clustered/HA VMs (refused; use the HA-aware manual path)
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
$phase       = 'preflight'

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

$hvHost = $null
try {
    Import-Module VirtualMachineManager -ErrorAction Stop
    Get-SCVMMServer -ComputerName $VMMServer -ErrorAction Stop | Out-Null
    Log "Connected to VMM: $VMMServer"

    # =========================================================================
    # PHASE 0 - PREFLIGHT (read-only)
    # =========================================================================

    $vms = @(Get-SCVirtualMachine -Name $VMName)
    if ($vms.Count -eq 0) { throw "VM '$VMName' not found in VMM." }
    if ($vms.Count -gt 1) {
        throw "VM name '$VMName' matches $($vms.Count) VMs in VMM ($(($vms | ForEach-Object { "$($_.ID) on $($_.VMHost)" }) -join '; ')). Names must resolve uniquely."
    }
    $vm = $vms[0]
    $hvHost = $vm.VMHost.Name
    Log "Resolved: '$VMName' ID $($vm.ID) on host $hvHost | Gen $($vm.Generation) | $($vm.VirtualMachineState) | vCPU $($vm.CPUCount) | RAM $($vm.Memory)MB"

    if ($vm.Generation -eq 2) { throw "'$VMName' is already Generation 2." }
    if ($vm.IsHighlyAvailable) { Log "'$VMName' is HA/clustered - the new VM will be created through VMM as highly available. Pilot on non-HA first; HA path is untested." }
    if (Get-SCVirtualMachine -Name $NewName)     { throw "'$NewName' already exists in VMM - clean up first." }
    if (Get-SCVirtualMachine -Name $StagingName) { throw "'$StagingName' already exists in VMM - clean up first." }
    if ($vm.VMCheckpoints.Count -gt 0) {
        throw "'$VMName' has $($vm.VMCheckpoints.Count) VMM checkpoint(s). Delete them, wait for the merge, rerun."
    }

    # NICs rebuilt VMM-natively: VM network binding preferred, vSwitch fallback,
    # VLAN + static MAC + port classification carried.
    $nicSpec = @($vm.VirtualNetworkAdapters | ForEach-Object {
        @{ Switch = "$($_.VirtualNetwork)"; VlanEnabled = $_.VLanEnabled; Vlan = $_.VLanID
           Mac = $_.MACAddress; MacStatic = ($_.MACAddressType -eq 'Static')
           VMNetwork = "$($_.VMNetwork)"; PortClass = "$($_.PortClassification)" } })
    foreach ($n in $nicSpec) {
        if ([string]::IsNullOrWhiteSpace($n.Switch) -and [string]::IsNullOrWhiteSpace($n.VMNetwork)) {
            throw "A NIC on '$VMName' has neither a VirtualNetwork nor a VMNetwork - cannot rebuild it."
        }
        Log "NIC: $(if ($n.VMNetwork) { "VM network '$($n.VMNetwork)'" } else { "vSwitch '$($n.Switch)'" }) VLAN $(if ($n.VlanEnabled) { $n.Vlan } else { 'none' }) MAC $($n.Mac) ($(if ($n.MacStatic) {'static, carried over'} else {'dynamic - guest may re-detect NIC'}))$(if ($n.PortClass) { " port-class '$($n.PortClass)'" })"
    }

    # Host-side preflight: disks (controller positions, format, chains),
    # HOST name collisions, switch existence, and the VM's config folder
    # (target derives from the VM folder, not disk paths - disks may live in
    # a "Virtual Hard Disks" subfolder).
    $hp = Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($name, $tempName, $stagingName, $switches)
        $ErrorActionPreference = 'Stop'
        foreach ($n in @($tempName, $stagingName)) {
            if (Get-VM -Name $n -ErrorAction SilentlyContinue) { throw "Host-level VM '$n' already exists on this host (may not be in VMM)." }
        }
        $missing = @($switches | Where-Object { -not (Get-VMSwitch -Name $_ -ErrorAction SilentlyContinue) })
        if ($missing) { throw "vSwitch(es) not found on host: $($missing -join ', ')" }
        $hostVm = Get-VM -Name $name
        $disks = foreach ($d in (Get-VMHardDiskDrive -VMName $name)) {
            $vhd = Get-VHD -Path $d.Path
            [pscustomobject]@{
                Path       = $d.Path
                Controller = "$($d.ControllerType) $($d.ControllerNumber):$($d.ControllerLocation)"
                IsBoot     = ($d.ControllerType -eq 'IDE' -and $d.ControllerNumber -eq 0 -and $d.ControllerLocation -eq 0)
                Format     = "$($vhd.VhdFormat)"
                VhdType    = "$($vhd.VhdType)"
                ParentPath = $vhd.ParentPath
                FileSizeGB = [math]::Round($vhd.FileSize / 1GB, 1)
            }
        }
        [pscustomobject]@{ VMPath = $hostVm.Path; Disks = $disks }
    } -ArgumentList $VMName, $NewName, $StagingName, @($nicSpec | Where-Object { -not $_.VMNetwork -and $_.Switch } | ForEach-Object { $_.Switch } | Select-Object -Unique)

    # VMM-side network object resolution (fail in preflight, not at build
    # time; require EXACTLY one match - ambiguous names are unsafe)
    foreach ($n in $nicSpec) {
        if ($n.VMNetwork) {
            $c = @(Get-SCVMNetwork -Name $n.VMNetwork).Count
            if ($c -ne 1) { throw "VM network '$($n.VMNetwork)' resolves to $c objects in VMM - need exactly 1." }
        }
        if ($n.PortClass) {
            $c = @(Get-SCPortClassification -Name $n.PortClass).Count
            if ($c -ne 1) { throw "Port classification '$($n.PortClass)' resolves to $c objects in VMM - need exactly 1." }
        }
    }
    if ($diskInfo.Count -gt 64) { throw "VM has $($diskInfo.Count) disks - more than one SCSI controller's 64-device limit. Handle manually." }

    $diskInfo = @($hp.Disks)
    $diskInfo | ForEach-Object { Log "Disk: $($_.Controller) $($_.Path) [$($_.Format)/$($_.VhdType), $($_.FileSizeGB)GB$(if ($_.IsBoot) { ', BOOT' })]" }
    $boot = @($diskInfo | Where-Object IsBoot)
    if ($boot.Count -ne 1) { throw "Expected exactly one boot disk at IDE 0:0, found $($boot.Count). Nonstandard layout - handle manually." }
    $chained = @($diskInfo | Where-Object { $_.ParentPath })
    if ($chained.Count -gt 0) { throw "Differencing/checkpoint chain detected on: $(($chained.Path) -join ', '). Merge chains first." }

    # Target folder: SIBLING of the original VM's own folder - never nested
    # inside it (deleting the original folder later must not touch the new VM)
    $vmFolder  = $hp.VMPath                               # e.g. D:\VMs\VM01
    $parentDir = Split-Path $vmFolder
    $newDir    = Join-Path $parentDir $NewName
    foreach ($d in $diskInfo) {
        if ($d.Path.StartsWith($newDir, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Source disk $($d.Path) is inside the target folder $newDir - unsafe layout." }
    }
    if ($newDir.StartsWith($vmFolder + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw "Target $newDir would nest inside the original VM folder $vmFolder - unsafe." }

    # Copy plan with GUARANTEED-unique destination names (d0-, d1-, ... prefix
    # only when needed), .vhd -> copy then convert the unattached copy
    $leafSeen = @{}
    $i = 0
    $copyPlan = foreach ($d in $diskInfo) {
        $leaf = Split-Path $d.Path -Leaf
        $finalLeaf = if ($d.Format -eq 'VHD') { [IO.Path]::GetFileNameWithoutExtension($leaf) + '.vhdx' } else { $leaf }
        while ($leafSeen.ContainsKey($finalLeaf.ToLower())) { $finalLeaf = "d$i-$finalLeaf" }   # loop until actually unique
        $leafSeen[$finalLeaf.ToLower()] = $true
        $i++
        [pscustomobject]@{
            Src = $d.Path; Fmt = $d.Format; VhdType = $d.VhdType; IsBoot = $d.IsBoot; SizeGB = $d.FileSizeGB
            TempVhd = if ($d.Format -eq 'VHD') { Join-Path $newDir ("tmp-" + $leaf) } else { $null }
            Dst = Join-Path $newDir $finalLeaf
        }
    }

    $dups = @($copyPlan | Group-Object { $_.Dst.ToLower() } | Where-Object Count -gt 1)
    if ($dups) { throw "Internal error: duplicate copy destinations generated: $(($dups.Name) -join ', ')" }

    # Space: all copies + temporary .vhd intermediates exist simultaneously
    $needGB = [math]::Round((($copyPlan | Measure-Object SizeGB -Sum).Sum +
                             (($copyPlan | Where-Object TempVhd | Measure-Object SizeGB -Sum).Sum)) * 1.05 + 2, 1)
    $freeGB = Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($p)
        $ErrorActionPreference = 'Stop'
        if (Test-Path $p) { throw "Target folder already exists: $p" }
        # Mount-point-aware: CSVs live under C:\ClusterStorage\ - a drive-letter
        # check would measure the host OS volume instead of the CSV.
        $probe = $p
        while (-not (Test-Path $probe)) { $probe = Split-Path $probe }   # nearest existing ancestor
        $vol = Get-Volume -FilePath $probe -ErrorAction SilentlyContinue
        if ($vol) { [math]::Round($vol.SizeRemaining / 1GB, 1) }
        else      { [math]::Round((Get-PSDrive $p.Substring(0,1)).Free / 1GB, 1) }   # non-CSV fallback
    } -ArgumentList $newDir
    Log "Target: $newDir | need ~${needGB}GB (incl. VHD conversion temp), volume has ${freeGB}GB free"
    if ($freeGB -lt $needGB) { throw "Not enough space (need ~${needGB}GB, have ${freeGB}GB)." }

    # Guest probe (creds + mbr2gpt + BitLocker) - FAIL-CLOSED BitLocker: if
    # state cannot be determined, that is an ABORT, never 'off'.
    $blOn = @()
    $guestProbed = $false
    if ($vm.VirtualMachineState -eq 'Running') {
        $probe = Invoke-Command -ComputerName $hvHost -ScriptBlock {
            param($name, $cred)
            $ErrorActionPreference = 'Stop'
            Invoke-Command -VMName $name -Credential $cred -ScriptBlock {
                $ErrorActionPreference = 'Stop'
                if (-not (Test-Path "$env:windir\System32\mbr2gpt.exe")) {
                    throw 'mbr2gpt.exe not found - guest OS too old (needs 2019+/Win10+). Upgrade the OS first.'
                }
                $vols = $null
                if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
                    $vols = @(Get-BitLockerVolume | Where-Object { $_.ProtectionStatus -eq 'On' } |
                              ForEach-Object { "$($_.MountPoint) [$($_.KeyProtector.KeyProtectorType -join '+')]" })
                } elseif (Test-Path "$env:windir\System32\manage-bde.exe") {
                    $raw = & "$env:windir\System32\manage-bde.exe" -status 2>&1 | Out-String
                    if ($LASTEXITCODE -ne 0) { throw "Cannot determine BitLocker state (manage-bde exit $LASTEXITCODE) - refusing to assume 'off'." }
                    $vols = @()
                    if ($raw -match 'Protection Status:\s*Protection On') { $vols = @('(volume detected via manage-bde)') }
                } else {
                    throw 'Cannot determine BitLocker state (no Get-BitLockerVolume, no manage-bde) - refusing to assume off.'
                }
                [pscustomobject]@{ BitLockerOn = $vols; OS = (Get-CimInstance Win32_OperatingSystem).Caption }
            }
        } -ArgumentList $VMName, $guestCred
        $blOn = @($probe.BitLockerOn)
        $guestProbed = $true
        Log "Guest probe OK: $($probe.OS) | mbr2gpt present | BitLocker $(if ($blOn.Count) { "ON: $($blOn -join ', ')" } else { 'off on all volumes' })"
        if ($blOn.Count) {
            Log "BITLOCKER GATE: verify recovery keys are escrowed (AD/backup) BEFORE proceeding. Protectors must be re-validated in the Gen2 VM - Verify-Gen2 checks this."
        }
    }

    if ($guestProbed) { Log "PREFLIGHT PASSED." }
    else { Log "PREFLIGHT PASSED WITH GAPS: '$VMName' is $($vm.VirtualMachineState) - guest creds, mbr2gpt presence, and BitLocker state are UNVERIFIED and will be enforced fail-closed in staging." }

    # ---- Dry run stops here -------------------------------------------------
    if (-not $PSCmdlet.ShouldProcess($VMName, "copy-first Gen2 conversion -> '$NewName'")) {
        foreach ($p in $copyPlan) {
            $act = if ($p.Fmt -eq 'VHD') { "copy + convert VHD->VHDX ->" } else { 'copy ->' }
            Log "WOULD $act $($p.Dst) ($($p.SizeGB)GB)"
        }
        Log "WOULD: shut down '$VMName' | stage+convert boot copy (isolated) | build Gen2 '$NewName' ($($vm.CPUCount) vCPU, $($vm.Memory)MB, $($nicSpec.Count) NIC(s), Secure Boot on)$(if ($StartAfter) { ' | start it' })"
        if (-not $guestProbed) { Log "NOTE: dry run could NOT test guest credentials/mbr2gpt/BitLocker (VM off). Consider a -WhatIf while the VM is running." }
        Log "DRY RUN complete - nothing was changed, no email sent."
        exit 0
    }

    # =========================================================================
    # PHASE 1 - SHUT DOWN THE ORIGINAL
    # =========================================================================
    $phase = 'shutdown'
    if ($vm.VirtualMachineState -ne 'PowerOff') {
        Log "Shutting down '$VMName' gracefully..."
        Stop-SCVirtualMachine -VM $vm -Shutdown -ErrorAction Stop | Out-Null
        for ($j = 0; $j -lt 60 -and $vm.VirtualMachineState -ne 'PowerOff'; $j++) {
            Start-Sleep -Seconds 10
            $vm = Get-SCVirtualMachine -Name $VMName
        }
        if ($vm.VirtualMachineState -ne 'PowerOff') { throw "'$VMName' did not shut down within 10 minutes - aborting (nothing was changed)." }
        Log "'$VMName' is powered off."
    }

    # =========================================================================
    # PHASE 2 - COPY DISKS (originals untouched; VHDs converted via the COPY)
    # =========================================================================
    $phase = 'copy'
    Log "Copying $($copyPlan.Count) disk(s) to $newDir ..."
    Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($plan, $dir, $vmName)
        $ErrorActionPreference = 'Stop'
        # Revalidate: the disk set must not have changed between preflight and now
        $current = @((Get-VMHardDiskDrive -VMName $vmName).Path | Sort-Object)
        $planned = @($plan.Src | Sort-Object)
        if (Compare-Object $current $planned) { throw "Disk set on '$vmName' changed since preflight (now: $($current -join ', ')). Rerun." }
        New-Item -Path $dir -ItemType Directory | Out-Null
        foreach ($p in $plan) {
            if ($p.Fmt -eq 'VHD') {
                # Convert-VHD must not run against an attached disk: copy the
                # .vhd first, convert the UNATTACHED copy, drop the temp.
                Copy-Item -LiteralPath $p.Src -Destination $p.TempVhd
                Convert-VHD -Path $p.TempVhd -DestinationPath $p.Dst      # type preserved (no -VHDType override)
                Remove-Item -LiteralPath $p.TempVhd -Force
            } else {
                Copy-Item -LiteralPath $p.Src -Destination $p.Dst
            }
            $check = Get-VHD -Path $p.Dst      # validates the result is a readable VHDX
            if ($check.VhdFormat -ne 'VHDX') { throw "Post-copy validation failed: $($p.Dst) is $($check.VhdFormat), expected VHDX." }
        }
    } -ArgumentList $copyPlan, $newDir, $VMName
    $bootCopy = ($copyPlan | Where-Object IsBoot).Dst
    Log "Copy complete + validated. Boot disk copy: $bootCopy"

    # =========================================================================
    # PHASE 3 - STAGING (isolated). Shell is ALWAYS stopped+removed via finally.
    # =========================================================================
    $phase = 'staging'
    Log "Creating isolated staging VM '$StagingName' (no network)..."
    $stageResult = Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($sName, $bootDisk, $dir, $cred)
        $ErrorActionPreference = 'Stop'
        $out = New-Object System.Collections.Generic.List[string]
        try {
            New-VM -Name $sName -Generation 1 -Path $dir -MemoryStartupBytes 4GB -VHDPath $bootDisk | Out-Null
            Get-VMNetworkAdapter -VMName $sName | Remove-VMNetworkAdapter
            Start-VM -Name $sName
            $out.Add('Staging VM started (isolated).')

            # Heartbeat, then PowerShell Direct READINESS (heartbeat alone
            # does not mean PS is available in the guest) - retried.
            $up = $false
            for ($j = 0; $j -lt 60; $j++) {
                Start-Sleep -Seconds 10
                if ("$((Get-VM -Name $sName).Heartbeat)" -like 'Ok*') { $up = $true; break }
            }
            if (-not $up) { throw "Staging VM never reached a healthy heartbeat (10 min) - copied disk may not boot." }
            $ready = $false
            for ($j = 0; $j -lt 12; $j++) {
                try {
                    Invoke-Command -VMName $sName -Credential $cred -ScriptBlock { 'ready' } -ErrorAction Stop | Out-Null
                    $ready = $true; break
                } catch {
                    # Bad credentials are a hard stop - retrying them risks account lockout
                    if ($_.Exception.Message -match 'credential|password|logon failure|authentication|access is denied') {
                        throw "PowerShell Direct rejected the supplied credentials: $($_.Exception.Message)"
                    }
                    Start-Sleep -Seconds 15
                }
            }
            if (-not $ready) { throw "PowerShell Direct never became ready in staging (3 min after heartbeat) - check guest credentials." }
            $out.Add('Staging heartbeat + PowerShell Direct ready - converting.')

            $conv = Invoke-Command -VMName $sName -Credential $cred -ScriptBlock {
                $ErrorActionPreference = 'Stop'
                $r = New-Object System.Collections.Generic.List[string]
                # BitLocker fail-closed, all volumes
                if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
                    foreach ($v in Get-BitLockerVolume) {
                        if ($v.ProtectionStatus -notin 'On', 'Off') { throw "BitLocker state on $($v.MountPoint) is '$($v.ProtectionStatus)' (unknown) - refusing to convert blind." }
                        if ($v.ProtectionStatus -eq 'On') {
                            Suspend-BitLocker -MountPoint $v.MountPoint | Out-Null
                            if ((Get-BitLockerVolume -MountPoint $v.MountPoint).ProtectionStatus -eq 'On') { throw "BitLocker suspension FAILED on $($v.MountPoint)." }
                            $r.Add("BitLocker suspended on $($v.MountPoint).")
                        }
                    }
                } elseif (Test-Path "$env:windir\System32\manage-bde.exe") {
                    $raw = & "$env:windir\System32\manage-bde.exe" -status 2>&1 | Out-String
                    if ($LASTEXITCODE -ne 0) { throw 'Cannot determine BitLocker state in staging - refusing to convert blind.' }
                    if ($raw -match 'Protection Status:\s*Protection On') { throw 'BitLocker ON but Get-BitLockerVolume unavailable to suspend it - handle manually.' }
                } else {
                    throw 'Cannot determine BitLocker state in staging (no tooling) - refusing to convert blind.'
                }
                if (-not (Test-Path "$env:windir\System32\mbr2gpt.exe")) { throw 'mbr2gpt.exe not found in guest - OS too old.' }
                $v = & "$env:windir\System32\mbr2gpt.exe" /validate /allowFullOS 2>&1
                $r.Add("validate: $($v -join ' | ')")
                if ($LASTEXITCODE -ne 0) { throw "mbr2gpt VALIDATE failed (exit $LASTEXITCODE). Copied disk unchanged." }
                $c = & "$env:windir\System32\mbr2gpt.exe" /convert /allowFullOS 2>&1
                $r.Add("convert: $($c -join ' | ')")
                if ($LASTEXITCODE -eq 100) { throw 'mbr2gpt exit 100: disk converted to GPT but BCD restore FAILED - copy is converted-but-unbootable. See %windir%\setupact.log / setuperr.log in staging.' }
                if ($LASTEXITCODE -ne 0) { throw "mbr2gpt CONVERT failed (exit $LASTEXITCODE). See %windir%\setupact.log / setuperr.log in the staging guest." }
                $r.Add('Conversion complete (disk is GPT; firmware switch happens via the Gen2 VM).')
                $r
            }
            $conv | ForEach-Object { $out.Add($_) }

            Stop-VM -Name $sName -Force
            for ($j = 0; $j -lt 30 -and (Get-VM -Name $sName).State -ne 'Off'; $j++) { Start-Sleep -Seconds 5 }
            if ((Get-VM -Name $sName).State -ne 'Off') { throw 'Staging VM did not power off.' }
            $out.Add('Staging shut down cleanly.')
        }
        finally {
            # Best-effort staging cleanup; the caller VERIFIES the result.
            $s = Get-VM -Name $sName -ErrorAction SilentlyContinue
            if ($s) {
                if ($s.State -ne 'Off') { Stop-VM -Name $sName -TurnOff -Force -ErrorAction SilentlyContinue }
                Remove-VM -Name $sName -Force -ErrorAction SilentlyContinue   # shell only; disks stay for diagnosis
                $s2 = Get-VM -Name $sName -ErrorAction SilentlyContinue
                if ($s2) { $out.Add("STAGING CLEANUP INCOMPLETE: '$sName' still registered, state $($s2.State) - manual cleanup required.") }
                else     { $out.Add('Staging shell removed (best-effort cleanup verified).') }
            }
        }
        $out
    } -ArgumentList $StagingName, $bootCopy, $newDir, $guestCred
    $stageResult | ForEach-Object { Log $_ }

    # Independent verification: never build the Gen2 VM while a staging shell exists
    $residual = Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($n)
        $s = Get-VM -Name $n -ErrorAction SilentlyContinue
        if ($s) { "$($s.State)" } else { $null }
    } -ArgumentList $StagingName
    if ($residual) { throw "Staging VM '$StagingName' still exists on the host (state: $residual) after cleanup - remove it manually before rerunning." }

    # =========================================================================
    # PHASE 4 - BUILD THE GEN2 VM
    # =========================================================================
    $phase = 'build'
    Log "Building Gen2 VM '$NewName' THROUGH VMM (fully VMM-managed, HA carried)..."
    $jobGroup = [guid]::NewGuid().Guid
    $hwName   = "tmp-$NewName-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $hwProfile = $null
    try {
        # Hardware profile: generation, CPU, memory (+dynamic), Secure Boot
        $hwArgs = @{
            Name = $hwName; Generation = 2
            CPUCount = $vm.CPUCount; MemoryMB = $vm.Memory
            SecureBootEnabled = $true; SecureBootTemplate = 'MicrosoftWindows'
            FirstBootDevice = 'SCSI,0,0'      # deterministic Gen2 firmware boot entry
        }
        if ($vm.DynamicMemoryEnabled) {
            $hwArgs['DynamicMemoryEnabled'] = $true
            $hwArgs['DynamicMemoryMinimumMB'] = $vm.DynamicMemoryMinimumMB
            $hwArgs['DynamicMemoryMaximumMB'] = $vm.DynamicMemoryMaximumMB
        }
        $hwProfile = New-SCHardwareProfile @hwArgs

        # Disks: boot disk at SCSI 0:0 (marked boot/system), data disks after it
        $lun = 0
        foreach ($p in @($copyPlan | Where-Object IsBoot) + @($copyPlan | Where-Object { -not $_.IsBoot })) {
            $dArgs = @{
                SCSI = $true; Bus = 0; LUN = $lun; JobGroup = $jobGroup
                UseLocalVirtualHardDisk = $true
                Path = (Split-Path $p.Dst); FileName = (Split-Path $p.Dst -Leaf)
            }
            if ($p.IsBoot) { $dArgs['BootVolume'] = $true; $dArgs['SystemVolume'] = $true }
            New-SCVirtualDiskDrive @dArgs | Out-Null
            $lun++
        }

        # NICs: SYNTHETIC (Gen2 does not support emulated adapters - VMM's
        # default); VM-network binding preferred; VLAN/MAC/port class carried
        foreach ($n in $nicSpec) {
            $nicArgs = @{ JobGroup = $jobGroup; Synthetic = $true }
            if ($n.VMNetwork) { $nicArgs['VMNetwork'] = Get-SCVMNetwork -Name $n.VMNetwork | Select-Object -First 1 }
            elseif ($n.Switch) { $nicArgs['VirtualNetwork'] = $n.Switch }
            if ($n.VlanEnabled) { $nicArgs['VLanEnabled'] = $true; $nicArgs['VLanID'] = $n.Vlan }
            if ($n.MacStatic -and $n.Mac) { $nicArgs['MACAddress'] = $n.Mac; $nicArgs['MACAddressType'] = 'Static' }
            if ($n.PortClass) { $nicArgs['PortClassification'] = Get-SCPortClassification -Name $n.PortClass | Select-Object -First 1 }
            New-SCVirtualNetworkAdapter @nicArgs | Out-Null
        }

        $newVm = New-SCVirtualMachine -Name $NewName -VMHost (Get-SCVMHost -ComputerName $hvHost) `
            -Path $parentDir -HardwareProfile $hwProfile -JobGroup $jobGroup `
            -UseLocalVirtualHardDisk -HighlyAvailable $vm.IsHighlyAvailable -ErrorAction Stop
        if (-not $newVm) { throw "New-SCVirtualMachine returned nothing - check the VMM job log." }
    }
    finally {
        if ($hwProfile) { Remove-SCHardwareProfile -HardwareProfile $hwProfile -ErrorAction SilentlyContinue | Out-Null }
    }
    Log "Gen2 VM '$NewName' built via VMM: $($vm.CPUCount) vCPU, $($vm.Memory)MB, $($copyPlan.Count) disk(s), $($nicSpec.Count) NIC(s), Secure Boot on, HighlyAvailable=$($vm.IsHighlyAvailable)."

    # =========================================================================
    # PHASE 5 - START + VMM REFRESH (verified) + REPORT
    # =========================================================================
    $phase = 'finish'
    # VM was created BY VMM, so it is VMM-owned from birth - no refresh dance
    $inVmm = @(Get-SCVirtualMachine -Name $NewName)
    if ($inVmm.Count -ne 1) { throw "VMM reports $($inVmm.Count) VMs named '$NewName' after creation - inspect the VMM job log before proceeding." }
    # Post-create verification: what VMM actually built
    $built = $inVmm[0]
    if ($built.Generation -ne 2) { throw "Post-create check: '$NewName' is Generation $($built.Generation), expected 2." }
    if ($built.VirtualDiskDrives.Count -ne $copyPlan.Count) { throw "Post-create check: '$NewName' has $($built.VirtualDiskDrives.Count) disks, expected $($copyPlan.Count)." }
    if ($built.VirtualNetworkAdapters.Count -ne $nicSpec.Count) { throw "Post-create check: '$NewName' has $($built.VirtualNetworkAdapters.Count) NICs, expected $($nicSpec.Count)." }
    if ($built.IsHighlyAvailable -ne $vm.IsHighlyAvailable) { throw "Post-create check: HA is $($built.IsHighlyAvailable), expected $($vm.IsHighlyAvailable)." }
    Log "'$NewName' is VMM-managed and verified (ID $($built.ID), Gen $($built.Generation), $($built.VirtualDiskDrives.Count) disks, $($built.VirtualNetworkAdapters.Count) NICs, HighlyAvailable=$($built.IsHighlyAvailable))."
    if ($StartAfter) {
        Start-SCVirtualMachine -VM $inVmm[0] -ErrorAction Stop | Out-Null
        Log "'$NewName' started via VMM."
    }
    Log "NOT carried over: VMM cloud/owner/custom properties, IP-pool assignments, checkpoint policy, CPU limits/weights, memory buffer/priority, automatic start/stop actions, NIC security/offload settings, original disk controller layout (all disks re-attach in order on SCSI 0). Carried: CPU/RAM/dynamic memory, VM networks or vSwitch, VLANs, static MACs, port classifications, HA flag."
    if ($blOn.Count) { Log "BitLocker was ON - Verify-Gen2 gates on protection resuming in the Gen2 VM; confirm recovery-key escrow." }
    Log "Original '$VMName' left OFF as rollback. NEVER start it while '$NewName' runs (same hostname/IP/MAC)."
    Log "SUCCESS. Next: .\Verify-Gen2.ps1 -VMName $VMName"
    Send-Report "Gen2 conversion OK: $VMName -> $NewName"
}
catch {
    Log "FAILED in phase '$phase': $_"
    # Report ACTUAL current states so the operator cannot double-run the server
    try {
        if ($hvHost) {
            $states = Invoke-Command -ComputerName $hvHost -ScriptBlock {
                param($names)
                foreach ($n in $names) {
                    $v = Get-VM -Name $n -ErrorAction SilentlyContinue
                    "{0}: {1}" -f $n, $(if ($v) { $v.State } else { 'not present' })
                }
            } -ArgumentList (,@($VMName, $NewName, $StagingName))
            $states | ForEach-Object { Log "State: $_" }
            Log "Rollback rule: start '$VMName' ONLY if '$NewName' and '$StagingName' are Off/not present (same hostname/IP/MAC - two running copies will conflict)."
        }
    } catch { Log "Could not query VM states: $_" }
    Log "Original '$VMName' disks were never modified. Artifacts under the -temp folder can be inspected or deleted."
    Send-Report "Gen2 conversion FAILED: $VMName (phase: $phase)"
    exit 1
}
