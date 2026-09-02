# Gen2 Conversion — Codex Review Iterations

Adversarial review loop: rework → GPT-5.6 Sol (high reasoning) review → repeat.
Notes per pass for review.

## Pass 1 — baseline review of the original 3-script design (2026-09-02)

**Verdict: "do not run in production." 15 findings — 1 blocker, 8 high.**

Key findings and what was done:

| # | Finding | Action taken |
|---|---|---|
| 1 | **BLOCKER**: script rebooted the Gen1 VM after mbr2gpt — BIOS can't boot a GPT disk; VM would die | Architecture change: conversion now runs in an isolated staging VM on a COPY; staging shuts down, never reboots. First boot of the converted disk is in the Gen2 shell. |
| 8 | "Original untouched" claim was false — Prepare converted the original disk irreversibly | Copy-first design: original MBR disks are never modified; they ARE the rollback |
| 2 | Missing `-ErrorAction Stop` → failures could email SUCCESS | `$ErrorActionPreference='Stop'` in script + every remote block; copy verification added |
| 3 | `.vhd` copied unchanged; Gen2 requires VHDX | Preflight detects format; `Convert-VHD` VHD→VHDX during copy |
| 4 | First-sorted disk assumed to be boot disk | Boot disk resolved explicitly = IDE 0:0 (Gen1 BIOS boot location); abort if not exactly one |
| 7 | Shutdown before preflight; space only checked in -WhatIf | ALL preflight (space enforced, names, checkpoints, chains, guest probe) runs before shutdown |
| 9 | BitLocker fail-open, C: only | Fail-closed, all volumes, suspension verified, escrow warning logged |
| 10 | Checkpoint count ≠ self-contained disk | `Get-VHD` per disk; abort on any `ParentPath` (differencing chain) |
| 5 | Raw Hyper-V VM loses VMM properties, breaks HA | Partially: HA/clustered VMs now REFUSED (manual path); static MACs carried; remaining VMM-property losses documented in output + README. Full `New-SCVirtualMachine` JobGroup rebuild deliberately NOT done (complexity vs. lab/non-HA scope). |
| 6 | NIC rebuild lossy / wrong abstraction | Static MAC carried; VM-network-only NICs refused; VLAN carried; remaining losses documented |
| 11 | `New-VM -Path` put config one level up | `-Path` now the VM's own folder |
| 12 | VM names not unique in VMM | Exactly-one-match enforced; ID+host printed |
| 13 | Verify said "safe to decommission" on thin checks | Added: spec compare vs original, Secure Boot, DNS, domain secure channel, event-log errors, original-left-off check; verdict reworded to "basic checks passed — decommission is an operator decision" |
| 14 | mbr2gpt exit 100 mishandled | Distinct converted-but-unbootable message (only the COPY is affected now) |
| 15 | `Send-MailMessage` obsolete/insecure | ACCEPTED as-is: non-secure SMTP relay is the explicit requirement (internal relay). Warning suppressed. |
| — | No runbook; step labels conflicted | Prepare-Gen2.ps1 removed (merged into one pipeline); authoritative runbook added to README |

**Accepted risks (deliberate):** plain SMTP (site standard); no VMM JobGroup
clone (HA VMs refused instead); VMM cloud/custom-property loss (documented).

## Pass 2 — review of the reworked scripts (2026-09-02)

**Verdict: architecture endorsed, "do not run yet" — 11 findings (7 high).
Two pass-1 fixes were judged incomplete (VHD conversion, BitLocker).**

| # | Finding | Action taken |
|---|---|---|
| 1 | `Convert-VHD` ran against the ATTACHED original .vhd (unsupported) | Copy the .vhd first, convert the UNATTACHED copy, delete the temp; result validated with `Get-VHD`; temp space added to the space check |
| 2 | BitLocker still fail-open if the module is absent | Fail-closed everywhere: missing tooling = ABORT (with `manage-bde` fallback probe); Verify now has a real "BitLocker resumed" CHECK (protectors present + protection off = FAIL) |
| 3 | Failure message could lead operator to start original while -temp runs (duplicate server) | Catch block now queries and prints ACTUAL states of original/temp/staging + explicit "start original ONLY if others are Off" rule; same warning in success output + README |
| 4 | Staging failure left a registered running clone; heartbeat ≠ PS ready | try/finally guarantees staging is powered off + shell removed on every path; PowerShell Direct readiness retried (12x15s) after heartbeat |
| 5 | Duplicate destination filenames could overwrite copies | Copy plan built in preflight with guaranteed-unique names (`dN-` prefix on collision) |
| 6 | Target folder could nest inside the original VM folder | Target now derives from the VM's own config folder (host `Get-VM .Path`) → true sibling; ancestor/descendant assertions added |
| 7 | Runbook deleted rollback before backing up the new VM | README order fixed: rename → re-validate → backup new + verify → retain old through rollback window → delete last |
| 8 | -WhatIf silently skipped guest checks when VM off | Preflight now reports "PASSED WITH GAPS" + dry run states what was NOT tested |
| 9 | Host-level name/switch collisions found too late; VMM refresh unverified | Preflight now checks host `Get-VM` for temp/staging names + `Get-VMSwitch` for every NIC switch; post-refresh VMM presence verified |
| 10 | VHD forced to Dynamic; loss list understated | `-VHDType` override removed (source type preserved); loss list expanded (CPU limits/weights, memory buffer/priority, auto start/stop, NIC offloads, controller layout) |
| 11 | Verify could false-pass (silent event log) and false-fail (DCs/workgroup on secure channel) | Event log unreadable = FAIL; secure-channel check skipped on non-members and DCs; ambiguous original name = explicit FAIL, not silent skip |
| 12 | Wrong mbr2gpt log filename in guidance | Corrected to `%windir%\setupact.log` / `setuperr.log` |

