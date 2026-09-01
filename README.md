# Server 2016 → 2022 In-Place Upgrade via PDQ Deploy

Three scripts, three PDQ packages, deployed in order.

## One-time prep

1. Download the **latest** Server 2022 ISO (VLSC/M365 admin center). Old ISOs
   (pre-Nov-2022) have a known in-place-upgrade bug.
2. Extract the ISO contents (right-click → Mount → copy all files) to a share,
   e.g. `\\FILESERVER\Deploy\Server2022`. `setup.exe` must sit at the root.
3. Edit `$MediaSource` at the top of `Upgrade-2016-to-2022.ps1`.

## PDQ packages

| Package | Script | Notes |
|---|---|---|
| 0. Preflight Check | `Preflight-Check.ps1` | Report-only readiness check: disk / edition / auto-services (saves baseline for the post-upgrade diff). Run against the whole candidate list first. **Then take a snapshot - manual.** |
| 1. Server 2022 Upgrade | `Upgrade-2016-to-2022.ps1` | PowerShell step. Bump step timeout to **30 min** (media copy). Run as Deploy User. |
| 2. Verify 2022 Upgrade | `Verify-Upgrade.ps1` | Deploy ~2h later. Success = on 2022. Also cleans up media. |
| 3. Post-Upgrade MS Updates | `Install-MSUpdates.ps1` | PowerShell step + a **Reboot step** after it. Bump timeout to 60 min. |

Deploy each: **Deploy Once → add server name → Deploy Now**.

## How the flow works

- Package 1 pre-checks (right OS, disk space, no pending reboot, media reachable),
  copies media to `C:\Temp\Server2022Media`, then launches setup **detached via
  a SYSTEM scheduled task** and exits.
- **PDQ "Success" on package 1 = upgrade LAUNCHED, not finished.**
  If setup ran inside the PDQ step, the first reboot would kill the deployment —
  that's why it's detached.
- Server reboots itself several times over **45–90 min**. Leave it alone.
- Package 2 confirms build ≥ 20348 and deletes the local media + task.
- Package 3 patches, then the PDQ Reboot step finishes it off.

## Exit codes (package 1)

| Code | Meaning |
|---|---|
| 0 | Launched OK (or already 2022) |
| 10 | Not Server 2016 Datacenter |
| 11 | Low disk (< 60GB free) |
| 12 | Pending reboot — reboot first, redeploy |
| 13 | Media share unreachable |
| 14 | Robocopy failed |
| 15 | Datacenter index not found in media |
| 16 | Scheduled task didn't start setup |

## Gotchas / prereqs

- **Snapshot or backup first.** In-place upgrades occasionally brick.
- **Licensing**: volume media + KMS = no key needed. MAK shop → add
  `/pkey XXXXX-...` to `$setupArgs` in the script.
- **VMware**: PVSCSI driver ≥ 1.3.25.0 has caused upgrade failures — check
  VMware Tools version first.
- Don't run on DCs, Exchange, or cluster nodes without their specific
  upgrade procedures.
- Upgrade failed? Read `C:\$WINDOWS.~BT\Sources\Panther\setupact.log` /
  `setuperr.log` on the target.
