<#
.SYNOPSIS
    Clone a Gen1 VM (already converted with mbr2gpt) into a Gen2 VM named
    <VMName>-temp, via SCVMM. Original VM and disks are NOT modified - the
    new VM gets COPIES of the disks. Emails a report when done.

.USAGE
    .\Convert-ToGen2.ps1 -VMName VM01

    .\Convert-ToGen2.ps1 -VMName VM01 -WhatIf
    Dry run: resolves the VM, host, specs, disks (with sizes) and prints
    exactly what WOULD happen. No shutdown, no copies, no new VM, no email.

.PREREQS
    - Run steps 1-6 first (checkpoint, mbr2gpt /convert inside guest, shut down)
    - VM must be powered OFF
    - Run from a box with the SCVMM console (VirtualMachineManager module)
    - Admin/WinRM rights on the Hyper-V host that owns the VM
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName
)

# ==================== EDIT THESE ====================
$VMMServer  = 'SCVMM01.yourdomain.local'          # SCVMM management server
$SmtpServer = 'smtp.yourdomain.local'             # non-secure relay
$SmtpPort   = 25
$MailFrom   = 'hyperv-automation@yourdomain.local'
$MailTo     = @('you@yourdomain.local')           # add more: 'a@x.com','b@x.com'
$StartAfter = $true                               # start the -temp VM when built
# ====================================================

$NewName = "$VMName-temp"
$log = New-Object System.Collections.Generic.List[string]
function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    $log.Add($line)
}

function Send-Report($subject) {
    try {
        Send-MailMessage -SmtpServer $SmtpServer -Port $SmtpPort `
            -From $MailFrom -To $MailTo -Subject $subject `
            -Body ($log -join "`r`n")
    } catch {
        Write-Warning "Email failed: $_"
    }
}

