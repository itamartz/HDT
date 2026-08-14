---
phase: 05-bootimage
verified: 2026-08-14
verified_by: executor
status: met_with_named_gaps
score: "ROADMAP M4's first exit clause met and demonstrated; the second clause NOT met, and refused rather than approximated"
gaps:
  - truth: "a physical or virtual machine PXE-boots the same image from WDS and deploys"
    status: not_met
    reason: >
      There is no WDS on this host. It is Windows 11 Pro; the WDS PowerShell
      module and wdsutil.exe ship with a Windows Server role, and both
      Get-Module -ListAvailable WDS and Get-Command wdsutil.exe return nothing.
      Standing one up is refused by PROJECT.md rule 3: CM01 runs a PXE responder
      on 'Default Switch', and a second responder would either break the user's
      SCCM lab or answer our test VMs and silently invalidate the test. So no WDS
      import has ever executed anywhere in this repository.
    substituted_by:
      - "Import-HDTBootImageToWds's replace-in-place semantics, including ROADMAP M4's named 'importing twice leaves one image', asserted against New-HDTFakeWdsService"
      - "the ONE fact this machine can prove, asserted against the REAL adapter: New-HDTWdsService refuses with a named HDTDependencyError"
      - "New-HDTPxePayload's staging completeness against the real ADK media tree and the real boot WIM, hash-verified file by file"
    not_claimed:
      - "that New-HDTPxePayload's output will PXE boot a machine. Complete means staged-and-verified. The BCD staged is the ADK media template, which describes booting sources\\boot.wim from removable media; a TFTP/HTTP stack generally needs its own store and its own device element."
  - truth: "a VM deploys over SMB"
    status: not_met
    reason: >
      PROJECT.md rule 2 keeps test VMs on the isolated 'HDT Lab' switch and
      SPIKES S6 records that a VM there cannot reach a share on the host. Every
      VM in this phase deployed with provider Local from a locally attached
      content disk.
    substituted_by:
      - "05-02's unit refusals: guest, anonymous, empty user and SMB1 all throw HDTSecurityError and tear the mapping down"
      - "05-02's loopback integration run against a real throwaway share"
  - truth: "WinPE needs wpeutil reboot rather than shutdown.exe (ROADMAP M2's open question, deferred to phase 05)"
    status: not_answered
    reason: >
      DEMO-M4 has no Restart step, so New-HDTPowerService still has never
      executed. The only evidence this phase produces is the payload's own
      endedWith 'wpeutil shutdown', and the payload calls wpeutil.exe directly
      rather than through the service. That is not the same thing and is not
      reported as if it were.
human_verification:
  - test: "Open C:\\HDTLab\\scratch\\e2e-m4\\m4-01-winpe.png"
    expected: "the engine already running - the two module-load lines, the machine override path, 'sequence DEMO-M4: 5 step(s)', 'running the task sequence'. NOT a bare X:\\Windows\\System32> prompt."
    why_human: "a prompt there is the failure this whole phase exists to eliminate, and no assertion reads a pixel (SPIKES S4)"
  - test: "Decide whether an isolated HDT-FS01 file server VM on 'HDT Lab' should be built in a later phase, so a VM can deploy over SMB"
    expected: "a decision, not a test"
    why_human: "it is about the shape of the user's lab, and PROJECT.md forbids the alternative"
  - test: "Decide whether an isolated HDT-WDS01 on 'HDT Lab' should be built in a later phase, so the WDS import can execute once"
    expected: "a decision, not a test"
    why_human: "same. The fake-plus-payload evidence may or may not be enough for v1"
---

# Phase 05: Boot image, ISO and PXE — Verification Report

**Phase goal.** DESIGN 5 and DESIGN 6.1: one build produces a `.wim` and a
hash-identical `.iso`, recorded by a manifest; the boot image carries the engine
and starts its own deployment; WDS serves the WIM, with a non-WDS payload for
sites that have a TFTP or HTTP stack instead; and the `Smb` content provider with
its least-privilege share model.

**Exit criterion (ROADMAP M4).** *"A VM boots the ISO unattended with no keypress,
and a physical or virtual machine PXE-boots the same image from WDS and
deploys."*

**Verified:** 2026-08-14, by the executor of 05-05, from the run it performed.
This is not an independent verification pass.

---

## Verdict

**The first clause is met and demonstrated. The second is not met, and this
report will not blur the difference** — that difference is the whole value of the
phase.

A Generation 2 VM booted an ISO `Update-HDTBootImage` produced and deployed
Windows 11 to completion **with zero keystrokes sent to it**. `RESULT.json`:

```
status Succeeded    launchedBy startnet    provider Local    sequenceId DEMO-M4
deployRoot \Share   resolvedDeployRoot C:\Share    deployRootSource Discovered
yamlBase X:\HDT\Modules\powershell-yaml    endedWith "wpeutil shutdown"
```

No WDS import has ever executed. See the gaps in the front matter.

---

## The must-haves, plan by plan