## Pass 3 — final review (2026-09-02)

**Verdict: "not safe to pilot as-is" — 4 must-fixes + a BitLocker gate.
After fixing: approved for a SUPERVISED PILOT on a backed-up, non-HA,
non-critical, non-BitLocker VM.** Of the 12 pass-2 items it audited:
6 fixed, 5 partial, 1 unresolved.

Must-fixes and what was done (post-review, same day):

| # | Finding | Action taken |
|---|---|---|
| 1 | Filename allocator could STILL collide (Codex executed it and proved `data.vhdx, d2-data.vhdx, data.vhdx` → duplicate) | Allocator now loops until the name is actually unused + a grouped-duplicate assertion on the finished plan |
| 2 | Staging cleanup logged "guarantee" while suppressing failures | Cleanup is now "best-effort + verified": finally re-queries the VM and reports honestly; an independent post-check refuses to build Gen2 while any staging shell exists |
| 3 | PS Direct retry loop retried bad credentials (lockout risk) | Auth/credential errors now abort immediately; only transport/not-ready errors retry |
| 4 | Missing VMM discovery still reported SUCCESS | Discovery now verified (with one retried refresh); absence = run FAILS as INCOMPLETE |
| 5 | BitLocker gate | Verify: unknown state = FAIL (manage-bde fallback added); conversion: any non-On/Off state = abort; README: explicit "no BitLocker VMs in pilot" + protector-recreate/escrow manual step |

Nice-to-haves also applied: README no longer calls -WhatIf a "full" preflight
(and requires PREFLIGHT PASSED, not PASSED WITH GAPS, before a pilot); loss
list expanded in README; DNS check skips workgroup machines; `-LiteralPath`
on copy/remove; disk set revalidated between preflight and copy.

## SCVMM addendum — VMM-native build + targeted verification (2026-09-02)

Requirement added after pass 3: **"fully supported on SCVMM."** Phase 4 was
rebuilt to create the VM THROUGH VMM (New-SCHardwareProfile + JobGroup +
New-SCVirtualDiskDrive/-SCVirtualNetworkAdapter + New-SCVirtualMachine).
Bonus: VM networks and port classifications now carry, and HA VMs are no
longer refused (HA flag carried; HA path still untested).

A targeted Codex pass verified every cmdlet parameter combination against
Microsoft's 2019/2022/2025 VMM docs. Result: parameter sets valid, plus:

| Finding | Action taken |
|---|---|
| **P1: NIC defaulted to EMULATED — Gen2 only supports synthetic; build would fail on any VM with NICs** | `-Synthetic $true` added |
| P1: boot order not deterministic | `FirstBootDevice = 'SCSI,0,0'` in the hardware profile + boot disk marked `-BootVolume -SystemVolume` |
| P2: >64 disks overflow SCSI controller 0 | Preflight guard added |
| P2: network-object lookups accepted ambiguous names | Exactly-one resolution enforced |
| P2: no post-create verification | Generation/disk count/NIC count/HA verified against expectations before start |

## Where this stands for the pilot

1. Pick a **non-critical, non-HA, non-BitLocker** Gen1 VM with a verified backup
2. Run `-WhatIf` while it's running — require `PREFLIGHT PASSED` (no gaps)
3. Run the conversion supervised; follow the README runbook incl. the
   retention window before deleting the original
4. Not validated by any reviewer: actual runtime behavior on Hyper-V/SCVMM
   (no Windows environment available to either reviewer) — the pilot IS the
   runtime test. Codex also noted there are no Pester tests.
