---
phase: 04-imaging
plan: 04
subsystem: imaging
tags: [integration, e2e, winpe, hyper-v, lab-safety, disk, image, milestone]
requires: ["04-01", "04-02", "04-03"]
provides:
  - "build.ps1 -Task integration and -Task e2e, dispatched and not part of ci"
  - "the lab helpers, with PROJECT.md's Hyper-V safety rules enforced in code"
  - "the destructive half of IDiskService and IImageService, proven on real disks"
  - "ROADMAP M3's exit criterion, as an executable test"
affects:
  - "src/Hephaestus/Public/Steps/Invoke-HDTDiskPartitionStep.ps1"
  - "src/Hephaestus/Public/Steps/Invoke-HDTApplyUnattendStep.ps1"
  - "tests/helpers/HDTFakes/HDTFakes.psm1"
  - "docs/DESIGN.md"
  - "docs/ROADMAP.md"
  - ".planning/SPIKES.md"
tech-stack:
  added: []
  patterns:
    - "guards enforced in code before any Hyper-V call, asserted by AST offset"
    - "the launcher proven to do no deployment work, by parsing it"
    - "a probe that writes its answer to a disk, so the harness reads a file"
key-files:
  created:
    - "tests/integration/DiskService.Integration.Tests.ps1"
    - "tests/integration/DiskPartition.Integration.Tests.ps1"
    - "tests/integration/ImageService.Integration.Tests.ps1"
    - "tests/e2e/WinPeSmoke.E2E.Tests.ps1"
    - "tests/e2e/Deployment.E2E.Tests.ps1"
    - "tests/e2e/payload/Start-HDTLabDeployment.ps1"
    - "tests/e2e/payload/Start-HDTLabProbe.ps1"
    - "tests/helpers/HDTTestTools/tools/Assert-HDTLabVmName.ps1"
    - "tests/helpers/HDTTestTools/tools/Assert-HDTLabVmPath.ps1"
    - "tests/helpers/HDTTestTools/tools/Assert-HDTLabScratchDisk.ps1"
    - "tests/helpers/HDTTestTools/tools/New-HDTLabScratchDisk.ps1"
    - "tests/helpers/HDTTestTools/tools/Remove-HDTLabScratchDisk.ps1"
    - "tests/helpers/HDTTestTools/tools/New-HDTLabVirtualMachine.ps1"
    - "tests/helpers/HDTTestTools/tools/Remove-HDTLabVirtualMachine.ps1"
    - "tests/helpers/HDTTestTools/tools/New-HDTLabContentDisk.ps1"
    - "tests/helpers/HDTTestTools/tools/Send-HDTLabVmText.ps1"
    - "tests/helpers/HDTTestTools/tools/Save-HDTLabVmScreen.ps1"
    - "tests/helpers/HDTTestTools/tools/Wait-HDTLabVmState.ps1"
    - "tests/helpers/HDTTestTools/tools/Get-HDTLabOfflineComputerName.ps1"
    - "tests/unit/BuildScript.Tests.ps1"
    - "tests/unit/New-HDTLabVirtualMachine.Tests.ps1"
    - "tests/unit/New-HDTLabScratchDisk.Tests.ps1"
    - "tests/unit/StartHDTLabDeploymentPayload.Tests.ps1"
    - "tests/integration/README.md"
    - "tests/e2e/README.md"
  modified:
    - "build.ps1"
    - "src/Hephaestus/Public/Steps/Invoke-HDTDiskPartitionStep.ps1"
    - "src/Hephaestus/Public/Steps/Invoke-HDTApplyUnattendStep.ps1"
    - "tests/helpers/HDTFakes/HDTFakes.psm1"
    - "tests/fixtures/disk/gen2-vm-raw-disk.json"
decisions:
  - "integration and e2e are accepted AND dispatched; an empty dispatch is now a failure"
  - "the workspace is a locally attached content disk, not a share - the isolated switch cannot reach one"
  - "DiskPartition skips ClearDisk on a RAW disk; the decision lives in the step, not the adapter"
  - "ApplyUnattend refuses an illegal computer name rather than truncating it"
  - "the deployed machine's name comes from a per-machine override, DESIGN 3.1 source 2"
metrics:
  duration: "~5 h"
  completed: "2026-08-13"
---

# Phase 04 Plan 04: The first real run — integration, WinPE and the M3 exit criterion Summary

**A Generation 2 VM on the isolated `HDT Lab` switch was partitioned, imaged,
unattended and boot-configured by `DEMO-M3` run through
`Invoke-HDTTaskSequence`, and booted into Windows 11 with the installation media
still attached — and the eight things that had to be corrected to get there are
worth more than the demonstration.**

## The demonstration

