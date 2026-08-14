---
phase: 05-bootimage
plan: 05
subsystem: bootimage
tags: [e2e, wds, pxe, winpe, hyper-v, lab-safety, milestone, unattended]
requires: ["05-01", "05-02", "05-03", "05-04"]
provides:
  - "ROADMAP M4's exit criterion as an executable test: a VM that deploys itself"
  - "Import-HDTBootImageToWds, replace-in-place, asserted against a fake"
  - "New-HDTPxePayload, staged and hash-verified against the real ADK"
  - "New-HDTWdsService and New-HDTFakeWdsService"
  - "DEMO-M4"
  - "the AST proof, in the fast suite, that the M4 E2E sends no keyboard input"
affects:
  - "src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1"
  - "tests/helpers/HDTFakes/HDTFakes.psm1"
  - "tests/e2e/README.md"
  - "tests/helpers/README.md"
  - "docs/ROADMAP.md"
  - ".planning/SPIKES.md"
tech-stack:
  added: []
  patterns:
    - "a slow suite's own claim about itself, asserted by AST in the fast suite"
    - "one declared table, read by both the command and the test"
    - "a fake that is a STORE, so 'one image, not two' is provable"
    - "the corrupt copy, stated rather than arranged (SeedHash)"
key-files:
  created:
    - "src/Hephaestus/Public/New-HDTWdsService.ps1"
    - "src/Hephaestus/Public/Import-HDTBootImageToWds.ps1"
    - "src/Hephaestus/Public/New-HDTPxePayload.ps1"
    - "src/Hephaestus/Private/Get-HDTPxePayloadRow.ps1"
    - "tests/unit/New-HDTFakeWdsService.Tests.ps1"
    - "tests/unit/Import-HDTBootImageToWds.Tests.ps1"
    - "tests/unit/New-HDTPxePayload.Tests.ps1"
    - "tests/unit/UnattendedDeploymentE2E.Tests.ps1"
    - "tests/integration/PxePayload.Integration.Tests.ps1"
    - "tests/e2e/UnattendedDeployment.E2E.Tests.ps1"
    - "samples/workspace/TaskSequences/DEMO-M4/sequence.yaml"
    - "samples/workspace/TaskSequences/DEMO-M4/unattend.xml"
  modified:
    - "src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1"
    - "src/Hephaestus/Hephaestus.psd1"
    - "tests/helpers/HDTFakes/HDTFakes.psm1"
    - "tests/helpers/HDTFakes/HDTFakes.psd1"
    - "tests/helpers/HDTTestTools/tools/Send-HDTLabVmText.ps1"
    - "tests/unit/FakeJournal.Tests.ps1"
    - "tests/unit/Invoke-HDTTaskSequence.LogRelocation.Tests.ps1"
    - "tests/e2e/README.md"
    - "tests/helpers/README.md"
    - "docs/ROADMAP.md"
    - ".planning/SPIKES.md"
decisions:
  - "the state document moves with the log at relocation - a frozen copy is worse than none"
  - "IWdsService gets no contract row, and the helpers README says why in full"
  - "New-HDTPxePayload's Complete means staged-and-verified, never bootable"
  - "the per-machine override carries HDTTaskSequenceID: nothing types one at this machine"
  - "the staged media was restored from the Dropbox ISOs, closing SPIKES S10"
metrics:
  tasks: 3
  duration: "one session"
  completed: 2026-08-14
---

# Phase 5 Plan 5: The M4 Exit Criterion Summary

**A Generation 2 VM booted an ISO this repository built and deployed Windows 11
to completion with zero keystrokes sent to it**, and the claim is proven three
ways rather than asserted once.

---

## The demonstration

`./build.ps1 -Task e2e`, elevated. `tests/e2e/UnattendedDeployment.E2E.Tests.ps1`
built a boot image with `Update-HDTBootImage`, created `HDT-M4-Deploy` on the
isolated `HDT Lab` switch, booted it from the ISO that build produced, **and then
did nothing to it at all**.

`RESULT.json`, read off the content disk after the machine powered itself off:

```
status Succeeded      launchedBy startnet       provider Local
deployRoot \Share     resolvedDeployRoot C:\Share    deployRootSource Discovered
sequenceId DEMO-M4    computerName HDT-M4-01
yamlVersion 0.4.12    yamlBase X:\HDT\Modules\powershell-yaml
engineVersion 0.1.0   psVersion 5.1.26100.1
elapsedSecond 105     endedWith "wpeutil shutdown"   logPath W:\HDT\Logs
```

`LAUNCHER.log`, verbatim, from inside the VM:

```
03:12:37  powershell-yaml 0.4.12 loaded from X:\HDT\Modules\powershell-yaml
03:12:37  Hephaestus 0.1.0 loaded from X:\HDT\Modules\Hephaestus
03:12:37  PowerShell 5.1.26100.1; launched by 'startnet'
03:12:37  bootstrap: workspace 'HDT-LAB-M4', provider Local, deployRoot '\Share', marker 'rules.yaml'
03:12:38  deploy root 'C:\Share' (Discovered); the volumes considered were: C:\, X:\
03:12:38  machine override: C:\Share\Control\machines\351B53DB-...-6A5BA69610DC.yaml
03:12:38  sequence 'DEMO-M4': 5 step(s)
03:12:38  HDTComputerName resolved to 'HDT-M4-01'
03:12:38  running the task sequence
03:14:21  sequence finished: Succeeded
```

### Timings, beside SPIKES S9.12's

| Leg | M3 (S9.12) | M4 (S12) |
|---|---|---|
| Boot image built by HDT | — (hand-built spike artifact) | **134 s** |
| Content disk staged | 12–14 s | **11 s**, and it no longer carries the engine |
| WinPE boot → five steps → shutdown | 273 s wall, engine reported 100 s | **248 s wall, engine reported 105 s** |
| First Windows boot to a settled heartbeat | 265 s | **319 s** |
| Whole `-Task e2e` (three files, two deployments) | — | **1561 s** |

Two `-Task e2e` runs: the first found the defect below, the second — with the
fixed engine staged into a freshly built boot image — is **93 passed, 0 failed,
BUILD SUCCEEDED**.

**The M4 leg is 25 s faster than the M3 one a harness started by hand.** The
machine begins deploying the moment `wpeinit` returns rather than after a harness
slept 150 s and typed.

### Why zero keystrokes is a fact and not a claim

1. **The test file sends nothing, checked in the *fast* suite.**
   `tests/unit/UnattendedDeploymentE2E.Tests.ps1` parses the E2E and asserts,
   over the comment-free token stream, that it names no `Send-HDTLabVmText`, no
   `TypeText`, no `TypeKey` and no `Msvm_Keyboard` — four assertions with four
   messages. Three seconds, no Hyper-V, every commit.
2. **The guest says who started it.** `launchedBy` is `startnet`, set by
   `set HDT_LAUNCHED_BY=startnet` inside the image's own `startnet.cmd` and by
   nothing else.
3. **A run that did not start itself could not look like success.** Nothing
   types, so a `startnet.cmd` that failed to launch the payload leaves a WinPE
   prompt and `Wait-HDTLabVmState -State Off` times out.

And `m4-01-winpe.png` at t+150 s shows the engine already running — the two
module-load lines, the machine override path, `sequence 'DEMO-M4': 5 step(s)`,
`running the task sequence` — rather than a bare `X:\Windows\System32>` prompt.

---

## What the fakes had been wrong about

The most valuable section of 04-04, and this plan's is short but expensive.

### 1. The state document was frozen by its own log relocation

**Both E2E files found it in the same run**, and it had been unprovable for two
plans. Each reported

```
Expected @('Completed','Completed','Completed','Completed','Completed'),
but got  @('Completed','Completed','Pending','Pending','Pending')
```

on a deployment that had **succeeded**, booted into Windows and come up with the
right computer name.

The chain: `state.json` lives in the log directory by default; 05-03's relocation
**mirrors that whole directory** onto the target volume; the writes kept going to
the RAM disk, so the copy on the target was frozen at the moment of the move; and
`Copy-HDTLog` then shipped **the frozen one** to the share. So the state document
a technician reads off the deployment share said three steps were `Pending` on a
run that had finished.

