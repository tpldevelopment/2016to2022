<#
.SYNOPSIS
    Clone a Gen1 VM (already converted with mbr2gpt) into a Gen2 VM named
    <VMName>-temp, via SCVMM. Original VM and disks are NOT modified - the
    new VM gets COPIES of the disks. Emails a report when done.

.USAGE
    .\Convert-ToGen2.ps1 -VMName VM01

.PREREQS
    - Run steps 1-6 first (checkpoint, mbr2gpt /convert inside guest, shut down)
    - VM must be powered OFF
    - Run from a box with the SCVMM console (VirtualMachineManager module)
    - Admin/WinRM rights on the Hyper-V host that owns the VM
#>

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
    if ($vm.VirtualMachineState -ne 'PowerOff') {
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
    if (Get-SCVirtualMachine -Name $NewName) { throw "'$NewName' already exists - clean up first." }

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

    # --- Build the Gen2 copy on the owning Hyper-V host ---
    Log "Building '$NewName' on $hvHost (disks are COPIED - original untouched)..."
    $result = Invoke-Command -ComputerName $hvHost -ArgumentList $spec -ScriptBlock {
        param($s)
        $out = New-Object System.Collections.Generic.List[string]

        # Copy every disk next to the original with a -temp suffix
        $newDisks = foreach ($d in $s.Disks) {
            $dir  = Split-Path $d
            $base = [IO.Path]::GetFileNameWithoutExtension($d)
            $ext  = [IO.Path]::GetExtension($d)
            $copy = Join-Path $dir "$base-temp$ext"
            if (Test-Path $copy) { throw "Disk copy target already exists: $copy" }
            $out.Add("Copying $d -> $copy")
            Copy-Item $d $copy
            $copy
        }

        # Gen2 VM, OS disk = first copied disk
        $vm = New-VM -Name $s.Name -Generation 2 -MemoryStartupBytes ([int64]$s.MemoryMB * 1MB) -VHDPath $newDisks[0]
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
