---
phase: 05-bootimage
verified: 2026-08-14T08:15:00Z
verified_by: independent verifier (not the executor)
status: gaps_found
score: 9/11 truths verified, 1 partial, 1 not met
verified_at_commit: 0feeb4e
tree_caveat: >
  HEAD moved and the working tree began changing DURING this verification. The
  fast suites, the lint run and the 5.1 integration run all executed against the
  clean tree at 0feeb4e (phase 05's end state). Commits 0d34503 and 96764e7
  landed at 07:30 and 07:34 - both documentation only (PROJECT.md, DESIGN.md,
  CLAUDE.md), no source. From 07:49 a CONCURRENT SESSION began editing
  src/Hephaestus/Public/Update-HDTBootImage.ps1, the workspace validator, two
  E2E files and their payloads, and added an untracked
  tests/contract/NoKeystroke.Contract.Tests.ps1. The pwsh 7 e2e run was already
  in flight and its M4 file, tests/e2e/UnattendedDeployment.E2E.Tests.ps1, was
  NOT among the edited files; the pwsh 7 integration run executed after those
  edits and passed anyway. Nothing in this report rests on a file that changed
  under it.
runs:
  - task: test
    engine: pwsh 7.5.8
    result: "4907 passed, 0 failed, 42 skipped, 249s - BUILD SUCCEEDED"
  - task: test
    engine: Windows PowerShell 5.1.26100.8655
    result: "4762 passed, 0 failed, 187 skipped, 265s - BUILD SUCCEEDED"
  - task: lint
    engine: pwsh 7.5.8
    result: "0 diagnostics across 344 files - BUILD SUCCEEDED"
  - task: integration
    engine: Windows PowerShell 5.1.26100.8655
    result: "138 passed, 0 failed, 0 skipped, 599s - BUILD SUCCEEDED"
  - task: integration
    engine: pwsh 7.5.8
    result: "138 passed, 0 failed, 0 skipped, 818s - BUILD SUCCEEDED"
  - task: e2e
    engine: pwsh 7.5.8
    result: "98 passed, 0 failed, 0 skipped, 1597s - BUILD SUCCEEDED"
exit_criterion:
  clause_1: met
  clause_1_evidence: >
    Re-executed here, not taken from the summary.
    tests/e2e/UnattendedDeployment.E2E.Tests.ps1 built a boot image with
    Update-HDTBootImage, booted HDT-M4-Deploy from the ISO that build produced,
    SENT IT NOTHING, and the machine deployed Windows 11 and powered itself off
    after 249s. RESULT.json read off the content disk - status Succeeded,
    launchedBy startnet, sequenceId DEMO-M4, provider Local, deployRoot '\Share'
    resolved to 'C:\Share' with deployRootSource Discovered, endedWith
    'wpeutil shutdown', computerName HDT-M4-01, elapsedSecond 109. The VM was
    then restarted with the ISO still attached and reached full Windows 11, with
    an integration-services heartbeat WinPE never reports.
  clause_2: not_met
  clause_2_reason: >
    No WDS exists on this host and no WDS import has ever executed anywhere in
    this repository. Verified independently - Get-Module -ListAvailable WDS
    returns 0 modules, Get-Command wdsutil.exe returns nothing, and the OS is
    Windows 11 Pro. New-HDTPxePayload stages and hash-verifies a payload but no
    machine has ever network-booted from it.
gaps:
  - truth: "A physical or virtual machine PXE-boots the same image from WDS and deploys"
    status: failed
    reason: >
      ROADMAP M4's second exit clause. There is no WDS role on Windows 11 Pro and
      PROJECT.md rule 3 refused standing a second PXE responder beside CM01's.
      Import-HDTBootImageToWds is proven only against New-HDTFakeWdsService; the
      real adapter's only executed row is its named HDTDependencyError refusal.
      New-HDTPxePayload's Complete means staged-and-hash-verified, not bootable -
      the BCD staged is the ADK media template, which describes removable media.
    artifacts:
      - path: "src/Hephaestus/Public/Import-HDTBootImageToWds.ps1"
        issue: "Never executed against a real WDS; replace-in-place is fake-proven only"
      - path: "src/Hephaestus/Public/New-HDTPxePayload.ps1"
        issue: "Staging completeness proven against the real ADK tree; network boot never attempted"
    missing:
      - "One execution of Import-HDTBootImageToWds against a real WDS server"
      - "One machine PXE-booting the staged payload and reaching the engine"
      - "A venue for it - a Windows Server VM on the isolated HDT Lab switch, or the MS-A2 host PROJECT.md now names"
  - truth: "A VM deploys over SMB, so the Smb content provider is proven end to end"
    status: partial
    reason: >
      Every VM in phases 04 and 05 deployed with provider Local from an attached
      content disk. The Smb provider's evidence is the shared IContentProvider
      contract with Fake, Local and Smb rows, an operation-list equality test
      that runs the same ApplyImage step through Local and Smb, unit refusals for
      guest, anonymous, empty user and SMB1, and a loopback integration run
      against a real throwaway share - but not one deployment.
    artifacts:
      - path: "src/Hephaestus/Public/New-HDTSmbContentProvider.ps1"
        issue: "Never carried a real deployment to a VM"
    missing:
      - "One VM deployment with provider Smb. PROJECT.md changed at 07:30 today to allow the HDT External switch for exactly this, which removes the blocker phase 05 recorded"
human_verification:
  - test: 'Open C:\HDTLab\scratch\e2e-m4\m4-01-winpe.png'
    expected: 'the engine already running - module-load lines, the machine override path, the line sequence DEMO-M4: 5 step(s), and running the task sequence; NOT a bare X:\Windows\System32 prompt'
    why_human: "no assertion reads a pixel (SPIKES S4)"
    verifier_note: >
      DONE by this verifier, against the image on disk - it shows exactly that,
      ending in 'running the task sequence'. The run performed here could not
      re-save it: Hyper-V returned GetVirtualSystemThumbnailImage 32775 for both
      VMs, so m4-02 and m4-03 are absent from this run. Screenshots are
      diagnosis, never assertion, so no result depends on it.
  - test: "Decide whether the SMB gap should now be closed on the HDT External switch"
    expected: "a decision, not a test"
    why_human: "PROJECT.md changed today to permit it; phase 05 was refused it"
---

# Phase 05: Boot image, ISO, WDS and the boot path - Independent Verification

**Phase goal.** `Update-HDTBootImage` and `New-HDTBootIso`, the WDS import, the
`Smb` content provider, and **the boot path itself** - `startnet.cmd` plus
`Start-HDTDeployment.ps1` - so a machine boots and deploys with nobody touching
the keyboard.

**Exit.** *"A VM boots the generated ISO and deploys to Windows with ZERO
keystrokes, and the same image PXE-boots from WDS."*

**Verified:** 2026-08-14, by re-running everything. Nothing below is taken from a
SUMMARY. Where a number appears, this verifier produced it.

---

## Verdict

**The deciding question is answered YES.** A Generation 2 VM booted an ISO that
`Update-HDTBootImage` produced in this run and deployed Windows 11 to completion
with **zero keystrokes sent to it**. The second exit clause - PXE from WDS - is
**not met and cannot be met on this host**, exactly as the phase itself states.

---

## The deciding question: does it deploy with zero keystrokes?

Three independent checks, all performed here.

**1. The E2E sends nothing.** A search of
`tests/e2e/UnattendedDeployment.E2E.Tests.ps1` for `Send-HDTLabVmText`,
`TypeText`, `TypeKey`, `Msvm_Keyboard` and `SendKeys` returns nothing but prose
in the header discussing the property. The only Hyper-V input in the whole file
is `Hyper-V\Start-VM`, followed by `Start-Sleep`, two screenshots and
`Wait-HDTLabVmState -State Off`. The two files that *do* type -
`Deployment.E2E.Tests.ps1` (M3, whose boot image predates the engine) and
`WinPeSmoke.E2E.Tests.ps1` (a probe) - are not the exit criterion and do not
touch it.

**2. The fast suite proves it without Hyper-V.**
`tests/unit/UnattendedDeploymentE2E.Tests.ps1` parses the E2E's comment-free
token stream and asserts all four names absent, with a fifth assertion over the
raw text so a plain `Select-String` also comes back empty. Those tests ran green
on both engines here.

**3. The guest says who started it.** `RESULT.json`, read off the content disk
after the machine powered itself off in this run:

```
runId run-20260814-074641   status Succeeded        launchedBy startnet
sequenceId DEMO-M4          provider Local          connected true
deployRoot \Share           resolvedDeployRoot C:\Share   deployRootSource Discovered
candidateRoot C:\, X:\      yamlBase X:\HDT\Modules\powershell-yaml
psVersion 5.1.26100.1       elapsedSecond 109       endedWith "wpeutil shutdown"
computerName HDT-M4-01
```

`HDT_LAUNCHED_BY=startnet` is set by the image's own `startnet.cmd` and by
nothing else. And because nothing types, a `startnet.cmd` that failed to launch
the payload would have left a WinPE prompt and timed out rather than passed.

**It still types nothing, and it deployed.** `exitCriteriaMet` is nevertheless
false, for the WDS clause below.

---

## Observable truths

| # | Truth | Status | Evidence produced here |
|---|---|---|---|
| 1 | One command builds a bootable WIM and a hash-identical ISO with a manifest | VERIFIED | `-Task integration` on both engines built it: WIM 495 609 562 B, ISO 551 184 384 B, manifest written |
| 2 | The WIM inside the ISO hashes identical to the standalone WIM | VERIFIED | Hashed independently, outside the suite: the WIM, `sources\boot.wim` inside the mounted ISO, `artifacts.wim.sha256` and `artifacts.isoBootWimSha256` are all `91A2716CF302D2E37849F1A80AE21C4DAA89FE3DD29AC369E4DCEBC2C8D61934` |
| 3 | `startnet.cmd` inside the image runs `wpeinit` then the payload, no BOM | VERIFIED | Mounted the built WIM read-only and printed it: five CRLF lines, first byte `0x40`, last line `powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTDeployment.ps1` |
| 4 | The image carries the engine, powershell-yaml, both payloads and a bootstrap.json | VERIFIED | Same mount: `HDT\Start-HDTDeployment.ps1`, `HDT\Modules\Hephaestus\Hephaestus.psd1`, `HDT\Modules\powershell-yaml`, and a `bootstrap.json` with a volume-relative `deployRoot` and no plaintext secret |
| 5 | The payload finds its content without being told a drive letter | VERIFIED | `deployRoot '\Share'` resolved to `C:\Share`, `deployRootSource Discovered`, candidates `C:\, X:\` |
| 6 | A VM boots the generated ISO and deploys to Windows with ZERO keystrokes | VERIFIED | 249 s WinPE leg, clean power-off, five steps Completed, no `step.fail`, then a second boot to full Windows with an Ok heartbeat |
| 7 | The WinPE-phase log survives onto the machine that was built | VERIFIED | `HDT\Logs\HDT.jsonl` read off the deployed OS volume: 44 records, seq 1 to 44 with no gap or repeat, `run.start` present, seq 1-3 are the WinPE-only lines (`loaded from X:\HDT\Modules\...`, `launched by 'startnet'`), and seq 24 is `_HDTLogPath moved from 'X:\HDT\Logs' to 'W:\HDT\Logs'`. `HDT\state.json` mirrored beside it |
| 8 | WinPE has wpeutil and no shutdown.exe, and the power service uses the right one | VERIFIED | Read out of my own mount: `shutdown.exe` **False**, `wpeutil.exe` **True**. Fresh `PROBE.json` off the smoke VM: `shutdownExe false`, `wpeutilExe true`, `powerCommand wpeutil.exe`, `powerError ""`, and the did-not-fall-back assertion green |
| 9 | Naming, no-MDT and PS5.1 contracts hold; the analyzer is clean | VERIFIED | Contract suites green on both engines; `-Task lint` 0 diagnostics across 344 files |
| 10 | The Smb provider is indistinguishable from Local to a step | PARTIAL | Contract rows for Fake, Local and Smb, the operation-list equality test and the loopback integration run all pass - but no VM has deployed over SMB |
| 11 | The same image PXE-boots from WDS and deploys | FAILED | No WDS module, no `wdsutil.exe`, Windows 11 Pro. Never executed anywhere |

**Score: 9 verified, 1 partial, 1 failed.**

---

## Suite results - all through ./build.ps1, never bare Invoke-Pester

| Task | Engine | Result |
|---|---|---|
| `test` | pwsh 7.5.8 | **4907 passed, 0 failed, 42 skipped** (249 s) |
| `test` | Windows PowerShell 5.1.26100.8655 | **4762 passed, 0 failed, 187 skipped** (265 s) |
| `lint` | pwsh 7.5.8 | **0 diagnostics across 344 files** |
| `integration` | Windows PowerShell 5.1 | **138 passed, 0 failed, 0 skipped** (599 s) |
| `integration` | pwsh 7.5.8 | **138 passed, 0 failed, 0 skipped** (818 s) |
| `e2e` | pwsh 7.5.8 | **98 passed, 0 failed, 0 skipped** (1597 s) |

`0 skipped` on both slow suites matters. Phase 04 shipped a red integration task
because a file was only ever run bare, and `Assert-HDTPesterResult` (05-06) now
fails the build on `FailedContainersCount` as well as `FailedCount`, so a build
that ran nothing cannot report success. Nothing skipped itself in either run.

**The one engine gap.** `-Task e2e` was executed here under pwsh 7 only. SPIKES
S13.7 records a 5.1 e2e run (98 passed, 1566 s) performed by the executor with
`PROBE.json` as its artifact; this verifier did not repeat it, because a second
26-minute lab run adds an hour without a new claim - the guest runs 5.1
regardless of the host engine. The 5.1 leg of the slow suites is covered here by
`-Task integration`, which builds the boot image through the same oscdimg and
DISM adapters SPIKES S13.5 fixed.

---

## Artifacts - exists, substantive, wired

Every artifact named in the six plans' `must_haves` exists and exceeds its
`min_lines`. Selected rows:

| Artifact | Lines | Status |
|---|---|---|
| `src/Hephaestus/Public/Update-HDTBootImage.ps1` | 799 | WIRED - built the image the E2E booted |
| `src/Hephaestus/Public/New-HDTBootIso.ps1` | 255 | WIRED - efisys_noprompt.bin, asserted in the manifest |
| `src/Hephaestus/Public/New-HDTBootImageService.ps1` | 343 | WIRED - the DISM and oscdimg adapter, branch-free |
| `src/Hephaestus/Payload/Start-HDTDeployment.ps1` | 573 | WIRED - launched by startnet.cmd in the lab run |
| `src/Hephaestus/Public/Set-HDTLogPath.ps1` | 167 | WIRED - truth 7 is its output |
| `src/Hephaestus/Public/Resolve-HDTDeployRoot.ps1` | 203 | WIRED - deployRootSource Discovered |
| `src/Hephaestus/Public/Get-HDTBootstrapConfiguration.ps1` | 275 | WIRED - read inside WinPE in the lab run |
| `src/Hephaestus/Public/Get-HDTAdkPath.ps1` | 271 | WIRED - every ADK asset in both slow suites |
| `src/Hephaestus/Public/Get-HDTBootImageComponent.ps1` | 231 | WIRED - the nine components asserted inside the built image |
| `src/Hephaestus/Private/Get-HDTPowerCommand.ps1` | 120 | WIRED - New-HDTPowerService powered the smoke VM off |
| `src/Hephaestus/Public/New-HDTSmbContentProvider.ps1` | 425 | PARTIAL - wired to the contract and a loopback share, never to a deployment |
| `src/Hephaestus/Public/Import-HDTBootImageToWds.ps1` | 200 | PARTIAL - wired to a fake only |
| `src/Hephaestus/Public/New-HDTPxePayload.ps1` | 298 | PARTIAL - staged and hash-verified, never booted |
| `tests/e2e/UnattendedDeployment.E2E.Tests.ps1` | 988 | WIRED - the exit criterion, executed |
| `tests/unit/UnattendedDeploymentE2E.Tests.ps1` | 397 | WIRED - the zero-keystroke AST proof, in the fast suite |

Key links spot-checked in source: `KitsRoot10` read through `IRegistryService`
with no literal ADK path; `$Context.Service.Content` reaching
`Get-HDTOperatingSystem -Content` inside `Invoke-HDTApplyImageStep`;
`Set-HDTLogPath` called from the sequence loop; `Copy-HDTLog` after the payload's
`catch`; `RemoveBootImage` before `ImportBootImage`; and `bootdata` built from a
space-free staging directory (SPIKES S2).

---

## TDD

74 commits carry a `05-0x` scope. Every implementation commit is preceded by a
`test(05-0x)` commit, and the test commits touch only `tests/` - checked with
`git show --stat` on pairs across all six plans (`24c7714`/`31e9821`,
`4ffdb93`/`019625b`, `6d4df69`/`f3c7d58`, `980736c`/`64886d4`,
`f2fa710`/`c8a452c`, `e19e907`/`7d1e6d4`). The implementation file did not exist
at the point its test landed. The three fixes in 05-05 and 05-06 follow the same
shape: failing test first, then `fix(...)`.

---

## Lab safety

`CM01` and `DC01` were present and **Off** before and after every run, asserted
inside each E2E file (module-qualified and name-filtered) and checked again by
hand afterwards. Disk 0 is `GPT|True|True` before and after. No image is left
mounted. `C:\HDTLab\vms` was empty after my e2e run removed `HDT-M3-Deploy`,
`HDT-M4-Deploy` and `HDT-M3-Smoke`.

**One caveat, and it is not phase 05's.** At the final check a VM named
`HDT-M3-Smoke` was running, created at 08:12:45 - after my e2e finished. It is
2 GB, on the isolated `HDT Lab` switch, under `C:\HDTLab\vms\`, correctly named,
and belongs to the concurrent session that has been editing
`tests/e2e/WinPeSmoke.E2E.Tests.ps1` since 07:52. It complies with every
PROJECT.md rule and it is not a stray left by this phase.

---

## Anti-patterns

No `TODO`, `FIXME`, placeholder return or empty handler was found in phase 05's
source. The honest-limitation comments - Complete means staged rather than
bootable; no Restart step, deliberately; the real WDS row is a refusal - are
documented scope statements, not stubs. Each is backed by a passing assertion
about the narrower claim.

---

## What is still not proven, stated plainly

- **No WDS import has ever run.** Gap 1.
- **No VM has deployed over SMB.** Gap 2 - and PROJECT.md changed today to permit
  the `HDT External` switch, which removes the reason it was refused.
- **The PXE payload has never network-booted.**
- **No Restart step has executed in WinPE.** Stop has, through the real adapter,
  in the smoke E2E. Restart differs only in the verb taken from the same asserted
  table, which is an argument rather than a measurement.
- **Start-HDTResume.ps1's FullOS leg has never executed.**
- **`-Task e2e` was not re-run here under 5.1** - see the engine gap above.

---

_Verified: 2026-08-14T08:15:00Z_
_Verifier: Claude (gsd-verifier), independent of the phase executor_