DESIGN 4.4.6's heartbeat was moved for exactly this reason, in exactly this
place, ten lines earlier. 05-03's stated reason for not moving the state document
— "moving the primary would make the mirror the only copy on a machine that has
not rebooted yet" — is wrong on its own terms: after the move there are **two**
copies on the target volume, and the copy on `X:` dies at the reboot regardless.

**A stale state document is worse than an absent one, because it is believed.**

Fixed with a failing test first: a state path under the **old** log root is
rebased onto the new one; a caller who supplied `-StatePath`, or who put it
outside the log directory, is not overruled.

**Why the fakes were green about it:** the unit relocation tests asserted the
mirror at `W:\HDT\state.json` (which the loop *does* keep current) and that the
primary still existed. Nobody asserted the file the copy-back actually ships. The
new test does, and it fails on the old code with `Running`/`Pending` rather than
`Succeeded`.

### 2. The screenshot call is not reliable, and one that asserted would have been red

`GetVirtualSystemThumbnailImage` returned `32775` for two of the four M4 captures
and one of the M3 ones. The two a human is asked to look at survived, so nothing
was lost — but SPIKES S4's rule that screenshots are diagnosis and never
assertion now has a measured reason behind it rather than a stylistic one.

### 3. `Sort-Object` returns a scalar, and `[0]` on a string is a character

In the AST test, `(@($x) | Sort-Object -Property Length -Descending)[0]` on a
one-element input yielded `'B'` — the first character of `'BeforeAll {'` — and
the assertion that "the BeforeAll recomputes its skip condition" was checking a
single letter. Helpers README F12's rule, in a new costume: assign first, wrap
second, and pin a floor the coercion cannot fabricate.

### 4. `-BeLike` is literal across a help-text line wrap

The integration test asserts that `New-HDTPxePayload`'s source still carries the
sentence "has never been network-booted". The first version of that sentence wrapped
across two comment lines, so the literal wildcard did not match. That is the
assertion working, not failing — the property it guards is a *sentence*, and a
sentence broken in half is one somebody can delete half of.

### 5. A prose comment can break the check a human is asked to run

The plan's verification asks a human to `Select-String` the E2E for
`Send-HDTLabVmText`, `TypeText`, `TypeKey` and `Msvm_Keyboard` and expect nothing
back. The E2E's own header discussed all four — so the simplest check anybody can
perform reported four hits on a file that was perfectly correct.

The AST assertions were right to scan the **comment-free** token stream: a raw
scan would teach the next author to delete the sentence rather than keep the
property. But a verification step that cries wolf is one nobody runs twice. The
resolution: the seven names (four keyboard, three switches) live in the file
whose job is to name them, the E2E's header points at that file, and two new
assertions over the **raw** text keep the arrangement true — both watched failing
on a planted `# TypeText and Default Switch` line before it was removed.

### 6. `Export-ModuleMember` in `HDTFakes.psm1` is a second export list

Adding `New-HDTFakeWdsService` to `HDTFakes.psd1` was not enough; the `.psm1`
ends with its own explicit `Export-ModuleMember -Function @(...)`. The function
was defined, the manifest declared it, and it was still not importable. Two lists
that must agree, and nothing asserts that they do.

---

## What M4 ships without

Stated in plain sentences, because the value of this phase is the difference
between "proven" and "written".

- **No VM deployed over SMB in this lab.** `PROJECT.md` rule 2 keeps test VMs on
  the isolated `HDT Lab` switch, and SPIKES S6 records that a VM there cannot
  reach a share on the host. The image therefore declares `provider: Local` and a
  **volume-relative** `deployRoot`. The `Smb` provider's evidence is 05-02's unit
  refusals plus its loopback integration run. Moving a test VM to `HDT External`
  or `Default Switch` to close this gap is refused: it would put the machine on a
  segment where `CM01`'s PXE responder can answer it.
