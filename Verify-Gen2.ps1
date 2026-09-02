<#
.SYNOPSIS
    Post-conversion checks on <VMName>-temp, compared against the original
    (still present, powered off). Report-only. Emails results.

    IMPORTANT: a clean pass means BASIC BOOT/CONFIG CHECKS PASSED. It does
    NOT certify application health - validate the workload before
    decommissioning the original. That call is the operator's.

.USAGE
    .\Verify-Gen2.ps1 -VMName VM01     # checks VM01-temp against VM01
#>

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

$ErrorActionPreference = 'Stop'
$Target = "$VMName-temp"
$log = New-Object System.Collections.Generic.List[string]
$fail = $false
function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    $log.Add($line)
}
function Check($label, $ok, $detail) {
    if ($ok) { Log "PASS  $label - $detail" }
    else     { Log "FAIL  $label - $detail"; $script:fail = $true }
}
function Send-Report($subject) {
    try {
        Send-MailMessage -SmtpServer $SmtpServer -Port $SmtpPort `
            -From $MailFrom -To $MailTo -Subject $subject -Body ($log -join "`r`n") `
            -ErrorAction Stop -WarningAction SilentlyContinue
    } catch { Write-Warning "Email failed: $_" }
}

# One prompt: your own password. Used for PowerShell Direct into the guest.
$guestCred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message "Password for $env:USERDOMAIN\$env:USERNAME"

try {
    Import-Module VirtualMachineManager -ErrorAction Stop
    Get-SCVMMServer -ComputerName $VMMServer -ErrorAction Stop | Out-Null

    $targets = @(Get-SCVirtualMachine -Name $Target)
    if ($targets.Count -ne 1) { throw "'$Target' resolves to $($targets.Count) VMs - expected exactly 1." }
    $vm = $targets[0]
    $hvHost = $vm.VMHost.Name

    # Original for comparison (may already be decommissioned on a re-run)
    $orig = @(Get-SCVirtualMachine -Name $VMName)
    $orig = if ($orig.Count -eq 1) { $orig[0] } else { $null }

    Check 'Generation'  ($vm.Generation -eq 2) "Gen $($vm.Generation)"
    Check 'Power state' ($vm.VirtualMachineState -eq 'Running') "$($vm.VirtualMachineState)"
    if ($orig) {
        Check 'vCPU matches original'   ($vm.CPUCount -eq $orig.CPUCount) "$($vm.CPUCount) vs $($orig.CPUCount)"
        Check 'Memory matches original' ($vm.Memory -eq $orig.Memory) "$($vm.Memory)MB vs $($orig.Memory)MB"
        Check 'Disk count matches'      ($vm.VirtualDiskDrives.Count -eq $orig.VirtualDiskDrives.Count) "$($vm.VirtualDiskDrives.Count) vs $($orig.VirtualDiskDrives.Count)"
        Check 'NIC count matches'       ($vm.VirtualNetworkAdapters.Count -eq $orig.VirtualNetworkAdapters.Count) "$($vm.VirtualNetworkAdapters.Count) vs $($orig.VirtualNetworkAdapters.Count)"
        Check 'Original left OFF'       ($orig.VirtualMachineState -eq 'PowerOff') "original is $($orig.VirtualMachineState) - both up = IP/name conflict risk"
    } else {
        Log "NOTE: original '$VMName' not found in VMM - spec comparison skipped."
    }

    $g = Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($name, $cred)
        $ErrorActionPreference = 'Stop'
        $hb = "$((Get-VM -Name $name).Heartbeat)"
        $inner = Invoke-Command -VMName $name -Credential $cred -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
            $bl = 'n/a'
            if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
                $bl = (Get-BitLockerVolume | ForEach-Object { "$($_.MountPoint):$($_.ProtectionStatus)" }) -join ' '
            }
            [pscustomobject]@{
                Firmware   = (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType
                SecureBoot = try { Confirm-SecureBootUEFI } catch { $false }
                OS         = (Get-CimInstance Win32_OperatingSystem).Caption
                IPs        = (Get-NetIPAddress -AddressFamily IPv4 |
                              Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' }).IPAddress -join ', '
                GwPing     = if ($gw) { Test-Connection $gw -Count 1 -Quiet } else { $false }
                DnsOk      = [bool](Resolve-DnsName -Name $env:USERDNSDOMAIN -ErrorAction SilentlyContinue)
                DomainOk   = try { Test-ComputerSecureChannel } catch { $false }
                SysErrors  = @(Get-WinEvent -FilterHashtable @{ LogName='System'; Level=1,2; StartTime=(Get-Date).AddHours(-1) } -ErrorAction SilentlyContinue).Count
                BitLocker  = $bl
                StoppedAutoSvcs = (Get-Service | Where-Object {
                                      $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' -and
                                      $_.Name -notmatch 'edgeupdate|gupdate|MapsBroker|RemoteRegistry|sppsvc|TrustedInstaller|WbioSrvc|wuauserv|BITS|CDPSvc|dosvc'
                                  }).Name -join ', '
            }
        }
        [pscustomobject]@{ Heartbeat = $hb; G = $inner }
    } -ArgumentList $Target, $guestCred

    Check 'Heartbeat'      ($g.Heartbeat -like 'Ok*') $g.Heartbeat
    Check 'Firmware UEFI'  ($g.G.Firmware -eq 'Uefi') "$($g.G.Firmware)"
    Check 'Secure Boot'    ($g.G.SecureBoot) "guest reports $($g.G.SecureBoot)"
    Check 'Network'        ($g.G.GwPing) "IPs: $($g.G.IPs) | gateway ping: $($g.G.GwPing)"
    Check 'DNS resolves'   ($g.G.DnsOk) "domain lookup $(if ($g.G.DnsOk) {'ok'} else {'FAILED'})"
    Check 'Domain channel' ($g.G.DomainOk) "secure channel $(if ($g.G.DomainOk) {'ok'} else {'broken - Test-ComputerSecureChannel -Repair'})"
    Check 'System log clean' ($g.G.SysErrors -eq 0) "$($g.G.SysErrors) critical/error events in the last hour"
    Check 'Auto services'  ([string]::IsNullOrEmpty($g.G.StoppedAutoSvcs)) `
        $(if ($g.G.StoppedAutoSvcs) { "NOT running: $($g.G.StoppedAutoSvcs)" } else { 'all running' })
    Log "OS: $($g.G.OS) | BitLocker: $($g.G.BitLocker)"

    if ($fail) {
        Log "RESULT: FAILED CHECKS on '$Target' - investigate before doing anything to '$VMName'."
        Send-Report "Gen2 verify FAILED checks: $Target"
        exit 1
    }
    Log "RESULT: basic boot/config checks PASSED on '$Target'."
    Log "This does NOT certify application health. Validate the workload (app owners, monitoring, backups) - decommissioning '$VMName' is an operator decision."
    Send-Report "Gen2 verify: basic checks passed on $Target"
}
catch {
    Log "FAILED: $_"
    Send-Report "Gen2 verify ERROR: $Target"
    exit 1
}
