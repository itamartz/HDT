---
phase: 04-imaging
verified: 2026-08-13T19:40:00Z
status: gaps_found
score: 9/10 must-haves verified
gaps:
  - truth: "The real image service applies Windows 11 index 1 to a scratch VHDX, writes boot files with bcdboot and registers a recovery image - provable by running the suite"
    status: partial
    reason: >
      The assertions themselves pass (18/18, real 4 GB apply, real bcdboot, real
      reagentc). But ./build.ps1 -Task integration - the documented and only
      supported entry point - FAILS. tests/integration/ImageService.Integration.Tests.ps1
      reads $script:skipSlow (set in BeforeDiscovery) inside BeforeAll at line 53.
      Pester's discovery and run phases do not share a scope, so under build.ps1's
      Set-StrictMode -Version Latest this throws in BeforeAll and the whole
      container dies: 19 failed, 0 of the image assertions executed, BUILD FAILED.
      This is SPIKES S9.15 verbatim - the defect the executor documented, fixed in
      BOTH e2e files, and left in place here. The method lesson S9.14 recorded
      ("run integration and E2E through build.ps1, not Invoke-Pester") was written
      down and then not applied to the file it was about. build.ps1 -Task
      integration has never passed since 3ef27aa introduced the file.
    artifacts:
      - path: "tests/integration/ImageService.Integration.Tests.ps1"
        issue: "line 53 reads $script:skipSlow, a BeforeDiscovery variable, from BeforeAll; throws under StrictMode, so the file cannot run through build.ps1"
    missing:
      - "Recompute the skip condition inside BeforeAll, as tests/e2e/Deployment.E2E.Tests.ps1:115 and tests/e2e/WinPeSmoke.E2E.Tests.ps1:59 already do"
      - "Re-run ./build.ps1 -Task integration elevated and confirm BUILD SUCCEEDED before the phase is called done"
      - "A guard against recurrence: a test that greps tests/integration and tests/e2e for a $script:skip* variable read inside BeforeAll would make S9.15 permanent instead of remembered"
human_verification:
  - test: './build.ps1 -Task e2e, elevated, then confirm CM01 and DC01 are Off, no HDT-* VM is running, and C:\HDTLab\scratch\e2e\deploy-04-windows.png shows Windows 11 rather than a WinPE prompt'
    expected: "All E2E describes green; the machine reaches a settled integration-services heartbeat with the WinPE ISO still attached"
    why_human: "04-04 task 3 is declared checkpoint:human-verify in the plan and is still outstanding. The verifier deliberately did not re-run it: it creates and destroys Hyper-V VMs in the user's live lab, which already lost HDT-PE-Test and S7's deployed disk during 04-04 (SPIKES S9.13). Performing the demonstration on the user's behalf would also defeat the point of the checkpoint."
  - test: "Decide whether the loss of HDT-PE-Test and HDT-PE-Test-osdisk.vhdx matters enough to rebuild SPIKES S7's disk"
    expected: "A decision, not a test"
    why_human: 'A judgement about the lab belonging to the user. C:\HDTLab\vms is confirmed empty.'
---

# Phase 04: Imaging - Verification Report

**Phase Goal:** The destructive parts of deployment, guarded. `IDiskService` and
`IImageService` adapters over DISM, storage cmdlets, `bcdboot` and `reagentc`;
named disk layouts with firmware detection; the `Validate`, `DiskPartition`,
`ApplyImage`, `ApplyUnattend` and `ConfigureBoot` steps; and
`Import-HDTOperatingSystem` with `os.yaml`. Target-disk ambiguity must refuse to
proceed rather than guess. **Exit:** a Hyper-V VM boots into Windows 11 from a
real sequence run driven by the engine.

**Verified:** 2026-08-13
**Status:** gaps_found - one real, currently-red defect
**Re-verification:** No - initial verification

---

## What was actually run

Nothing below is taken from a SUMMARY. Every number is from output read in this
session.