| Plan | Must-have | Status | Evidence |
|---|---|---|---|
| 05-01 | ADK assets resolved at runtime, never a literal | met | `Get-HDTAdkPath`, twelve assets, proven against this host's real ADK; a contract grep forbids a hardcoded fallback |
| 05-01 | `workspace.yaml` as the fifth document type | met | schema, validator, reader, 13 fixtures, and an AST contract comparing the schema's `required` with the validator's own list |
| 05-01 | component order and dependency validation | met | `Get-HDTBootImageComponent`, SPIKES S1's boot-verified order merged with the admin's declaration |
| 05-02 | `IContentProvider` with `Local` and `Smb` behaving identically from a step's view | met | one contract file, three implementations, and an operation-list equality test running one step through both over a shared journal |
| 05-02 | refusal to fall back to guest auth | met | four refusals before the mapping, five judgements after it; guest/anonymous/empty/SMB1 throw and tear down |
| 05-03 | the bootstrap document and the provider factory | met | eight validation rules, the secret closed over with `GetNewClosure` so it reaches neither `RESULT.json` nor a log record |
| 05-03 | `_HDTLogPath` follows the deployment | met **and corrected here** | see "the one defect" below |
| 05-04 | `Update-HDTBootImage`, seventeen steps | met | `./build.ps1 -Task integration`: a real 495 MB WIM and a real 550 MB ISO |
| 05-04 | **WIM/ISO equivalence** (DESIGN 6.1.1) | met | asserted three ways — the file on disk, `sources\boot.wim` inside the mounted ISO, and the manifest's `isoBootWimSha256` (SPIKES S11.2) |
| 05-04 | `-NoPromptForKey`, `-SkipIso`, manifest accuracy | met | SPIKES S2's staging worked first try; `-SkipIso` costs ~2 s, and DESIGN 5.1 was corrected by measurement |
| 05-05 | **a VM deploys itself with zero keystrokes** | met | SPIKES S12.1 |
| 05-05 | the zero-keystroke claim proven, not asserted | met | three independent proofs — see below |
| 05-05 | the WinPE log readable off the deployed disk | met | `W:\HDT\Logs\HDT.jsonl` on the target volume, carrying the run's `run.start` record, seq 1..44 with no gap and no repeat |
| 05-05 | importing the same image twice leaves one image | met **against a fake only** | `New-HDTFakeWdsService` is a store and does not de-duplicate, so the assertion is about the command |
| 05-05 | WDS absence stated plainly, payload demonstrated instead | met | `tests/integration/PxePayload.Integration.Tests.ps1` asserts the absence and stages 23 real files |
| 05-05 | the content volume DISCOVERED, not assumed | met | `deployRootSource Discovered`, `resolvedDeployRoot C:\Share`, candidates `C:\, X:\` |

---

## The zero-keystroke claim, and why it is a fact

Three independent proofs, because one would not be enough:

1. **The test file sends nothing, and that is checked in the fast suite.**
   `tests/unit/UnattendedDeploymentE2E.Tests.ps1` parses the E2E over the
   comment-free token stream and asserts it names no `Send-HDTLabVmText`, no
   `TypeText`, no `TypeKey` and no `Msvm_Keyboard` — four assertions with four
   messages. It also asserts the lab rules, S9.14's `MemoryStartup`, S9.15's
   recomputed skip condition, deliverable 7's relocated log, and that the E2E's
   own `deployRoot` names no drive letter. Three seconds, no Hyper-V.
2. **The guest says who started it.** `launchedBy startnet`, set by
   `set HDT_LAUNCHED_BY=startnet` inside the image's own `startnet.cmd` and by
   nothing else.
3. **A run that did not start itself could not look like success.** Nothing
   types, so a `startnet.cmd` that failed to launch the payload leaves a WinPE
   prompt and `Wait-HDTLabVmState -State Off` times out.

---

## The one defect the phase's own exit run found

**The state document was frozen by its own log relocation** (SPIKES S12.3). Both
E2E files reported `Completed, Completed, Pending, Pending, Pending` on
deployments that had succeeded and booted.

`state.json` lives in the log directory; 05-03's relocation mirrors that whole
directory onto the target volume; the writes kept going to the RAM disk, so the
mirrored copy was frozen at the moment of the move; and `Copy-HDTLog` shipped the
frozen one to the share. DESIGN 4.4.6's heartbeat was moved for exactly this
reason, ten lines earlier in the same block. Fixed with a failing test first.

**It had been unprovable for two plans.** 05-03 added the relocation; SPIKES S10
then recorded that `C:\HDTLab\media` had vanished and `-Task e2e` could not run;
05-04 added no E2E. The media was restored in 05-05 (six seconds per tree from
the Dropbox ISOs), and the first `-Task e2e` run afterwards found the defect in
both files at once.

**That is the method lesson of this phase, and it is the same one S9.14 and
S9.15 recorded:** a slow suite that has not been run through its real entry point
is not evidence. Two plans of green fast suites did not notice.

---

## What phase 05 ships without

Every item here is also in `docs/ROADMAP.md` M4 and in `05-05-SUMMARY.md`, in the
same words.

- No VM deployed over SMB in this lab, and why.
- No WDS import has ever executed, and why.
- The PXE payload is staged and hash-verified but **has never been
  network-booted**.
- No drivers (M5, deferred to v2); no applications, updates, roles or BitLocker
  (M6).
- No engine-driven reboot into an autologon resume — `DEMO-M4` has no `Restart`
  step, deliberately.
- `New-HDTPowerService` still has never executed, so ROADMAP M2's `wpeutil`
  question is still open.
- Domain join is still unproven end to end.
- DESIGN 11's technician UI is absent (M8).

---

## Lab safety across the whole phase

`CM01` and `DC01` were recorded before every run and asserted identical after, in
`AfterAll` blocks that run on failure too — both `Off` and untouched throughout
05-01 to 05-05. Every Hyper-V call is name-filtered and module-qualified; every
VM was created and removed through the helpers, whose delete is fronted by
`Assert-HDTLabVmPath` (SPIKES S9.13). Nothing in the phase touched
`Default Switch`, `HDT External` or `FSE Switch`. `C:\HDTLab\vms` was empty before
and after. This host's disk 0 was snapshotted and asserted identical across every
integration run, and `git status --porcelain` was compared across the boot image
build so a build that scattered a mount folder into the working tree would be
caught.