try {
    Import-Module VirtualMachineManager -ErrorAction Stop
    Get-SCVMMServer -ComputerName $VMMServer -ErrorAction Stop | Out-Null
    Log "Connected to VMM: $VMMServer"

    # --- Locate the VM and its host ---
    $vm = Get-SCVirtualMachine -Name $VMName -ErrorAction Stop
    if (-not $vm) { throw "VM '$VMName' not found in VMM." }
    if ($vm.Generation -eq 2) { throw "'$VMName' is already Generation 2." }
    $doIt = $PSCmdlet.ShouldProcess($VMName, "clone to Gen2 as '$NewName'")

    if ($vm.VirtualMachineState -ne 'PowerOff') {
        if (-not $doIt) {
            Log "WOULD shut down '$VMName' (currently $($vm.VirtualMachineState)) gracefully."
        } else {
        Log "'$VMName' is $($vm.VirtualMachineState) - shutting it down (make sure mbr2gpt /convert was already run!)..."
        Stop-SCVirtualMachine -VM $vm -Shutdown -ErrorAction Stop | Out-Null
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 10
            $vm = Get-SCVirtualMachine -Name $VMName
            if ($vm.VirtualMachineState -eq 'PowerOff') { break }
        }
        if ($vm.VirtualMachineState -ne 'PowerOff') {
            throw "'$VMName' did not shut down within 10 minutes - aborting."
        }
        Log "'$VMName' is powered off."
        }
    }
    if (Get-SCVirtualMachine -Name $NewName) { throw "'$NewName' already exists - clean up first." }
    if ($vm.VMCheckpoints.Count -gt 0) {
        throw "'$VMName' has $($vm.VMCheckpoints.Count) checkpoint(s). The disk copy would grab the PRE-checkpoint state. Verify the mbr2gpt conversion took, DELETE the checkpoint (lets the disk chain merge), wait for the merge to finish, then rerun."
    }

    $hvHost = $vm.VMHost.Name
    Log "VM found on host: $hvHost | vCPU $($vm.CPUCount) | RAM $($vm.Memory)MB | Gen $($vm.Generation)"

    # --- Collect specs from VMM ---
    $spec = @{
        Name     = $NewName
        CPU      = $vm.CPUCount
        MemoryMB = $vm.Memory
        DynMem   = $vm.DynamicMemoryEnabled
        DynMinMB = $vm.DynamicMemoryMinimumMB
        DynMaxMB = $vm.DynamicMemoryMaximumMB
        Nics     = @($vm.VirtualNetworkAdapters | ForEach-Object {
                        @{ Switch = $_.VirtualNetwork; VlanEnabled = $_.VLanEnabled; Vlan = $_.VLanID } })
        Disks    = @($vm.VirtualDiskDrives | Sort-Object { $_.BusType }, { $_.Bus }, { $_.Lun } |
                        ForEach-Object { $_.VirtualHardDisk.Location })
    }
    if ($spec.Disks.Count -eq 0) { throw "No disks found on '$VMName'." }
    $spec.Disks | ForEach-Object { Log "Disk: $_" }
    $spec.Nics  | ForEach-Object { Log "NIC:  switch '$($_.Switch)' VLAN $(if ($_.VlanEnabled) { $_.Vlan } else { 'none' })" }

    # --- Dry run: report and stop ---
    if (-not $doIt) {
        $sizes = Invoke-Command -ComputerName $hvHost -ScriptBlock {
            param($paths) $paths | ForEach-Object { [math]::Round((Get-Item $_).Length / 1GB, 1) }
        } -ArgumentList (,$spec.Disks)
        $newDir = Join-Path (Split-Path (Split-Path $spec.Disks[0])) $NewName
        $free = Invoke-Command -ComputerName $hvHost -ScriptBlock {
            param($p) [math]::Round((Get-PSDrive ($p.Substring(0,1))).Free / 1GB, 1)
        } -ArgumentList $newDir
        for ($i = 0; $i -lt $spec.Disks.Count; $i++) {
            Log "WOULD copy: $($spec.Disks[$i]) ($($sizes[$i])GB) -> $newDir\"
        }
        Log "WOULD create: '$NewName' Gen2, $($spec.CPU) vCPU, $($spec.MemoryMB)MB RAM, $($spec.Nics.Count) NIC(s), Secure Boot on$(if ($StartAfter) { ', then start it' })"
        Log "Space check: needs $([math]::Round(($sizes | Measure-Object -Sum).Sum,1))GB, volume has ${free}GB free."
        Log "DRY RUN complete - nothing was changed, no email sent."
        exit 0
    }

    # --- Build the Gen2 copy on the owning Hyper-V host ---
    Log "Building '$NewName' on $hvHost (disks are COPIED - original untouched)..."
    $result = Invoke-Command -ComputerName $hvHost -ArgumentList $spec -ScriptBlock {
        param($s)
        $out = New-Object System.Collections.Generic.List[string]

        # New VM gets its own folder next to the original's:
        #   D:\VMs\VM01\VM01.vhdx  ->  D:\VMs\VM01-temp\VM01.vhdx
        $parentDir = Split-Path (Split-Path $s.Disks[0])
        $newDir    = Join-Path $parentDir $s.Name
        if (Test-Path $newDir) { throw "Target folder already exists: $newDir" }
        New-Item -Path $newDir -ItemType Directory | Out-Null
        $out.Add("New VM folder: $newDir")

        $newDisks = foreach ($d in $s.Disks) {
            $copy = Join-Path $newDir (Split-Path $d -Leaf)
            if (Test-Path $copy) {   # two disks with the same filename from different folders
                $copy = Join-Path $newDir ("{0}-{1}" -f (Get-Random), (Split-Path $d -Leaf))
            }
            $out.Add("Copying $d -> $copy")
            Copy-Item $d $copy
            $copy
        }

        # Gen2 VM, config stored in the same folder, OS disk = first copied disk
        $vm = New-VM -Name $s.Name -Generation 2 -Path $parentDir `
                     -MemoryStartupBytes ([int64]$s.MemoryMB * 1MB) -VHDPath $newDisks[0]
        Set-VMProcessor -VMName $s.Name -Count $s.CPU
        if ($s.DynMem) {
            Set-VMMemory -VMName $s.Name -DynamicMemoryEnabled $true `
                -MinimumBytes ([int64]$s.DynMinMB * 1MB) -MaximumBytes ([int64]$s.DynMaxMB * 1MB)
        }

        # Additional disks
        foreach ($d in ($newDisks | Select-Object -Skip 1)) {
            Add-VMHardDiskDrive -VMName $s.Name -Path $d
        }

        # NICs: New-VM creates one adapter with no switch - remove it, rebuild from spec
        Get-VMNetworkAdapter -VMName $s.Name | Remove-VMNetworkAdapter
        foreach ($n in $s.Nics) {
            $nic = Add-VMNetworkAdapter -VMName $s.Name -SwitchName $n.Switch -Passthru
            if ($n.VlanEnabled) {
                Set-VMNetworkAdapterVlan -VMNetworkAdapter $nic -Access -VlanId $n.Vlan
            }
        }

        Set-VMFirmware -VMName $s.Name -EnableSecureBoot On
        $out.Add("VM '$($s.Name)' created: Gen2, $($s.CPU) vCPU, $($s.MemoryMB)MB, $($newDisks.Count) disk(s), $($s.Nics.Count) NIC(s)")
        $out
    }
    $result | ForEach-Object { Log $_ }

    # --- Optionally start it ---
    if ($StartAfter) {
        Invoke-Command -ComputerName $hvHost -ScriptBlock { Start-VM -Name $using:NewName }
        Log "'$NewName' started."
    } else {
        Log "'$NewName' left powered off (StartAfter = false)."
    }

    # --- Let VMM see it ---
    Get-SCVMHost -ComputerName $hvHost | Read-SCVMHost | Out-Null
    Log "VMM host refreshed - '$NewName' should appear in the VMM console."

    Log "SUCCESS. Verify '$NewName' boots + network, then decommission '$VMName' when happy."
    Send-Report "Gen2 conversion OK: $VMName -> $NewName"
}
catch {
    Log "FAILED: $_"
    Send-Report "Gen2 conversion FAILED: $VMName"
    exit 1
}