| Command | Result |
|---|---|
| `pwsh 7.5.8 ./build.ps1 -Task test` | **3812 passed, 0 failed, 42 skipped**, 168.65 s, BUILD SUCCEEDED |
| `powershell.exe 5.1.26100.8655 ./build.ps1 -Task test` | **3698 passed, 0 failed, 156 skipped**, 193.77 s, BUILD SUCCEEDED |
| `./build.ps1 -Task lint` | **0 diagnostics across 271 files** |
| Contract real rows, elevated, `HDT_ALLOW_DISK_TEST=1` | **60 passed, 0 failed, 0 skipped** - the real `IDiskService` against this host and the real `IImageService` against the staged Windows 11 WIM |
| `./build.ps1 -Task integration` (elevated) | **42 passed, 19 FAILED - BUILD FAILED** |
| `Invoke-Pester tests/integration/ImageService.Integration.Tests.ps1` (bare) | **18 passed, 0 failed**, 169.73 s |
| Independent ambiguity probe (written by the verifier, 8 scenarios) | all 8 behaved correctly |
| `Hyper-V\Get-VM` before and after | CM01 Off, DC01 Off, no HDT-* VMs |
| `Get-Disk` before and after | host disk 0 GPT / IsBoot True / IsSystem True / 4 partitions, identical |

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|---|---|---|
| 1 | `IDiskService` and `IImageService` exist as real adapters, each with a hand-written fake and one contract both satisfy | VERIFIED | Both contracts run both rows elevated: 60/60, 0 skipped. Real `GetDisk`/`GetPartition`/`GetVolume` and real `Get-WindowsImage` on the staged `install.wim` |
| 2 | Named layouts plan UEFI and BIOS partitions, neither declares an MSR, firmware chooses | VERIFIED | Unit suites green in both shells; integration observes `Initialize-Disk` creating the reserved partition and asserts HDT creates exactly one |
| 3 | The five step types run a deployment through injected services only | VERIFIED | All five present, each takes its service via `Context.Service.GetRequired(...)`; `tests/unit/Imaging.EndToEnd.Tests.ps1` asserts the exact ordered operation list off the real `DEMO-M3/sequence.yaml` |
| 4 | `Import-HDTOperatingSystem`, `os.yaml`, index selection by number/name/edition | VERIFIED | Schema, engine validator, contract and 15 fixtures; `schemas/os.schema.json` validated on the pwsh 7 leg |
| 5 | **Target-disk ambiguity refuses to proceed rather than guessing** | VERIFIED - independently | Tested, not read. See the probe table below |
| 6 | A refusal to wipe is never retried | VERIFIED | `Get-HDTFailureClass` returns `Configuration` for `HDTAmbiguousTargetError` through **both** the `ErrorRecord` leg and the `-ResultData` leg, confirmed by direct call |
| 7 | Engine logic never calls hardware directly | VERIFIED | Grep of `src/Hephaestus/` for every Storage / DISM / `bcdboot` / `bcdedit` / `reagentc` / `diskpart` / `Get-CimInstance` token: every hit outside the three adapter files is inside a comment or help block. Zero live calls |
| 8 | Naming, no-MDT and PS5.1 contracts pass; analyzer clean; suite green under both shells | VERIFIED | See the table above |
| 9 | **A Hyper-V VM boots into Windows 11 from a sequence run driven by the engine** | VERIFIED (from evidence; not re-executed) | See "The exit criterion" below |
| 10 | The real image service's apply / bcdboot / reagentc are provable by running the suite | **FAILED** | `./build.ps1 -Task integration` dies before the first image assertion. 19 failures, BUILD FAILED |

**Score: 9/10.**

---

### Truth 5 in detail - the refusal, tested rather than read

The single most important behaviour in the phase, so it was not accepted from a
green suite. A probe was written against the module and the fakes directly,
seeding disk topologies and reading the fake's operation journal for **write**
calls (`ClearDisk`, `InitializeDisk`, `NewPartition`, `FormatVolume`,
`SetPartitionDriveLetter`, `SetPartitionType`, `RemovePartition`):

