<#
.SYNOPSIS
    Step 4: verify the Gen2 clone. Pass the ORIGINAL name; the script targets
    <VMName>-temp. Report-only - changes nothing. Emails the results.

.USAGE
    .\Verify-Gen2.ps1 -VMName VM01     # checks VM01-temp
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
            -From $MailFrom -To $MailTo -Subject $subject -Body ($log -join "`r`n")
    } catch { Write-Warning "Email failed: $_" }
}

# One prompt: your own password. Same account is used for the in-guest steps.
$guestCred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message "Password for $env:USERDOMAIN\$env:USERNAME"

try {
    Import-Module VirtualMachineManager -ErrorAction Stop
    Get-SCVMMServer -ComputerName $VMMServer -ErrorAction Stop | Out-Null

    $vm = Get-SCVirtualMachine -Name $Target -ErrorAction Stop
    if (-not $vm) { throw "'$Target' not found in VMM - did Convert-ToGen2 run?" }
    $hvHost = $vm.VMHost.Name

    Check 'Generation' ($vm.Generation -eq 2) "Gen $($vm.Generation)"
    Check 'Power state' ($vm.VirtualMachineState -eq 'Running') "$($vm.VirtualMachineState)"

    $guest = Invoke-Command -ComputerName $hvHost -ScriptBlock {
        param($name, $cred)
        $hb = (Get-VM -Name $name).Heartbeat
        $g = Invoke-Command -VMName $name -Credential $cred -ScriptBlock {
            [pscustomobject]@{
                Firmware = (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType
                OS       = (Get-CimInstance Win32_OperatingSystem).Caption
                Build    = (Get-CimInstance Win32_OperatingSystem).BuildNumber
                IPs      = (Get-NetIPAddress -AddressFamily IPv4 |
                            Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' }).IPAddress -join ', '
                GwPing   = if ($gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                                      Select-Object -First 1).NextHop) {
                               (Test-Connection $gw -Count 1 -Quiet)
                           } else { $false }
                StoppedAutoSvcs = (Get-Service | Where-Object {
                                      $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' -and
                                      $_.Name -notmatch 'edgeupdate|gupdate|MapsBroker|RemoteRegistry|sppsvc|TrustedInstaller|WbioSrvc|wuauserv|BITS|CDPSvc|dosvc'
                                  }).Name -join ', '
            }
        }
        [pscustomobject]@{ Heartbeat = "$hb"; Guest = $g }
    } -ArgumentList $Target, $guestCred

    Check 'Heartbeat' ($guest.Heartbeat -like 'Ok*') $guest.Heartbeat
    Check 'Firmware'  ($guest.Guest.Firmware -eq 'Uefi') "$($guest.Guest.Firmware)"
    Check 'Network'   ($guest.Guest.GwPing) "IPs: $($guest.Guest.IPs) | gateway ping: $($guest.Guest.GwPing)"
    Check 'Auto services' ([string]::IsNullOrEmpty($guest.Guest.StoppedAutoSvcs)) `
        $(if ($guest.Guest.StoppedAutoSvcs) { "NOT running: $($guest.Guest.StoppedAutoSvcs)" } else { 'all running' })
    Log "OS: $($guest.Guest.OS) build $($guest.Guest.Build)"

    if ($fail) {
        Log "RESULT: '$Target' has FAILED checks - review before decommissioning '$VMName'."
        Send-Report "Gen2 verify FAILED checks: $Target"
        exit 1
    }
    Log "RESULT: '$Target' verified - Gen2/UEFI, network up, services clean. Safe to decommission '$VMName' when ready."
    Send-Report "Gen2 verify OK: $Target"
}
catch {
    Log "FAILED: $_"
    Send-Report "Gen2 verify ERROR: $Target"
    exit 1
}