- **No WDS import has ever executed, anywhere in this repository.** This host is
  Windows 11 Pro; `Get-Module -ListAvailable WDS` and `Get-Command wdsutil.exe`
  both return nothing, and standing WDS up beside `CM01`'s PXE responder is
  refused by `PROJECT.md` rule 3. `Import-HDTBootImageToWds`'s replace-in-place
  semantics — including ROADMAP M4's named test, "importing the same boot image
  twice leaves one image" — are asserted against `New-HDTFakeWdsService`. The one
  thing this machine can prove is proven against the **real** adapter:
  `New-HDTWdsService` refuses with a named `HDTDependencyError` naming the module
  and the role. **The second clause of M4's written exit criterion is not met.**
- **The PXE payload is staged and hash-verified but has never been
  network-booted.** `Complete` means "every declared file is staged and its bytes
  verify" and not "a machine will PXE boot from this". The `BCD` staged is the
  ADK media template, which describes booting `sources\boot.wim` from removable
  media; a TFTP/HTTP stack generally needs its own store and its own device
  element. The source file, the integration test and ROADMAP M4 all say so in
  those words, and the integration test asserts that the sentence is still there.
- **No drivers** (M5, deferred to v2) and **no applications, updates, roles or
  BitLocker** (M6).
- **No engine-driven reboot into an autologon resume.** `DEMO-M4` has no
  `Restart` step, deliberately and for `DEMO-M3`'s unexpired reason.
- **`New-HDTPowerService` still has never executed.** ROADMAP M2 asked whether
  WinPE needs `wpeutil reboot` rather than `shutdown.exe` and called it a phase
  05 question. The only evidence this phase produces is the payload's own
  `endedWith: wpeutil shutdown` — the payload calls `wpeutil.exe` directly, not
  through the service. That is not the same thing.
- **Domain join is still unproven end to end**, for `PROJECT.md`'s reason.
- **DESIGN 11's technician UI is absent.** It is M8.

---

## What was built

### Task 1 — the WDS import and the PXE payload

`Import-HDTBootImageToWds` is replace-in-place, and **the ordered journal is the
assertion**: `GetBootImage`, `RemoveBootImage`, `ImportBootImage`, in that order.
A call-count assertion cannot tell an import-before-remove from an
import-after-remove, and the first would delete the new image. It refuses a bad
`-Path` **before it builds the service**, which is what makes "the refusal called
nothing" true and stops a dependency error masking a typo.

`New-HDTFakeWdsService` is a **store, not a recorder**, and it deliberately does
not de-duplicate: a fake that quietly replaced would report green for a command
that never called `RemoveBootImage`.

`New-HDTPxePayload` stages DESIGN 6.1's list from **one declared table**
(`Get-HDTPxePayloadRow`), which `-ListRequired` hands back so the tests read the
command's own declaration rather than a second copy. Every copy is verified by
hash and a mismatch is a **failure, not a warning** — a truncated `boot.sdi` on a
TFTP server is a machine that hangs at boot with no message on the screen and no
line in any log. The fake filesystem gained `SeedHash` for exactly that case: a
corrupt copy is the one filesystem condition no amount of seeded content can
express, because `CopyItem` copies exactly.

`tests/integration/PxePayload.Integration.Tests.ps1` stages against the **real**
ADK media tree and the **real** boot WIM 05-04 built: 23 files, `boot.sdi`,
`bootmgr.exe` and `bootmgfw.efi` hash-equal to their ADK sources, the boot WIM
hash-equal to the manifest's — which ties the payload to DESIGN 6.1.1's
equivalence — and the workspace byte-identical before and after.

### Task 2 — DEMO-M4 and the AST proof

`DEMO-M4` is `DEMO-M3` **plus nothing**, and the header says why: a milestone
that also changed the sequence could not say which half of the change made the
machine deploy itself. `unattend.xml` is copied unchanged — SPIKES S7's verified
shape, proven end to end by 04-04.