| Scenario | Result | Writes |
|---|---|---|
| Two identical eligible 64 GB disks | Failed, `HDTAmbiguousTargetError`, *"2 disks qualify ... HDT will not guess which one to wipe"* | **0** |
| No disks at all | Failed, `HDTNoTargetDiskError`, points at the boot image's storage driver | **0** |
| Only disk is `IsBoot`/`IsSystem` | Failed, `HDTNoTargetDiskError`, *"disk 0 is the disk this machine booted from"* | **0** |
| `diskNumber: 0` naming the **boot** disk explicitly | Failed, `HDTUnsafeTargetError`, *"This rule is not overridable by naming the disk."* | **0** |
| Ambiguity + `diskNumber: 1` | Completed - and every write named disk **1**, never disk 0 | 13, all on disk 1 |
| `-WhatIf` on a clean single-disk machine | Completed, planned and logged | **0** |
| Only disk carries the workspace letter `Z:` | Failed, *"disk 0 holds drive letter Z, which this deployment is reading from or writing to"* | **0** |
| Classification of the refusal | `Configuration` via both classifier legs -> never retried | - |

Corroborated against **real** hardware by the integration run: against this
host's own disks, `Invoke-HDTDiskPartitionStep` refused, named the rules that
excluded each disk, *"wrote nothing when it refused"*, and refused an explicit
`diskNumber` naming disk 0.

The rule 1-5 / rule 6-7 split is real: an explicit `diskNumber` overrides the
size and USB rules (with a warning, observed in the integration log) and can
never override boot/system, a protected letter, read-only, offline or existing
data.

---

### The exit criterion

**Demonstrated. Not re-executed by the verifier, deliberately.**

The evidence on disk, all timestamped 2026-08-13 17:49-17:59, triangulates:

| Artifact | What it shows |
|---|---|
| `C:\HDTLab\scratch\e2e\deploy-04-windows.png` | Inspected. A **Windows 11 desktop**, Start menu open, taskbar, Edge/Settings/File Explorer pinned, signed in as **Administrator**. Not a WinPE prompt. Colours are wrong exactly as SPIKES S4 predicts for the thumbnail byte order |
| `DISK-BEFORE.json` | Captured **through `IDiskService` inside WinPE** a moment before the repartition: disk 0, 68 719 476 736 B, `BusType SAS`, `PartitionStyle RAW`, `IsBoot false`, `IsSystem false`, empty serial |
| `TARGET-PARTITION.json` | The disk afterwards: ESP `{c12a7328...}` 272 629 760 B, Windows `{ebd0a0a2...}`, Recovery `{de94bba4...}`. Three partitions, no MSR - S9.10 |
| `machines\4406D547-....yaml` | DESIGN 3.1 source 2, keyed on the guest UUID, setting `HDTComputerName: HDT-M3-01` |

**The VM was deployed by the engine, not by a script.**
`tests/e2e/payload/Start-HDTLabDeployment.ps1` was read line by line: it finds
the content disk, imports `powershell-yaml` and `Hephaestus`, builds the real
adapters, gathers facts, resolves variables, builds a context, and makes
**exactly one** call to `Invoke-HDTTaskSequence`. It contains no partitioning, no
apply, no `bcdboot`. `tests/unit/StartHDTLabDeploymentPayload.Tests.ps1` enforces
that by parsing the file, and that test is green in both shells.

`tests/e2e/Deployment.E2E.Tests.ps1` (780 lines) is a genuine executable exit
criterion, not a rubber stamp: it asserts the machine reached Windows from the
**integration-services heartbeat** (which WinPE never reports) with the ISO still
attached and the boot order untouched, and reads the deployed computer name
**offline from the SYSTEM hive**.

**Two honest caveats:**