```powershell
# elevated
./build.ps1 -Task integration     # ~4 min, real DISM and a real VHDX
./build.ps1 -Task e2e             # ~18 min, Hyper-V
```

`tests/e2e/Deployment.E2E.Tests.ps1` builds `HDT-M3-Deploy` — Gen 2, Secure Boot
on, 4 GB, 2 vCPU, files under `C:\HDTLab\vms\` — boots it from SPIKES S1/S3's
WinPE ISO, types one line at the prompt with `Msvm_Keyboard`, and lets the
engine run the five imaging steps against the **real** disk and image services.
It then starts the VM again **with the ISO still in the DVD drive and the boot
order untouched**, and asserts a settled integration-services heartbeat, which
WinPE never reports and full Windows always does.

| Leg | Time |
|---|---|
| Content disk staged (engine, `powershell-yaml`, workspace, 4 GB WIM) | 12–14 s |
| WinPE boot → all five steps → shutdown | 274 s wall, of which the engine reported **100 s** |
| First Windows boot to a settled heartbeat | 265–318 s |
| Apply of Windows 11 index 1 alone (integration suite) | **132–134 s** |

**Beside SPIKES S6's hand-run numbers:** S6 applied the same 4 GB WIM **over SMB
in 95 s**. HDT's own apply from a *local* disk into a *dynamic* VHDX took
132–134 s. **The network was never the slow part** — growing the VHDX is. M4
should not treat SMB as the thing to optimise.

## What the fakes had been wrong about

This is the value of the plan. Every one of these was green in a 3 700-test unit
suite.

**1. `Clear-Disk` throws on a RAW disk — and every factory-fresh disk is RAW.**

```
Clear-Disk -Number N -RemoveData -RemoveOEM
-> The disk has not been initialized.
```

`Invoke-HDTDiskPartitionStep` called `ClearDisk` unconditionally and the fake
shrugged at it. **HDT could not have partitioned a new machine.** SPIKES S6's
recipe holds only for a disk that already carries a partition table. The step
now skips the clear when the target is RAW, records `cleared` in its result and
says so in the log; the fake refuses the same call for the same reason.

**2. Windows Setup silently discards a `ComputerName` over 15 characters.**

The first full deployment reported `Succeeded` on all five steps, wrote no
`step.fail` — and produced a machine called `WIN-N91191NN153`. `rules.yaml`'s
`PC-%HDTSerialNumber%` fallback outranks a sequence's own defaults (correctly,
per DESIGN 3.1), and a Hyper-V VM's serial is 32 characters. **The deployment
succeeded and named the machine something nobody chose, and no log mentioned
it.** `ApplyUnattend` now refuses the name with `HDTConfigurationError` rather
than truncating — a silently shortened name is the same failure with a different
spelling — and the E2E supplies `HDT-M3-01` through a **per-machine override**
(DESIGN 3.1 source 2), keyed on the VM's UUID. That tier had never run end to
end before.

**3. `Initialize-Disk` creates a Microsoft Reserved partition on the host and
not inside WinPE.** The deployed disk carries ESP / Windows / Recovery and
nothing else. S6's own hand-run log said `#1 S 260MB #2 W 64250MB #3 1024MB` and
nobody had noticed; the "it creates its own MSR" finding came from a *host-side*
spike and was generalised without evidence. It changes nothing about
correctness: HDT never creates one either way, the 16 MB is an allowance, and
the recovery partition's `UseMaximumSize` absorbs it.

**4. `reagentc /setreimage` exits 0, prints "Operation Successful" and registers
nothing.** `/info` on the same offline target still reports
`Windows RE status: Disabled`. It does not refuse — it reports success, which is
exactly what the adapter checks. **WinRE on the deployed machine is Setup's
doing, not `ConfigureBoot`'s.** A green run does not prove WinRE was configured,
and the test asserts the misleading behaviour so that the day it changes,
somebody is told.

**5. The MSR is 16 759 808 bytes at offset 17 408** — which together are
*exactly* the 16 777 216 the layouts carry as `ReservedSizeByte`. Right to the
byte rather than lucky.

**6. FAT32 has no lower case in a volume label.** The layout asks for `System`;
`Get-Volume` reports `SYSTEM`. NTFS preserves case. Nothing may match a label
case-sensitively.

And one that had been recorded as unverified and turned out fine:
**`Set-Partition -GptType` after `Format-Volume` works** — the ESP is created as
basic data, lettered, formatted FAT32, retyped, and the machine boots from it.

## The engine inside WinPE

The plan called `powershell-yaml` "the single most likely way this plan
discovers a problem" and wrote a three-rung fix ladder. **No rung was needed.**
`tests/e2e/WinPeSmoke.E2E.Tests.ps1` ran before the deployment on purpose and
found, first try:

- **PowerShell 5.1.26100.1 Desktop**, as S1 recorded.
- **`powershell-yaml` 0.4.12 imports from a STAGED copy** on a plain data disk —
  not installed, not on the standard module path — its `net47` flavour loading
  against `WinPE-NetFx`.
- **`Get-HDTMachineFact` returned 18 facts** against the real CIM provider,
  registry and environment. `HDTIsVM True`, `HDTIsUEFI True`,
  `HDTSecureBootEnabled True`, `HDTMemory 2046` on a 2 GB VM (which is why
  `DEMO-M3`'s `minRamMB: 2048` is right), `HDTTPMVersion` and `HDTSystemSKU`
  empty on a VM.
- **The real documents came back**: `DEMO-M3` (5 steps), `rules.yaml` (4 rules),
  `os.yaml`. Importing the parser is necessary; a document coming back is what
  task 3 actually depended on.
- WinPE assigned the content disk `C:` and the RAM disk `X:`. **Nothing may
  assume a letter**, which is why the launcher, the probe and the typed line all
  scan.

## Deviations from the plan

### Auto-fixed (Rules 1–3)

**1. [Rule 1 — Bug] `ClearDisk` on a RAW disk.** See finding 1. Fake + step,
each with its own RED/GREEN pair. Commits `289469f`, `0a7ffa7`.

**2. [Rule 2 — Missing validation] The computer name.** See finding 2. Five
failing tests first. Commit `57dc2f9`.

**3. [Rule 3 — Blocking] `Get-HDTFailureClass` is private**, so an integration
test calls it inside the module rather than it being exported for a test's
convenience.

**4. [Rule 1 — Bug] F12 again, and it hid a safety guard.**
`tests/unit/New-HDTLabScratchDisk.Tests.ps1` read a fixture as
`@(... | ConvertFrom-Json)[0]`, which under 5.1 is the whole array — so
`Assert-HDTLabScratchDisk` saw an `Object[]` with no `IsBoot` property and had
nothing to refuse. **The guard that keeps the integration suite off the
developer's disk was asserting nothing under 5.1 and green under pwsh 7.**
Caught only by the dual-engine run. Commit `fb51df2`.

**5. [Rule 2 — Missing guard] `Assert-HDTLabVmPath`.** See "the lab" below.

**6. [Rule 1 — Bug] The lab-safety assertion was comparing nothing.** The
CM01/DC01 snapshot read `$_.MemoryStartupBytes` — which is `New-VM`'s *parameter*
name, not the property `Get-VM` returns (`MemoryStartup`). **Without StrictMode a
missing property is `$null`, `[long] $null` is `0`, and the assertion protecting
the user's live lab held `0` against `0`.** Found only when the suite was finally
run through `./build.ps1 -Task e2e`, which sets `Set-StrictMode -Version Latest`;
every earlier run had been a bare `Invoke-Pester`.

**7. [Rule 1 — Bug] A `BeforeDiscovery` variable is not readable from
`BeforeAll`.** `$script:skipDeployment` threw under StrictMode — and without it
evaluated to `$null`, so `if (-not $null)` was **true** and the expensive body
ran on a machine that was supposed to skip it. Both files now recompute the
condition in `BeforeAll`, as the integration files already did.

**The method lesson, and it is the one to carry forward: run an integration or
E2E suite through `build.ps1`, not through `Invoke-Pester` directly.** The build
script's `StrictMode` and `$ErrorActionPreference` are part of the environment
these tests are meant to run in. Two defects — one of them in the lab-safety
assertion itself — survived six green runs because that step was left to last.

### Departures from what the plan specified

**The `Mock` on `Hyper-V\New-VM` was replaced, not skipped.** The plan asked for
a mock proving no Hyper-V command is called when a helper refuses. It cannot
work: a module-qualified call resolves straight into the module and never
consults the function table Pester injects into, so the mock is never consulted
and the assertion always passes — worse than none. What replaced it is stronger
and runs on a machine with no Hyper-V: AST assertions that every Hyper-V command
in every lab helper is module-qualified, that no `Get-VM` is unfiltered, and
that `Assert-HDTLabVmName` is called **before the first Hyper-V command**,
compared by extent offset.

**Two extra guard commands** (`Assert-HDTLabVmName`,
`Assert-HDTLabScratchDisk`) beyond the plan's file list, because a guard that a
unit test can call directly is a guard that can be proven without mounting
anything. A third (`Assert-HDTLabVmPath`) was added later, for the reason below.

**The smoke VM keeps one small disk**, as the plan required — so the RAW 64 GB
row that closes `gen2-vm-raw-disk.json` is captured by the *deployment* run
instead, through `IDiskService`, a moment before the disk is repartitioned.
Better provenance than a host-side projection.

**The deployment E2E creates the VM before the content disk**, because the
per-machine override is keyed on the VM's UUID.

**`Start-HDTLabProbe.ps1`** is an extra payload the plan did not name; the smoke
check needed something to run.

## The lab

`CM01` and `DC01` are **exactly as they were** — `Off`, same memory, same
switch, recorded before every run and asserted identical after, in `AfterAll`
blocks that run on failure too. This host's disk 0 is GPT / `IsBoot` / `IsSystem`
with the same partitions it started with, and every destructive call in the
integration suite was asserted to name the scratch disk number and no other.
`C:\HDTLab\scratch\integration` is empty.

**But `C:\HDTLab\vms` was emptied, and that must be said plainly.** Lost:
`HDT-PE-Test`, `HDT-PE-Test-osdisk.vhdx` (the Windows 11 disk S7 deployed and S8
ran its autologon legs against, which sat **loose at the root** of that folder),
and a leftover `HDT-AutoLogon-Spike` folder. The WinPE media and ISO under
`C:\HDTLab\scratch\pe\` survive, so the boot vehicle is intact.

**The cause was never established and it would be dishonest to claim one.** The
Hyper-V VMMS log puts the `HDT-PE-Test` deletion at 17:24:06, alongside a
`-Task e2e` run that failed instantly with every test reporting "a setup in some
parent block failed" — an error not captured before the evidence was gone. No
lab helper names anything but the exact VM it is given; the developer was also
working in the same lab in that window.

What was fixed regardless: the delete was **not narrow enough to make the
accident impossible**, which is a defect in the one piece of code whose whole
job is to make it impossible. `Assert-HDTLabVmPath` now refuses the VM root
itself (`Join-Path` with an empty name yields it), anything outside the root,
and anything inside it that is not this VM's own folder — **including a VHDX
sitting loose beside the VM folders**, which the old `-like 'C:\HDTLab\vms\*'`
test accepted and which is exactly what was lost. Seven unit tests, watched
failing first.

## Suite state

| Run | Result |
|---|---|
| `pwsh ./build.ps1 -Task ci` | **green** — 3 803 passed, 0 failed, 42 skipped; ran neither integration nor e2e |
| `powershell.exe ./build.ps1 -Task test` (5.1) | **green** — 3 689 passed, 0 failed, 156 skipped |
| `./build.ps1 -Task lint` | **green** — 0 diagnostics across 271 files |
| `./build.ps1 -Task integration` (elevated) | **green** — 43 + 18 passed |
| `./build.ps1 -Task e2e` (elevated) | **green** — 52 passed, 0 failed (18 smoke + 34 deployment) |

## What M3 ships without

- **No reboot into the full OS driven by the engine, and no autologon resume.**
  `DEMO-M3` has no `Restart` step, deliberately: in WinPE the registry and LSA
  secret are the RAM disk's. The first logon of the machine being built is
  configured by the unattend. The handoff is M4's `Start-HDTDeployment`.
- **No drivers** (M5); **no applications, updates or roles** (M6).
- **No share.** The workspace is a locally attached content disk, because
  PROJECT.md requires the isolated switch and S6 records that a VM there cannot
  reach a share on the host. The `Smb` provider is M4's.
- **No boot image built by HDT.** The ISO is S1/S3's hand-built artifact;
  `Update-HDTBootImage` is M4's, which is why the harness types one line at the
  WinPE prompt instead of `startnet.cmd` doing it.
- **No PXE** (M4).
- **WinRE is not configured by HDT** — finding 4.
- **Domain join is unproven end to end**, and cannot be: the `HDT Lab` switch is
  isolated by design and a test VM must not be moved to reach `DC01`.
- **`SetBootOrderFirst` has run in exactly one place**, the lab VM. There is no
  integration coverage for it and there cannot be, because it edits the firmware
  boot order of the machine it runs on.

## Repeating the demonstration

```powershell
# elevated, on a host with Hyper-V, the staged media and the WinPE ISO
cd C:\Users\Itamartz\Documents\GithubRepos\HDT
./build.ps1 -Task e2e

# then, by hand
Hyper-V\Get-VM -Name 'CM01','DC01' | Format-Table Name, State      # both Off
Hyper-V\Get-VM -Name 'HDT-*' | Format-Table Name, State            # nothing running
Get-ChildItem C:\HDTLab\scratch\e2e                                # PROBE.json,
                                                                   # DISK-BEFORE.json,
                                                                   # TARGET-PARTITION.json,
                                                                   # deploy-04-windows.png
```

`deploy-04-windows.png` is the artifact to open: it shows a Windows 11 screen,
not a WinPE prompt. Set `$env:HDT_KEEP_LAB_VM = '1'` to leave the VM in place
for inspection.