`tests/unit/UnattendedDeploymentE2E.Tests.ps1` was written **first**, and watched
failing on exactly one test with the other 26 **skipped** rather than vacuously
green: a token stream from a file that does not exist is empty, and an empty
stream satisfies every "names no `TypeText`" assertion for the wrong reason
(SPIKES S9.15b).

### Task 3 — the exit criterion

`tests/e2e/UnattendedDeployment.E2E.Tests.ps1`, modelled on
`Deployment.E2E.Tests.ps1` with the keyboard deleted and the boot image replaced.
`Deployment.E2E.Tests.ps1` is **kept**, as the M3 record; it still passes.

One design point worth recording: **the per-machine override carries
`HDTTaskSequenceID` as well as `HDTComputerName`.** Nothing types a sequence id
at this machine, `bootstrap.json`'s `sequenceId` is empty, and the payload falls
through to the resolved variables — so the answer has to be somewhere the machine
can read. DESIGN 3.1's second source is the mechanism HDT already has for making
one machine an exception, and this is the second thing it has ever carried.

---

## SPIKES S10 is closed

`C:\HDTLab\media` was re-extracted from the Dropbox ISOs `PROJECT.md` names, with
`Mount-DiskImage -Access ReadOnly` and `robocopy /E` — a create-only operation
that deletes nothing. **Six seconds each.** The cause of the original loss is
still unknown and this does not pretend otherwise; what is now recorded is that
restoring it is cheap, beside a finding that stopped two plans from running
`-Task e2e` at all.

---

## Lab safety

Every Hyper-V call name-filtered and module-qualified. `CM01` and `DC01` were
recorded before each run and asserted identical after, in `AfterAll` blocks that
run on failure too — both `Off` and untouched throughout. Every VM was created
and removed through `New-`/`Remove-HDTLabVirtualMachine`, whose delete is fronted
by `Assert-HDTLabVmPath` (SPIKES S9.13). Nothing touched `Default Switch`,
`HDT External` or `FSE Switch`; `C:\HDTLab\vms` was empty before and after.

---

## How to repeat the demonstration

```powershell
cd C:\Users\Itamartz\Documents\GithubRepos\HDT

# 1. the fast suite, both engines
pwsh       -NoProfile -File ./build.ps1 -Task ci
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File ./build.ps1 -Task test

# 2. the real ADK, the real boot image, the real PXE payload (ELEVATED)
./build.ps1 -Task integration

# 3. the exit criterion (ELEVATED, ~26 minutes)
./build.ps1 -Task e2e

# 4. what the machine said about itself
Get-Content C:\HDTLab\scratch\e2e-m4\RESULT.json | ConvertFrom-Json |
    Select-Object status, launchedBy, deployRootSource, resolvedDeployRoot, endedWith

# 5. the picture that matters - the engine running, never a WinPE prompt
Invoke-Item C:\HDTLab\scratch\e2e-m4\m4-01-winpe.png

# 6. confirm the claim yourself - both return nothing, and
#    tests/unit/UnattendedDeploymentE2E.Tests.ps1 asserts that they do
Select-String -Path tests/e2e/UnattendedDeployment.E2E.Tests.ps1 `
    -Pattern 'TypeText|TypeKey|Send-HDTLabVmText|Msvm_Keyboard'
Select-String -Path tests/e2e/UnattendedDeployment.E2E.Tests.ps1 `
    -Pattern 'Default Switch|HDT External|FSE Switch'

# 7. the honest gap
Get-Module -ListAvailable WDS                                     # nothing
Get-Command wdsutil.exe -ErrorAction SilentlyContinue             # nothing
Import-Module ./src/Hephaestus/Hephaestus.psd1 -Force
try { New-HDTWdsService } catch { $_.Exception.Message }          # names the module and the role

# 8. the lab
Hyper-V\Get-VM -Name 'CM01', 'DC01' | Format-Table Name, State
Hyper-V\Get-VM -Name 'HDT-*' | Format-Table Name, State
```

Set `HDT_REUSE_BOOT_IMAGE=1` to reuse an existing build **only when its
manifest's hashes still match the artifacts on disk**; `HDT_KEEP_LAB_VM=1` to
leave the VM in place, powered off, for inspection.