1. **I did not re-run it.** 04-04 task 3 is `checkpoint:human-verify` and is still
   outstanding. The run creates and destroys VMs in the user's live lab, which
   already lost `HDT-PE-Test` and S7's deployed disk during 04-04.
2. **The engine's own log from the demonstration did not survive.** The E2E reads
   `RESULT.json`, `LAUNCHER.log`, `HDT.jsonl` and `state.json` off the content
   disk into memory and asserts on them, but only persists the screenshots,
   `DISK-BEFORE.json` and `TARGET-PARTITION.json` to the artifact root. The
   `AfterAll` then destroys the disk. So "reported Succeeded on all five steps"
   cannot be re-checked from artifacts - only by re-running. Worth fixing: copy
   those four files beside the screenshots.

---

### The gap - `./build.ps1 -Task integration` is red

```
Running tests from '...\tests\integration\ImageService.Integration.Tests.ps1'
[-] ImageService.Integration.Tests.ps1 failed with:
RuntimeException: The variable '$script:skipSlow' cannot be retrieved because it has not been set.
at <ScriptBlock>, ...\ImageService.Integration.Tests.ps1:53
Tests Passed: 42, Failed: 19
BUILD FAILED: 19 integration test(s) failed.
```

`$script:skipSlow` is set in `BeforeDiscovery` (line 23) and read in `BeforeAll`
(line 53). Pester's two phases do not share a scope. Under `build.ps1`'s
`Set-StrictMode -Version Latest` it throws; without StrictMode it evaluates to
`$null` and `if (-not $null)` is TRUE, so the guard means the opposite of what it
says. **This is SPIKES S9.15, in the file the lesson was learned from.** Both
E2E files carry the fix (`Deployment.E2E.Tests.ps1:115`,
`WinPeSmoke.E2E.Tests.ps1:59`, each with a comment explaining it); this one does
not. The two sibling integration files never had the problem.

Introduced in `3ef27aa` and never touched again, so `./build.ps1 -Task integration`
has not passed at any point in this phase.

**The underlying code is fine - the harness is broken.** Run the same file with a
bare `Invoke-Pester`, which is what the executor evidently did, and it is
**18/18 green in 169.73 s**: the real 4 GB Windows 11 apply, `ntoskrnl.exe` on
the volume, `bcdboot` writing `bootmgfw.efi` and a BCD store, `reagentc`
reporting success *and* the assertion that it did **not** actually enable WinRE
(S9.7), and the unattend Setup will consume. So this is a one-line defect in a
guard, not a broken image service. It is still a defect, and it is the exact
class the phase claimed to have learned about.

---

## TDD

**Followed.** 51 commits from `089364c` to `e550670`, walked in order with each
commit's file list. Every `feat(04-*)` that adds `src/Hephaestus/` is immediately
preceded by a `test(04-*)` that adds only tests and fixtures:

```
9b04bb9 test(04-01) 7 test files   ->  c563480 feat(04-01) the fake disk service
a50e090 test(04-01) 1 contract     ->  1ccb9e8 feat(04-01) the real IDiskService
e4204bb test(04-02) 3 test files   ->  85eccbb feat(04-02) Select-HDTTargetDisk
59556d7 test(04-02) 3 test files   ->  0fc2d44 feat(04-02) named layouts
2297a62 test(04-02) 17 test files  ->  f6d2abc feat(04-02) the OS catalog
737a3ba test(04-03) 2 test files   ->  d4781fd feat(04-03) the DiskPartition step
289469f test(04-04) RAW disk       ->  0a7ffa7 fix(04-04)  the partitioning order
3ef27aa test(04-04) image integ.   ->  179bb1d fix(04-04)  what a real apply exposed
```

The discipline held even for the hardware-driven fixes, which is the harder case.

**Two nits, neither a defect:** `57dc2f9` is labelled `test(04-04)` but also
carries the `ApplyUnattend` 15-character refusal in `src/` - test *alongside*
implementation, correctly ordered but mislabelled. `fb51df2` and `2491ee7` are
`fix(` commits carrying their own tests in the same commit rather than a
preceding RED.

