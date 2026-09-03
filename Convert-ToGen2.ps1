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
      3. An isolated staging VM (no NIC) boots a WinPE ISO with the COPIED
         boot disk attached; PE auto-runs mbr2gpt and powers off. No
         credentials, no host changes. Result verified GPT afterward.
         (One-time: build the ISO with Build-Gen2PeIso.ps1, set PeIsoPath
         in config.json.)
      4. Gen2 VM <name>-temp built on the converted copies; Secure Boot on
      5. Start (optional), VMM refresh + presence check, email report

    Rollback semantics DIFFER BY MODE:
      default (copy/PE): original VM + MBR disks untouched - start it to roll
        back (never while <name>-temp runs: same hostname/IP/MAC).
      -InPlace: the ORIGINAL disk is converted (irreversible). Rollback =
        restore the backup, or rebuild a Gen1 shell from the MBR fallback
        copies in <name>-temp. The old shell ends up diskless, NOT bootable.

.USAGE
    .\Convert-ToGen2.ps1 -VMName VM01
    .\Convert-ToGen2.ps1 -VMName VM01 -WhatIf     # preflight + plan, changes nothing

.PREREQS
    - A verified manual backup of the VM (always, first)
    - SCVMM console module on this box; WinRM/admin to the owning Hyper-V host
    - Guest OS 64-bit (probed when running); HOST needs mbr2gpt.exe (2019+)
    - HA VMs supported (created highly available via VMM); HA path untested
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,
    [switch]$InPlace,          # convert the ORIGINAL disk in the running guest (fast path; requires -BackupVerified)
    [switch]$BackupVerified    # operator attests a verified backup exists (required with -InPlace)
)

# ============ CONFIG (config.json) ============
# Looked up next to the script, then ONE FOLDER UP (e.g. C:\adminScripts\config.json
# survives re-downloading the repo). Copy config.sample.json there and edit once.
$cfgPath = @((Join-Path $PSScriptRoot 'config.json'),
             (Join-Path (Split-Path $PSScriptRoot) 'config.json')) |
           Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $cfgPath) { throw "config.json not found next to the script or one folder up. Copy config.sample.json to e.g. C:\adminScripts\config.json and edit it." }
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$VMMServer  = $cfg.VMMServer
$SmtpServer = $cfg.SmtpServer
$SmtpPort   = [int]$cfg.SmtpPort
$MailFrom   = $cfg.MailFrom
$MailTo     = @($cfg.MailTo)
$StartAfter = [bool]$cfg.StartAfter
$PeIsoPath  = $cfg.PeIsoPath   # WinPE conversion ISO (build once with Build-Gen2PeIso.ps1)
# ==============================================

$ErrorActionPreference = 'Stop'
$NewName     = "$VMName-temp"
$StagingName = "$VMName-staging"
$phase       = 'preflight'
$conversionAttempted = $false
$disksDetached       = $false
$newVmCreated        = $false

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

