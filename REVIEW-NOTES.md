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

## Pass 3 — final review

_(pending)_

## Pass 3 — final review

_(pending)_