---

## Contract and shell results

| Contract | Result |
|---|---|
| `Naming.Contract` | PASS - every function `Verb-HDTNoun`, approved verbs, no aliases, no `DefaultCommandPrefix` |
| `NoMdtDependency.Contract` | PASS - every file in `src/` and `build.ps1` |
| `PowerShell51Compatibility.Contract` | PASS - every source file parses and is accepted |
| `DiskService.Contract` / `ImageService.Contract` | PASS - both rows, fake and real |
| `StepContract` | PASS - discovers and invokes all five new step types |
| `OsSchema.Contract` | PASS on pwsh 7 |
| PSScriptAnalyzer | PASS - 0 diagnostics / 271 files |

**The 5.1 leg skips 114 more tests than pwsh 7.** Every one is a JSON-Schema test
(`Test-Json` does not exist on 5.1) or a PSScriptAnalyzer test (SPIKES S5: not
importable under 5.1 on this host). Both skips print a warning naming the reason,
and the engine-side validator (`Assert-HDTOperatingSystemDocument`) still runs
under 5.1 and is asserted to agree with the schema on the pwsh 7 leg. This is the
established, documented arrangement from earlier phases, not a phase-04 gap.

The other skips are opt-in real-hardware rows. Run elevated with
`HDT_ALLOW_DISK_TEST=1` they all execute and pass - worth knowing that a default
`build.ps1 -Task test` silently skips the real `IDiskService` row.

---

## Lab safety

| Check | Before | After |
|---|---|---|
| `CM01` | Off | Off, untouched |
| `DC01` | Off | Off, untouched |
| `HDT-*` VMs | none | none |
| Host disk 0 | GPT, `IsBoot` True, `IsSystem` True, 4 partitions | identical |
| `C:\HDTLab\scratch\integration` | empty | empty (the `AfterAll` cleaned up after a failing run) |
| Working tree | clean | clean |

The scratch VHDX the integration suite mounted appeared as disk 1
(`IsBoot False`, `IsSystem False`) mid-run and was gone afterwards.

**`C:\HDTLab\vms` is empty**, confirming the loss SPIKES S9.13 reports rather
than tidies away. The hardening it prompted (`Assert-HDTLabVmPath` refusing the
VM root, anything outside it, and any file inside it not belonging to this VM) is
present and unit-tested - those tests are green in both shells.

---

## Anti-patterns

None found. No `TODO`/`FIXME`/`PLACEHOLDER`, no stub returns, no empty handlers
in any phase-04 source file. The `bcdedit`/`reagentc`/`Get-Disk` tokens appearing
in `src/` outside the adapters are all inside comment-based help explaining *why*
the engine does not call them.

---

## Gaps Summary

**The phase goal is achieved.** The destructive parts exist, they are guarded, the
guards were tested rather than read, no engine code touches hardware, both shells
are green, the analyzer is clean, and a real Hyper-V VM was demonstrably deployed
into Windows 11 by `Invoke-HDTTaskSequence` rather than by a script.

**One thing is genuinely broken:** `./build.ps1 -Task integration` fails. The
image half of the integration suite - the only automated proof that the real
`Expand-WindowsImage`, `bcdboot` and `reagentc` legs work - cannot run through
the supported entry point. The assertions pass when the file is run around
`build.ps1`, which is exactly how the defect survived: SPIKES S9.14 says in
writing "run integration and E2E through `build.ps1`, not `Invoke-Pester`", and
that is the one thing that was not done to this file. It is a one-line fix plus a
re-run, and it should not be waved through, because the phase's own recorded
lesson is that a guard which means the opposite of what it says is worse than no
guard.

**Outstanding for the human:** 04-04 task 3's checkpoint (`./build.ps1 -Task e2e`
elevated) and the decision on rebuilding S7's lost disk.

---

_Verified: 2026-08-13_
_Verifier: Claude (gsd-verifier)_