# One prompt: your own password. Used only for the preflight probe into the RUNNING guest (network up, domain auth works there).
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
    if ($InPlace) {
        if (-not $BackupVerified) { throw '-InPlace converts the ORIGINAL disk (irreversible). Rerun with -BackupVerified to attest a verified backup exists.' }
        if ($vm.VirtualMachineState -ne 'Running') { throw "-InPlace needs '$VMName' RUNNING (conversion happens inside the guest over PowerShell Direct). Start it and rerun." }
    }
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
           VMNetwork = "$($_.VMNetwork)"; PortClass = "$($_.PortClassification)"
           VMSubnet = "$($_.VMSubnet)" } })
    foreach ($n in $nicSpec) {
        if ([string]::IsNullOrWhiteSpace($n.Switch) -and [string]::IsNullOrWhiteSpace($n.VMNetwork)) {
            throw "A NIC on '$VMName' has neither a VirtualNetwork nor a VMNetwork - cannot rebuild it."
        }
        Log "NIC: $(if ($n.VMNetwork) { "VM network '$($n.VMNetwork)'" } else { "vSwitch '$($n.Switch)'" })$(if ($n.VMSubnet) { " subnet '$($n.VMSubnet)'" }) VLAN $(if ($n.VlanEnabled) { $n.Vlan } else { 'none' }) MAC $($n.Mac) ($(if ($n.MacStatic) {'static, carried over'} else {'dynamic - guest may re-detect NIC'}))$(if ($n.PortClass) { " port-class '$($n.PortClass)'" })"
    }

    # Host-side preflight: disks (controller positions, format, chains),
    # HOST name collisions, switch existence, and the VM's config folder
    # (target derives from the VM folder, not disk paths - disks may live in
    # a "Virtual Hard Disks" subfolder).
    $hp = Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($name, $tempName, $stagingName, $switches, $isoPath, $inPlaceMode)
        $ErrorActionPreference = 'Stop'
        foreach ($n in @($tempName, $stagingName)) {
            if (Get-VM -Name $n -ErrorAction SilentlyContinue) { throw "Host-level VM '$n' already exists on this host (may not be in VMM)." }
        }
        $missing = @($switches | Where-Object { -not (Get-VMSwitch -Name $_ -ErrorAction SilentlyContinue) })
        if ($missing) { throw "vSwitch(es) not found on host: $($missing -join ', ')" }
        if (-not $inPlaceMode -and (-not $isoPath -or -not (Test-Path $isoPath))) { throw "PE conversion ISO not found from the host at '$isoPath'. Build it once with Build-Gen2PeIso.ps1 and set PeIsoPath in config.json - or use -InPlace." }
        $hostVm = Get-VM -Name $name
        $disks = foreach ($d in (Get-VMHardDiskDrive -VMName $name)) {
            $vhd = Get-VHD -Path $d.Path
            [pscustomobject]@{
                Path       = $d.Path
                Controller = "$($d.ControllerType) $($d.ControllerNumber):$($d.ControllerLocation)"
                CtrlType   = "$($d.ControllerType)"
                CtrlNum    = $d.ControllerNumber
                CtrlLoc    = $d.ControllerLocation
                IsBoot     = ($d.ControllerType -eq 'IDE' -and $d.ControllerNumber -eq 0 -and $d.ControllerLocation -eq 0)
                Format     = "$($vhd.VhdFormat)"
                VhdType    = "$($vhd.VhdType)"
                ParentPath = $vhd.ParentPath
                FileSizeGB = [math]::Round($vhd.FileSize / 1GB, 1)
            }
        }
        [pscustomobject]@{ VMPath = $hostVm.Path; Disks = $disks }
    } -ArgumentList $VMName, $NewName, $StagingName, @($nicSpec | Where-Object { -not $_.VMNetwork -and $_.Switch } | ForEach-Object { $_.Switch } | Select-Object -Unique), $PeIsoPath, [bool]$InPlace

    # VMM-side network object resolution (fail in preflight, not at build
    # time; require EXACTLY one match - ambiguous names are unsafe)
    foreach ($n in $nicSpec) {
        if ($n.VMNetwork) {
            $c = @(Get-SCVMNetwork -Name $n.VMNetwork).Count
            if ($c -ne 1) { throw "VM network '$($n.VMNetwork)' resolves to $c objects in VMM - need exactly 1." }
        }
        if ($n.VMSubnet) {
            if (-not $n.VMNetwork) { throw "NIC has VM subnet '$($n.VMSubnet)' but no VM network - cannot resolve it." }
            $vmnetObj = Get-SCVMNetwork -Name $n.VMNetwork | Select-Object -First 1
            $c = @(Get-SCVMSubnet -Name $n.VMSubnet -VMNetwork $vmnetObj).Count
            if ($c -ne 1) { throw "VM subnet '$($n.VMSubnet)' resolves to $c objects in VM network '$($n.VMNetwork)' - need exactly 1." }
        }
        if ($n.PortClass) {
            $c = @(Get-SCPortClassification -Name $n.PortClass).Count
            if ($c -ne 1) { throw "Port classification '$($n.PortClass)' resolves to $c objects in VMM - need exactly 1." }
        }
    }

    $diskInfo = @($hp.Disks)
    if ($diskInfo.Count -gt 64) { throw "VM has $($diskInfo.Count) disks - more than one SCSI controller's 64-device limit. Handle manually." }
    $diskInfo | ForEach-Object { Log "Disk: $($_.Controller) $($_.Path) [$($_.Format)/$($_.VhdType), $($_.FileSizeGB)GB$(if ($_.IsBoot) { ', BOOT' })]" }
    $boot = @($diskInfo | Where-Object IsBoot)
    if ($boot.Count -ne 1) { throw "Expected exactly one boot disk at IDE 0:0, found $($boot.Count). Nonstandard layout - handle manually." }
    if ($InPlace -and @($diskInfo | Where-Object Format -eq 'VHD').Count -gt 0) {
        throw '-InPlace cannot be used with legacy .vhd disks (Gen2 requires VHDX and in-place does not convert formats). Use the default staging mode for this VM.'
    }
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
    $staticIpCfg = @()
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
                } elseif ((Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) -and
                          -not (Get-WindowsFeature -Name BitLocker).Installed) {
                    # No tooling because the BitLocker FEATURE is not installed -
                    # on Windows Server that means BitLocker cannot be active.
                    $vols = @()
                } else {
                    throw 'Cannot determine BitLocker state (no Get-BitLockerVolume, no manage-bde, feature state unknown) - refusing to assume off.'
                }
                # Static IPv4 config, keyed by MAC - a new VM means new NIC
                # hardware in Windows, so static IPs don't carry on their own.
                # DHCP NICs are skipped: they re-lease fine on new hardware.
                $staticNics = @(Get-NetIPConfiguration | ForEach-Object {
                    $ipv4 = @($_.IPv4Address | Where-Object { $_ })
                    if (-not $ipv4) { return }
                    $dhcp = (Get-NetIPInterface -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
                    if ($dhcp -eq 'Enabled') { return }
                    $mac = (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).MacAddress
                    if (-not $mac) { return }
                    [pscustomobject]@{
                        Mac          = $mac
                        IPAddress    = $ipv4[0].IPAddress
                        PrefixLength = $ipv4[0].PrefixLength
                        Gateway      = ($_.IPv4DefaultGateway | Select-Object -First 1 -ExpandProperty NextHop)
                        DNSServers   = @($_.DNSServer | Where-Object AddressFamily -eq 2 | Select-Object -ExpandProperty ServerAddresses)
                    }
                })
                [pscustomobject]@{ BitLockerOn = $vols; OS = (Get-CimInstance Win32_OperatingSystem).Caption; StaticNics = $staticNics }
            }
        } -ArgumentList $VMName, $guestCred
        $blOn = @($probe.BitLockerOn)
        $staticIpCfg = @($probe.StaticNics)
        $guestProbed = $true
        Log "Guest probe OK: $($probe.OS) | mbr2gpt present | BitLocker $(if ($blOn.Count) { "ON: $($blOn -join ', ')" } else { 'off on all volumes' }) | static IPv4 on $($staticIpCfg.Count) NIC(s)"
        if ($blOn.Count) {
            Log "BITLOCKER GATE: verify recovery keys are escrowed (AD/backup) BEFORE proceeding. Protectors must be re-validated in the Gen2 VM - Verify-Gen2 checks this."
        }
        if ($staticIpCfg.Count) {
            Log "STATIC IP: captured $(($staticIpCfg | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength) (MAC $($_.Mac))" }) -join '; ') - will attempt to reapply to '$NewName' by MAC match after it starts. Only reliable for NICs whose MAC is static (carried over); dynamic-MAC NICs won't match and need manual re-entry."
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
    # PHASE 3 - CONVERT (two modes)
    #  -InPlace: mbr2gpt inside the RUNNING guest on its own system disk
    #            (supported full-OS mode; domain auth works - VM has network),
    #            then SHUT DOWN (never reboot: BIOS cannot boot the GPT result).
    #            The -temp copies remain as a pristine MBR fallback.
    #  default:  isolated staging VM boots the PE ISO against the COPY.
    # =========================================================================
    if ($InPlace) {
        $phase = 'convert-inplace'
        # The shared shutdown+copy phases just ran (clean MBR fallback copy in
        # $newDir). Conversion needs the guest RUNNING again - start it back up.
        Log "rev inplace-b | Starting '$VMName' back up to convert inside the running guest..."
        Start-SCVirtualMachine -VM (Get-SCVirtualMachine -Name $VMName) -ErrorAction Stop | Out-Null
        $ready = Invoke-Command -ComputerName $hvHost -ScriptBlock {
            param($name, $cred)
            $ErrorActionPreference = 'Stop'
            $up = $false
            for ($j = 0; $j -lt 60; $j++) {
                Start-Sleep -Seconds 10
                if ("$((Get-VM -Name $name).Heartbeat)" -like 'Ok*') { $up = $true; break }
            }
            if (-not $up) { return 'no-heartbeat' }
            for ($j = 0; $j -lt 12; $j++) {
                try {
                    Invoke-Command -VMName $name -Credential $cred -ScriptBlock { 'ready' } -ErrorAction Stop | Out-Null
                    return 'ready'
                } catch {
                    if ($_.Exception.Message -match 'credential|password|logon failure|authentication|access is denied') { return "auth: $($_.Exception.Message)" }
                    Start-Sleep -Seconds 15
                }
            }
            'no-psdirect'
        } -ArgumentList $VMName, $guestCred
        if ($ready -ne 'ready') { throw "Guest did not become reachable after restart ($ready). VM is running and unconverted - shut it down or retry." }
        Log "Guest back up + PowerShell Direct ready - converting (MBR fallback copy kept in $newDir)..."
        $conversionAttempted = $true
        $ipResult = Invoke-Command -ComputerName $hvHost -ScriptBlock {
            param($name, $cred)
            $ErrorActionPreference = 'Stop'
            Invoke-Command -VMName $name -Credential $cred -ScriptBlock {
                $ErrorActionPreference = 'Stop'
                $r = New-Object System.Collections.Generic.List[string]
                $suspended = @()
                $blCmdlet = [bool](Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)
                $bde = "$env:windir\System32\manage-bde.exe"
                if ($blCmdlet) {
                    foreach ($v in Get-BitLockerVolume) {
                        if ($v.ProtectionStatus -notin 'On', 'Off') { throw "BitLocker state on $($v.MountPoint) is '$($v.ProtectionStatus)' (unknown) - refusing." }
                        if ($v.ProtectionStatus -eq 'On') {
                            Suspend-BitLocker -MountPoint $v.MountPoint -RebootCount 0 | Out-Null
                            if ((Get-BitLockerVolume -MountPoint $v.MountPoint).ProtectionStatus -eq 'On') { throw "BitLocker suspension FAILED on $($v.MountPoint)." }
                            $suspended += $v.MountPoint
                            $r.Add("BitLocker suspended on $($v.MountPoint) (RebootCount 0 - stays off until protectors are recreated post-Gen2).")
                        }
                    }
                } elseif (Test-Path $bde) {
                    $raw = cmd.exe /c "`"$bde`" -status 2>&1" | Out-String
                    if ($LASTEXITCODE -ne 0) { throw 'Cannot determine BitLocker state (manage-bde failed) - refusing to convert blind.' }
                    if ($raw -match 'Protection Status:\s*Protection On') {
                        cmd.exe /c "`"$bde`" -protectors -disable C: 2>&1" | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw 'BitLocker ON and manage-bde could not disable protectors - aborting.' }
                        $suspended += 'C: (manage-bde)'
                        $r.Add('BitLocker protectors disabled via manage-bde (stays off until re-enabled post-Gen2).')
                    }
                } elseif ((Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) -and -not (Get-WindowsFeature -Name BitLocker).Installed) {
                    $r.Add('BitLocker feature not installed - cannot be active.')
                } else {
                    throw 'Cannot determine BitLocker state (no tooling) - refusing to convert blind.'
                }
                $v = cmd.exe /c "$env:windir\System32\mbr2gpt.exe /validate /allowFullOS 2>&1"
                $r.Add("validate (exit $LASTEXITCODE): $(($v | Where-Object { $_ }) -join ' | ')")
                if ($LASTEXITCODE -ne 0) {
                    # Undo BitLocker suspension before declaring the VM unharmed
                    foreach ($m in $suspended) {
                        if ($m -like '*manage-bde*') { cmd.exe /c "`"$bde`" -protectors -enable C: 2>&1" | Out-Null }
                        else { Resume-BitLocker -MountPoint $m -ErrorAction SilentlyContinue | Out-Null }
                    }
                    if ($suspended.Count) { $r.Add("BitLocker protection resumed on: $($suspended -join ', ')") }
                    throw "mbr2gpt VALIDATE failed (exit $LASTEXITCODE) - disk NOT converted; BitLocker restored. See %windir%\setupact.log in the guest."
                }
                $c = cmd.exe /c "$env:windir\System32\mbr2gpt.exe /convert /allowFullOS 2>&1"
                $r.Add("convert (exit $LASTEXITCODE): $(($c | Where-Object { $_ }) -join ' | ')")
                if ($LASTEXITCODE -eq 100) { throw 'mbr2gpt exit 100: disk IS GPT but BCD restore failed - converted-but-unbootable. Guest is being shut down. RESTORE FROM BACKUP or rebuild from the -temp MBR copies.' }
                if ($LASTEXITCODE -ne 0) { throw "mbr2gpt CONVERT failed (exit $LASTEXITCODE). Disk state uncertain - guest shutdown scheduled; verify before ANY boot. Fallbacks: backup / -temp MBR copies." }
                # Schedule shutdown INSIDE the guest so a lost remoting result
                # cannot leave a converted disk on a running Gen1 VM.
                cmd.exe /c "shutdown /s /t 5 /c `"Gen2 conversion complete`"" | Out-Null
                $r.Add('Conversion complete. In-guest shutdown scheduled (5s) - this VM must NEVER boot as Gen1 again.')
                $r
            }
        } -ArgumentList $VMName, $guestCred
        $ipResult | ForEach-Object { Log $_ }

        $conversionAttempted = $true
        # The guest scheduled its own shutdown. Wait for PowerOff; if it does
        # not arrive, FORCE the VM off - a converted disk must never stay
        # attached to a running Gen1 VM.
        $vm = Get-SCVirtualMachine -Name $VMName
        for ($j = 0; $j -lt 60 -and $vm.VirtualMachineState -ne 'PowerOff'; $j++) { Start-Sleep -Seconds 10; $vm = Get-SCVirtualMachine -Name $VMName }
        if ($vm.VirtualMachineState -ne 'PowerOff') {
            $hvHost = $vm.VMHost.Name      # owner may have moved on a cluster
            Log "'$VMName' did not shut down in 10 min - forcing power-off (disk is GPT; Gen1 must not run on it)."
            Invoke-Command -ComputerName $hvHost -ScriptBlock {
                param($n)
                Stop-VM -Name $n -TurnOff -Force -ErrorAction Stop
            } -ArgumentList $VMName
            for ($j = 0; $j -lt 12; $j++) { Start-Sleep -Seconds 5; $vm = Get-SCVirtualMachine -Name $VMName; if ($vm.VirtualMachineState -eq 'PowerOff') { break } }
            if ($vm.VirtualMachineState -ne 'PowerOff') { throw "'$VMName' STILL not off after force-TurnOff - stop it manually before anything else." }
        }
        Log "'$VMName' is off post-conversion."

        # Detach the (now GPT) disks from the Gen1 shell THROUGH VMM so its
        # ownership data stays truthful. Files are NOT deleted. Verified on
        # both the VMM and Hyper-V sides before proceeding.
        $vm = Get-SCVirtualMachine -Name $VMName
        $hvHost = $vm.VMHost.Name           # re-resolve owner before mutating
        foreach ($dd in @($vm.VirtualDiskDrives)) {
            Remove-SCVirtualDiskDrive -VirtualDiskDrive $dd -SkipDeleteVHD -ErrorAction Stop | Out-Null
        }
        Read-SCVirtualMachine -VM (Get-SCVirtualMachine -Name $VMName) -Force -ErrorAction SilentlyContinue | Out-Null
        $vmmLeft  = @((Get-SCVirtualMachine -Name $VMName).VirtualDiskDrives).Count
        $hostLeft = Invoke-Command -ComputerName $hvHost -ScriptBlock {
            param($n, $paths)
            $ErrorActionPreference = 'Stop'
            $left = @(Get-VMHardDiskDrive -VMName $n).Count
            $missing = @($paths | Where-Object { -not (Test-Path $_) })
            [pscustomobject]@{ Left = $left; Missing = $missing }
        } -ArgumentList $VMName, @($diskInfo.Path)
        if ($vmmLeft -ne 0 -or $hostLeft.Left -ne 0) { throw "Detach incomplete (VMM shows $vmmLeft, host shows $($hostLeft.Left) still attached) - resolve before the Gen2 build; do NOT start '$VMName'." }
        if ($hostLeft.Missing.Count) { throw "Disk file(s) missing after detach: $($hostLeft.Missing -join ', ') - STOP and investigate." }
        $disksDetached = $true
        Log "Disks detached from the Gen1 shell (files untouched, VMM-consistent). MBR fallback copies remain in $newDir - never reattach the ORIGINALS to a Gen1 shell (they are GPT now)."
    }
    else {
        # =========================================================================
        # PHASE 3 - CONVERT THE COPY FROM THE HOST (no staging boot, no guest auth)
        # Mount the copied boot VHDX on the Hyper-V host, run mbr2gpt against that
        # disk number, dismount. The original VM's disks are never mounted.
        # =========================================================================
        $phase = 'convert'
        Log "rev pe-staging-a | Booting PE staging VM '$StagingName' from the conversion ISO (no credentials, no host changes)..."
        $convResult = Invoke-Command -ComputerName $hvHost -ScriptBlock {
            param($sName, $bootDisk, $dir, $iso)
            $ErrorActionPreference = 'Stop'
            $out = New-Object System.Collections.Generic.List[string]
            $ok = $false; $fail = $null
            try {
                New-VM -Name $sName -Generation 1 -Path $dir -MemoryStartupBytes 2GB -VHDPath $bootDisk | Out-Null
                Get-VMNetworkAdapter -VMName $sName | Remove-VMNetworkAdapter      # fully isolated
                Set-VMDvdDrive -VMName $sName -Path $iso
                Set-VMBios -VMName $sName -StartupOrder @('CD','IDE','LegacyNetworkAdapter','Floppy')
                Start-VM -Name $sName
                $out.Add('PE staging booted (isolated, DVD-first). It runs mbr2gpt on its only disk and powers itself off.')
                $done = $false
                for ($j = 0; $j -lt 150; $j++) {
                    Start-Sleep -Seconds 10
                    if ((Get-VM -Name $sName).State -eq 'Off') { $done = $true; break }
                }
                if (-not $done) { throw 'PE staging did not power off within 25 min - check its console, then remove it.' }
                $out.Add("PE staging finished and powered off after ~$(($j + 1) * 10)s.")
            }
            catch { $fail = "$_" }
            finally {
                $st = Get-VM -Name $sName -ErrorAction SilentlyContinue
                if ($st) {
                    if ($st.State -ne 'Off') { Stop-VM -Name $sName -TurnOff -Force -ErrorAction SilentlyContinue }
                    Remove-VM -Name $sName -Force -ErrorAction SilentlyContinue
                    if (Get-VM -Name $sName -ErrorAction SilentlyContinue) { $out.Add("STAGING CLEANUP INCOMPLETE: remove '$sName' manually.") }
                    else { $out.Add('Staging shell removed (verified).') }
                }
            }
            if (-not $fail) {
                # Verify the copy is now GPT; pull the PE log off the disk for the report
                $mounted = $false
                try {
                    $disk = Mount-VHD -Path $bootDisk -ReadOnly -Passthru | Get-Disk
                    $mounted = $true
                    $style = $disk.PartitionStyle
                    $peLog = $null
                    $parts = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
                    foreach ($p in ($parts | Where-Object { -not $_.DriveLetter -and $_.Type -match 'IFS|Basic' })) {
                        try { $p | Add-PartitionAccessPath -AssignDriveLetter | Out-Null } catch {}
                    }
                    Start-Sleep -Seconds 2
                    $parts = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
                    $okMarker = $false
                    foreach ($p in ($parts | Where-Object DriveLetter)) {
                        $lp = "$($p.DriveLetter):\gen2convert-pe.log"
                        if (Test-Path $lp) { $peLog = Get-Content $lp -Raw }
                        if (Test-Path "$($p.DriveLetter):\gen2convert-ok.marker") { $okMarker = $true }
                        if ($peLog) { break }
                    }
                    if ($peLog) {
                        $out.Add('--- PE convert log ---')
                        ($peLog -split "`r?`n") | Where-Object { $_ } | ForEach-Object { $out.Add($_) }
                    }
                    if ($style -ne 'GPT') { $fail = "PE run finished but the copy is still $style (see PE log above). Original VM intact." }
                    elseif (-not $okMarker) { $fail = 'Disk is GPT but PE left no success marker (possible exit-100 converted-but-unbootable, or log volume not found). Inspect the PE log before trusting this copy. Original VM intact.' }
                    else { $ok = $true; $out.Add('Copy verified GPT + PE success marker present - conversion succeeded.') }
                }
                catch { $fail = "post-check: $_" }
                finally { if ($mounted) { Dismount-VHD -Path $bootDisk -ErrorAction SilentlyContinue } }
            }
            [pscustomobject]@{ Ok = $ok; Fail = $fail; Lines = $out }
        } -ArgumentList $StagingName, $bootCopy, $newDir, $PeIsoPath
        $convResult.Lines | ForEach-Object { Log $_ }
        if (-not $convResult.Ok) { throw "convert phase: $($convResult.Fail)" }
    }


    # (Old staging-VM path removed: PowerShell Direct into an isolated clone
    # cannot authenticate domain accounts - no DC reachable, and cached
    # credentials do not apply to that logon type. Host-mount needs no auth.)

    # =========================================================================
    # PHASE 4 - BUILD THE GEN2 VM
    # =========================================================================
    $phase = 'build'
    if ($InPlace) {
        $buildBoot   = $boot[0].Path
        $buildOthers = @($diskInfo | Where-Object { -not $_.IsBoot } | ForEach-Object { $_.Path })
    } else {
        $buildBoot   = $bootCopy
        $buildOthers = @($copyPlan | Where-Object { -not $_.IsBoot } | ForEach-Object { $_.Dst })
    }
    Log "Building Gen2 VM '$NewName' THROUGH VMM (fully VMM-managed, HA carried)$(if ($InPlace) { ' on the ORIGINAL disks' })..."
    $jobGroup = [guid]::NewGuid().Guid
    $hwName   = "tmp-$NewName-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $hwProfile = $null
    try {
        # Hardware profile: generation, CPU, memory (+dynamic), Secure Boot
        $hwArgs = @{
            Name = $hwName; Generation = 2
            CPUCount = $vm.CPUCount; MemoryMB = $vm.Memory
            SecureBootEnabled = $true; SecureBootTemplate = 'MicrosoftWindows'
            # NOTE: FirstBootDevice must NOT be set on the profile - the profile
            # has no disks (they arrive via the JobGroup) and VMM fails creation
            # with error 23352 "not valid for a boot device" (proven in pilot).
            # It is set on the VM right after creation instead.
        }
        if ($vm.DynamicMemoryEnabled) {
            $hwArgs['DynamicMemoryEnabled'] = $true
            $hwArgs['DynamicMemoryMinimumMB'] = $vm.DynamicMemoryMinimumMB
            $hwArgs['DynamicMemoryMaximumMB'] = $vm.DynamicMemoryMaximumMB
        }
        $hwProfile = New-SCHardwareProfile @hwArgs

        # Disks: boot disk at SCSI 0:0 (marked boot/system), data disks after it
        $lun = 0
        foreach ($p in @($buildBoot) + $buildOthers) {
            $dArgs = @{
                SCSI = $true; Bus = 0; LUN = $lun; JobGroup = $jobGroup
                UseLocalVirtualHardDisk = $true
                Path = (Split-Path $p); FileName = (Split-Path $p -Leaf)
            }
            if ($p -eq $buildBoot) { $dArgs['BootVolume'] = $true; $dArgs['SystemVolume'] = $true }
            New-SCVirtualDiskDrive @dArgs | Out-Null
            $lun++
        }

        # NICs: SYNTHETIC (Gen2 does not support emulated adapters - VMM's
        # default); VM-network binding preferred; VLAN/MAC/port class carried
        foreach ($n in $nicSpec) {
            $nicArgs = @{ JobGroup = $jobGroup; Synthetic = $true }
            if ($n.VMNetwork) {
                $vmnetObj = Get-SCVMNetwork -Name $n.VMNetwork | Select-Object -First 1
                $nicArgs['VMNetwork'] = $vmnetObj
                if ($n.VMSubnet) { $nicArgs['VMSubnet'] = Get-SCVMSubnet -Name $n.VMSubnet -VMNetwork $vmnetObj | Select-Object -First 1 }
            }
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
        $newVmCreated = $true
        # Deterministic Gen2 firmware boot entry - now that the disks exist
        Set-SCVirtualMachine -VM $newVm -FirstBootDevice 'SCSI,0,0' -ErrorAction Stop | Out-Null
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
        if ($staticIpCfg.Count -gt 0) {
            Log "Reapplying $($staticIpCfg.Count) captured static IPv4 config(s) to '$NewName' (matched by MAC; best-effort - does not fail the run)..."
            $ipReapply = Invoke-Command -ComputerName $hvHost -ScriptBlock {
                param($name, $cred, $configs)
                $out = New-Object System.Collections.Generic.List[string]
                $up = $false
                for ($j = 0; $j -lt 60; $j++) { Start-Sleep -Seconds 10; if ("$((Get-VM -Name $name).Heartbeat)" -like 'Ok*') { $up = $true; break } }
                if (-not $up) { $out.Add('Guest heartbeat never came up - static IP(s) NOT reapplied, configure manually via console.'); return $out }
                $ready = $false
                for ($j = 0; $j -lt 12; $j++) {
                    try { Invoke-Command -VMName $name -Credential $cred -ScriptBlock { 'ready' } -ErrorAction Stop | Out-Null; $ready = $true; break }
                    catch { Start-Sleep -Seconds 15 }
                }
                if (-not $ready) { $out.Add('PowerShell Direct never became ready - static IP(s) NOT reapplied, configure manually via console.'); return $out }
                Invoke-Command -VMName $name -Credential $cred -ScriptBlock {
                    param($configs)
                    $r = New-Object System.Collections.Generic.List[string]
                    foreach ($c in $configs) {
                        $macNorm = ($c.Mac -replace '[^0-9A-Fa-f]', '').ToUpper()
                        $adapter = Get-NetAdapter | Where-Object { ($_.MacAddress -replace '[^0-9A-Fa-f]', '').ToUpper() -eq $macNorm }
                        if (-not $adapter) { $r.Add("No adapter with MAC $($c.Mac) found in guest - '$($c.IPAddress)/$($c.PrefixLength)' NOT reapplied, configure manually."); continue }
                        try {
                            $existingIp = @(Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
                            if ($existingIp | Where-Object IPAddress -eq $c.IPAddress) { $r.Add("$($adapter.Name): already has $($c.IPAddress) - no change."); continue }
                            Get-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Set-NetIPInterface -Dhcp Disabled -ErrorAction SilentlyContinue
                            $existingIp | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                            Get-NetRoute -InterfaceIndex $adapter.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                            $p = @{ InterfaceIndex = $adapter.InterfaceIndex; IPAddress = $c.IPAddress; PrefixLength = $c.PrefixLength; ErrorAction = 'Stop' }
                            if ($c.Gateway) { $p['DefaultGateway'] = $c.Gateway }
                            New-NetIPAddress @p | Out-Null
                            if ($c.DNSServers.Count) { Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $c.DNSServers -ErrorAction Stop }
                            $r.Add("$($adapter.Name) (MAC $($c.Mac)): applied $($c.IPAddress)/$($c.PrefixLength)$(if ($c.Gateway) { ", gateway $($c.Gateway)" })$(if ($c.DNSServers.Count) { ", DNS $($c.DNSServers -join '/')" }).")
                        } catch { $r.Add("$($adapter.Name) (MAC $($c.Mac)): FAILED to apply $($c.IPAddress) - $_. Configure manually.") }
                    }
                    $r
                } -ArgumentList (,$configs)
            } -ArgumentList $VMName, $guestCred, $staticIpCfg
            $ipReapply | ForEach-Object { Log "  $_" }
        }
    } elseif ($staticIpCfg.Count -gt 0) {
        Log "STATIC IP: $($staticIpCfg.Count) config(s) captured but NOT reapplied (StartAfter is off in config.json, so '$NewName' was not started). Configure manually: $(($staticIpCfg | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength) (MAC $($_.Mac))" }) -join '; ')"
    }
    Log "NOT carried over: VMM cloud/owner/custom properties, IP-pool assignments, checkpoint policy, CPU limits/weights, memory buffer/priority, automatic start/stop actions, NIC security/offload settings, original disk controller layout (all disks re-attach in order on SCSI 0). Carried: CPU/RAM/dynamic memory, VM networks or vSwitch, VLANs, static MACs, port classifications, HA flag."
    if ($blOn.Count) { Log "BitLocker was ON - Verify-Gen2 gates on protection resuming in the Gen2 VM; confirm recovery-key escrow." }
    if ($InPlace) {
        Log "Old shell '$VMName' is OFF and DISKLESS (its disks now belong to '$NewName'). It is NOT a bootable rollback - rollback = restore backup, or rebuild a Gen1 VM from the MBR copies in $newDir. Keep those copies until decommission."
    } else {
        Log "Original '$VMName' left OFF as rollback. NEVER start it while '$NewName' runs (same hostname/IP/MAC)."
    }
    Log "SUCCESS. Next: .\Verify-Gen2.ps1 -VMName $VMName"
    Send-Report "Gen2 conversion OK: $VMName -> $NewName"
}
catch {
    Log "FAILED in phase '$phase': $_"
    if ($InPlace -and $conversionAttempted) {
        Log "IN-PLACE RECOVERY (conversion was attempted - the ORIGINAL boot disk may be GPT/partial):"
        Log "  - Do NOT start '$VMName' with its original disks, and do NOT delete the -temp folder ($newDir holds your MBR fallback copies)."
        Log "  - Recovery: restore the backup, OR rebuild the shell from the MBR copies:"
        foreach ($p in $copyPlan) {
            $d0 = $diskInfo | Where-Object Path -eq $p.Src
            Log "      Add-VMHardDiskDrive -VMName '$VMName' -ControllerType $($d0.CtrlType) -ControllerNumber $($d0.CtrlNum) -ControllerLocation $($d0.CtrlLoc) -Path '$($p.Dst)'"
        }
        if ($disksDetached) { Log "  - Original GPT disk files are detached but intact in their original folder$(if ($newVmCreated) { "; '$NewName' exists and may own them - inspect the VMM job log" })." }
    }
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
            if (-not ($InPlace -and $conversionAttempted)) {
                Log "Rollback rule: start '$VMName' ONLY if '$NewName' and '$StagingName' are Off/not present (same hostname/IP/MAC - two running copies will conflict)."
            }
        }
    } catch { Log "Could not query VM states: $_" }
    if ($InPlace -and $conversionAttempted) {
        Log "Original disks WERE targeted by conversion - treat them as GPT/unknown. The -temp folder is your MBR fallback: keep it."
    } else {
        Log "Original '$VMName' disks were never modified. Artifacts under the -temp folder can be inspected or deleted."
    }
    Send-Report "Gen2 conversion FAILED: $VMName (phase: $phase)"
    exit 1
}
