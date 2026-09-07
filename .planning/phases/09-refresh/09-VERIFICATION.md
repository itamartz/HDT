---
phase: 09-refresh
verified: 2026-09-07T00:00:00Z
status: gaps_found
score: 8/8 phase-goal truths verified against FAKES; 0/4 milestone exit criteria met
re_verification: false
verifier: retrospective documentation pass (static, no suite run)
verification_method: >-
  STATIC ONLY, AND THAT IS THE FIRST THING TO KNOW ABOUT THIS DOCUMENT. The tree
  at c9893d5 was read, the git history walked, and every claim below traced to a
  file and a line. NO SUITE WAS RUN - other agents were working in the tree and
  the brief forbade it - NO MODULE WAS IMPORTED, no VM was touched and no
  hardware was involved. Where a phase-06-style verification would say "proven by
  execution", this one can only say "present and consistent". Test counts below
  are static It-block counts, not results.
gaps:
  - truth: "The exception keys on the deployment type the engine DERIVED at the start of the leg, which nothing on the disk can forge (DESIGN 3.2); a state.json claiming REFRESH on a leg derived as NEWCOMPUTER does not unlock ApplyImage (ROADMAP M9 tests-first)"
    status: failed
    reason: >-
      THE CODE DOES THE OPPOSITE, DELIBERATELY, AND NEITHER DOCUMENT WAS
      UPDATED. Invoke-HDTTaskSequence.ps1:589-591 reads $state.deploymentType -
      the state document, beside the same stepIndex the guard exists to
      disbelieve - and hands it to Test-HDTResumeStepForbidden at :653. A forged
      or corrupted document asserting REFRESH therefore DOES unlock ApplyImage on
      a resumed leg. Get-HDTResumePermittedStepType.ps1:21-52 argues the case
      honestly and well: after the reboot the machine cannot tell you what the
      run was for, SystemDrive says X: on a Refresh's second leg exactly as on a
      bare-metal first leg, and the only thing that crosses a reboot is the state
      document. It also bounds the cost - DiskPartition is refused for every
      deployment type without exception, so the worst a forged document buys is
      an image apply, never a formatted disk. The reasoning is sound. The defect
      is that DESIGN 3.2 and ROADMAP M9 still promise a guarantee the code does
      not make, and one of them is the tests-first row a verifier checks against.
      CLAUDE.md: "If you believe one is wrong, say so and update the document -
      don't quietly diverge in code."
    artifacts:
      - path: "docs/DESIGN.md"
        issue: "Lines 418-424 assert the exception keys on a derived value 'which nothing on the disk can forge'. It does not."
      - path: "docs/ROADMAP.md"
        issue: "Line 1331, tests-first row 'The exception cannot be forged'. There is no such test, and there cannot be one against this implementation."
      - path: "src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1"
        issue: "Line 589-591 reads $state.deploymentType; :653 passes it to the guard."
    missing:
      - "A decision by the user: correct DESIGN 3.2 and ROADMAP M9 to describe what was built and why, OR treat the divergence as a defect and find a signal the resumed leg can derive"
      - "Whichever way it goes, the ROADMAP tests-first row must stop asserting a test that does not exist"
  - truth: "M9 Exit: a real machine already running Windows, deployed without touching its boot media - no ISO, no PXE, no F12"
    status: failed
    reason: >-
      Not met, and not attempted. tests/e2e/Refresh.E2E.Tests.ps1 does not exist
      and appears in no commit of this phase. No machine has ever run a Refresh.
      Every M9 behaviour - the derivation, the carried type, the resume
      exception, the clean, the suspend, the three guards, the shipped template -
      is proven against hand-written fakes and nothing else. ROADMAP M9 says so
      twice in its own text ("Proven against fakes only", of the suspend and of
      the guards), so the phase did not overclaim; but nothing else in the
      repository records that the milestone is open, because until now the
      milestone had no paperwork at all.
    artifacts:
      - path: "tests/e2e/Refresh.E2E.Tests.ps1"
        issue: "Does not exist. This is the milestone exit."
    missing:
      - "A Windows 11 VM on HDT External, deployed once by HDT so it is a known-good starting state"
      - "A launcher: nothing in the product tells an administrator how to start the engine from the running OS"
      - "tests/e2e/Refresh.E2E.Tests.ps1 - start in the full OS, stage WinPE, return through it, apply, finish in the new installation"
      - "A SPIKES.md entry written from that run"
  - truth: "M9 Exit: the machine was BitLocker-encrypted before the run started, and the boot after the arm reached WinPE rather than a recovery prompt"
    status: failed
    reason: >-
      No machine, encrypted or otherwise, has run a Refresh. The ordering claim -
      the suspend ahead of both BootToWinPE steps - is asserted on the ordered
      operation list of the real template against fakes
      (tests/unit/RefreshTemplate.EndToEnd.Tests.ps1), which proves the sequence
      is authored correctly and proves nothing about BitLocker. Whether a real
      Suspend-BitLocker on a real TPM leaves the one-shot boot entry reachable is
      not a question a hand-written double can answer. This is the criterion most
      likely to fail on first contact with hardware, and the only one for which a
      green suite is actively misleading - refreshing an unencrypted machine
      would pass the transport and prove nothing at all about the suspend.
    artifacts:
      - path: "src/Hephaestus/Public/Steps/Invoke-HDTSuspendBitLockerStep.ps1"
        issue: "Never executed against a real TPM. The adapter's Suspend-BitLocker call has never run."
      - path: "src/Hephaestus/Public/New-HDTBitLockerService.ps1"
        issue: "Line 201, the Suspend method. Branch-free by rule 1's adapter exception, therefore not unit tested, therefore carrying zero evidence."
    missing:
      - "A VM with a virtual TPM, BitLocker enabled and protection ON before the run starts"
      - "Evidence that the boot after the arm reached WinPE: the WinPE leg's own log existing at all is the proof, since a recovery prompt produces none"
      - "manage-bde -status captured before the run and after it"
  - truth: "M9 Exit: the partition table is the one it started with - same layout, same identifiers, read before and after"
    status: failed
    reason: >-
      Proven structurally and only structurally. Templates/refresh.yaml contains
      no DiskPartition step (its six mentions of the word are all comments
      explaining the absence), DiskPartition is in the resume-forbidden set for
      every deployment type, and RefreshTemplate.EndToEnd.Tests.ps1 asserts no
      partition operation appears in the ordered list either leg produces against
      the fakes. That is the authored sequence and the guard both behaving. It is
      not a partition table read off a disk before and after a run, which is what
      the criterion asks for - and the reason it asks is that a Refresh that
      quietly repartitioned looks identical from the finished desktop while
      having destroyed the staged WinPE it needed to return through.
    artifacts:
      - path: "tests/e2e/Refresh.E2E.Tests.ps1"
        issue: "Does not exist, so no disk was read before or after anything."
    missing:
      - "Get-Partition / Get-Disk output captured before the run and after it, compared on layout, offsets and GUIDs"
  - truth: "M9 Exit: every leg's state document recorded a DERIVED REFRESH, the WinPE one included"
    status: failed
    reason: >-
      Proven against fakes on both legs - DeploymentTypePersistence.Tests.ps1 and
      Invoke-HDTTaskSequence.FullOsStateMirror.Tests.ps1 assert that the type is
      decided on the first leg, written to state.json, and read back unchanged by
      a WinPE leg that would otherwise have re-derived NEWCOMPUTER. No real
      state.json has ever carried the value, because no run has produced one.
      This criterion exists precisely because a leg that derived NEWCOMPUTER and
      applied the image anyway got past the guard by accident - and the
      contradiction recorded as gap 1 above makes it sharper rather than softer,
      since the guard now believes whatever that document says.
    artifacts:
      - path: "tests/e2e/Refresh.E2E.Tests.ps1"
        issue: "Does not exist, so no real state.json has been inspected."
    missing:
      - "Both legs' state.json retained from a real run and inspected for deploymentType: REFRESH"
      - "The full-OS leg's log showing source 'engine' / property 'Phase', and the WinPE leg's showing source 'state' with the carried-from-checkpoint sentence"
  - truth: "A change to Templates/ that C:\\HDTLab\\Share does not have is a change nobody here can test (CLAUDE.md rule 8 corollary)"
    status: failed
    reason: >-
      refresh.yaml is a new file in src/Hephaestus/Templates/ and the lab share
      has no copy of it. New-HDTWorkspace never overwrites an existing share, by
      design, so the share will not acquire it on its own and no boot image will
      carry it there. Until the share is spliced, the shipped Refresh sequence
      cannot be run on the only lab this project has - which is also why the
      three exit criteria above have no hardware evidence behind them. Not
      verified live: this pass was static and did not read C:\\HDTLab\\Share.
    artifacts:
      - path: "src/Hephaestus/Templates/refresh.yaml"
        issue: "New in 4f3a8c2. Nothing in the phase's commits touches the lab share."
    missing:
      - "Splice refresh.yaml into C:\\HDTLab\\Share's TaskSequences, never replace - the rest of those files are somebody's edits"
  - truth: "An administrator can start a Refresh"
    status: partial
    reason: >-
      NOT A ROADMAP CRITERION, RAISED HERE BECAUSE IT BLOCKS THE ONE THAT IS.
      The engine now derives FullOS when its system drive is not X:, and
      refresh.yaml is discovered by Get-HDTSequenceTemplate's directory walk. But
      nothing in the product says how to launch the engine from inside a running
      Windows. DESIGN documents only the WinPE entry - startnet.cmd invoking
      X:\\HDT\\Start-HDTDeployment.ps1 (DESIGN 1791, 1849-1869) - and there is no
      full-OS equivalent of MDT's \\\\share\\Scripts\\LiteTouch.vbs, no launcher
      seeded by New-HDTWorkspace, and no DESIGN section describing one. The
      capability is in the engine; the door to it is not in the product. Whoever
      writes the E2E will have to invent the launch mechanism first, and inventing
      it in a test is how it ends up existing only in a test.
    artifacts:
      - path: "docs/DESIGN.md"
        issue: "Documents the WinPE entry point only. No full-OS entry point is described anywhere."
      - path: "src/Hephaestus/Public/New-HDTWorkspace.ps1"
        issue: "Seeds no full-OS launcher into the share."
    missing:
      - "A decision on how a Refresh is started, and a DESIGN section for it"
---

# Phase 09: Refresh (M9) Verification Report

**Phase Goal:** A wipe-and-load launched from the running Windows instead of from
a boot — the machine stages a WinPE onto its own disk, reboots into it, deletes
the old installation, applies the image and comes back. MDT's `REFRESH`, and the
third caller of the `BootToWinPE` transport M7 built. It restores no user state.

**Milestone:** M9 — Refresh (`docs/ROADMAP.md`)
**Verified:** 2026-09-07, retrospectively, against the tree at `c9893d5`
**Re-verification:** No — initial, and late. M9 shipped and released as 0.23.0
before any phase paperwork existed.

**Verdict in one line: everything M9 set out to build is built, wired and
consistent — and every one of it is proven against hand-written fakes, so all
four of the milestone's exit criteria are open and one documented guarantee is
not true of the code.**

---

## What this document is, and what it is not

Every other `*-VERIFICATION.md` in `.planning/phases/` was written by a verifier
who ran the gate, imported the module, enumerated the lab and re-ran history to
check TDD. **This one was not.** It is a static reading of the tree and the git
log, produced on 2026-09-07 to give M9 the paperwork it shipped without.

So the honest form of every "VERIFIED" below is *present, wired and internally
consistent* — not *proven by execution*. Where phase 06's verifier could write
"live probe: Source=Media, Path empty", this document can write only "the call is
at `:589` and the parameter is consumed at `:653`". That is a weaker claim and it
is stated as one.

What is **not** claimed anywhere in this document: a passing suite, a lint result,
a Hyper-V lab enumeration, a TDD red-first replay, or any behaviour observed
rather than read.

---

## Goal Achievement — Observable Truths

The eight truths reconstructed in `09-01-PLAN.md`'s frontmatter, each traced to
the tree.

| # | Truth | Status | Evidence |
|---|---|---|---|
| 1 | The engine derives which leg it is on from `SystemDrive`, and no longer hard-codes WinPE | VERIFIED (static) | `Get-HDTDeploymentPhase.ps1:102-109` — empty drive throws `HDTPhaseUnknown` rather than defaulting, and the drive is a **parameter** taken from the environment adapter, so a fake can say `X:` on a laptop. `Start-HDTDeployment.ps1:456` derives it; the four `-Phase WinPE` literals ROADMAP named are gone |
| 2 | `HDTDeploymentType` is `NEWCOMPUTER` from a WinPE start and `REFRESH` from a full-OS one, and `rules.yaml` cannot set either | VERIFIED (static) | `Get-HDTVariableMap.ps1:147` carries `Writable = $false`; `Assert-HDTRuleDocument` refuses on that **column**, not on a name (the pattern M7 established), so the row is the change |
| 3 | The type is decided on the run's FIRST leg and carried in `state.json`, never re-derived | VERIFIED (static) | `Get-HDTDeploymentType.ps1` is the single mapping, called by both `Get-HDTMachineFact` and `New-HDTRunState` so the bag and the document cannot disagree. `Get-HDTMachineFact.ps1:565-583` takes the carried value when present and records source `state` with a sentence naming the deciding leg; derives with source `engine` / property `Phase` when absent. `schemas/state.schema.json:55-61` carries the optional enum |
| 4 | A resumed leg may run `ApplyImage` on a `REFRESH` and nothing else; `DiskPartition` is refused under both | VERIFIED (static), **with gap 1** | `Get-HDTResumePermittedStepType.ps1:96` maps `REFRESH → @('ApplyImage')` and returns an empty set for an absent, empty or unknown type at `:91`/`:98`. `DiskPartition` never appears in the table. The guard keeps its position **ahead of** the already-completed check (`Invoke-HDTTaskSequence.ps1:653`), which is the ordering that makes it a guard. **But the value it reads comes from `state.json` — see gap 1** |
| 5 | `CleanVolume` empties the OS volume, preserves a declared SET, and FAILS where MDT warns | VERIFIED (static) | `Get-HDTCleanVolumePreservedName.ps1` returns `HDT`, `System Volume Information` and `$Recycle.Bin`, **each with the reason it is exempt on the row**, which is what lets a test enumerate the set instead of naming `HDT\`. `Invoke-HDTCleanVolumeStep.ps1:313` writes `step.fail` on a refused delete — the divergence from `LTIApply.wsf:1297-1299`, which the file's own header cites at `:63` |
| 6 | `SuspendBitLocker` suspends before either `BootToWinPE`, defaults `rebootCount` to `0`, and runs only in the full OS | VERIFIED (static) | `Invoke-HDTSuspendBitLockerStep.ps1:158` defaults `'0'`; `:162` and `:167` refuse a non-numeric or negative count with the reason in the message. `refresh.yaml:278` places it ahead of both `BootToWinPE` steps at `:287` and `:295`. `New-HDTBitLockerService.ps1:201` is the fifth operation and is branch-free |
| 7 | Three `Validate` checks are scoped `REFRESH` and two disk checks `NEWCOMPUTER`, from one table with a `Scope` column | VERIFIED (static), **and larger than described** | `Get-HDTValidateCheckDefinition.ps1` — eleven rows, every one carrying `Scope`: `imageVersion` (:148), `imageSizeMB` (:158), `allowOtherPartition` (:168) are `REFRESH`; two target-disk rows (:92, :122) are `NEWCOMPUTER`; six are `Any`. **Five rows changed behaviour, not three** |
| 8 | `Templates/refresh.yaml` exists, carries no `DiskPartition` step, and EXECUTES end to end against fakes on both legs | VERIFIED (static) | The file's six mentions of `DiskPartition` (`:52, :72, :104, :123, :124, :234`) are **all comments**, and `:52` states the absence is the design. `RefreshTemplate.EndToEnd.Tests.ps1:283` and `:381` run it through `Invoke-HDTTaskSequence` on the full-OS leg and the resumed WinPE leg — not parse, not schema-check, **execute**. That is the `client.yaml` failure CLAUDE.md records, closed |

---

## Key Link Verification

| From | To | Via | Status |
|---|---|---|---|
| `Start-HDTDeployment.ps1` | `Get-HDTDeploymentPhase` | `SystemDrive` off the environment adapter | WIRED (:456) |
| `Get-HDTMachineFact.ps1` | `Get-HDTDeploymentType` | taken only when the state document carried nothing | WIRED (:572) |
| `New-HDTRunState.ps1` | `Get-HDTDeploymentType` | the same mapping, stamped on the document that crosses the reboot | WIRED |
| `Invoke-HDTTaskSequence.ps1` | `Test-HDTResumeStepForbidden` | `-DeploymentType`, read once above the loop with a property-existence check | WIRED (:589, :653) |
| `Test-HDTResumeStepForbidden.ps1` | `Get-HDTResumePermittedStepType` | the permitted set, negated | WIRED (:85) |
| `Assert-HDTRuleDocument.ps1` | `Get-HDTVariableMap` | the `Writable` column | WIRED |
| `Invoke-HDTValidateStep.ps1` | `Get-HDTValidateCheckDefinition` | the `Scope` column | WIRED |
| `Get-HDTConsoleValidateCheck.ps1` | the same table | the scope projected into the editor row | WIRED |
| `Get-HDTSequenceTemplate.ps1` | `Templates/refresh.yaml` | a directory walk for `*.yaml`, so nothing names the file | WIRED (:76-86) |

**The property-existence check at `:589` is the detail worth keeping.** Under
`Set-StrictMode -Version Latest`, reading `deploymentType` off a document written
by an older engine is a terminating error. The check makes the absence safe, and
`Get-HDTResumePermittedStepType` makes it *conservative*: an older document loses
a permission rather than gaining one.

---

## Hard-Rule Compliance

Read from the tree; **not** confirmed by running the contract suites.

| Rule | Status | Evidence |
|---|---|---|
| **1. TDD** | UNPROVEN | Tests ship in the same commit as their implementation, which is the repository's normal shape and consistent with TDD. **It is not evidence of it.** The red-first replay phase 06's verifier ran was never done for M9 and is not done here. See below |
| **2. PS 5.1 syntax** | PRESUMED | `PowerShell51Compatibility.Contract` walks the whole of `src/`, so it covers the new files. Not run |
| **3. `Verb-HDTNoun`** | PASS (static) | `Get-HDTDeploymentPhase`, `Get-HDTDeploymentType`, `Get-HDTResumePermittedStepType`, `Invoke-HDTCleanVolumeStep`, `Invoke-HDTSuspendBitLockerStep`, `Assert-HDTCleanVolumeTarget`, `Get-HDTCleanVolumePreservedName` — approved verbs, uppercase HDT, singular nouns |
| **4. Zero MDT dependencies** | PASS (static) | MDT appears throughout as cited prior art — `LTIApply.wsf`, `ZTIValidate.wsf`, `ZTIDisableBDEProtectors.wsf`, `Client.xml` — in comments only. No module, drive, assembly or script is loaded |
| **5. No direct hardware access** | PASS (static) | `CleanVolume` deletes through `IFileSystem`; `SuspendBitLocker` suspends through `IBitLockerService`; the `Suspend-BitLocker` call is inside the adapter at `New-HDTBitLockerService.ps1:206`, which is the one place rule 5 permits it |
| **6. `SupportsShouldProcess`** | PASS (static) | `Invoke-HDTCleanVolumeStep` is the phase's one destructive addition; `Assert-HDTCleanVolumeTarget` exists so it refuses an ambiguous volume instead of guessing |
| **7. StrictMode + `$ErrorActionPreference`** | PASS (static) | Present in every new file checked, and the `:589` existence check exists **because** of it |
| **8. Every surface** | PASS (static) | Manifest (both step commands and `Get-HDTDeploymentPhase` exported), `Get-HDTConsoleStepCatalog` (:189, :199), `Get-HDTStepPropertyDefinition` (:266, :276), three step contract suites, `Write-HDTLog`'s closed vocabulary, `docs/command-categories.psd1` and the regenerated `command-reference.html`. `refresh.yaml` needed no registration — `Get-HDTSequenceTemplate` walks the directory, which is rule 8 working as intended |

### On TDD, said plainly

Every one of the eight commits contains its tests. Not one adds a `src/` file
without a corresponding test file in the same commit. **That is the shape TDD
produces and also the shape a diligent test-after produces**, and this pass has
no way to tell them apart — the check that could (restore the test at
`<commit>~1` in a scratch worktree and watch it fail) requires running Pester,
which the brief excluded.

Static counts of the phase's own eight test files, `It` blocks:

```
Get-HDTDeploymentPhase.Tests.ps1                    12
DeploymentTypePersistence.Tests.ps1                 12
Invoke-HDTCleanVolumeStep.Tests.ps1                 29
Invoke-HDTSuspendBitLockerStep.Tests.ps1            24
Invoke-HDTValidateStep.Refresh.Tests.ps1            29
RefreshTemplate.EndToEnd.Tests.ps1                  26
Invoke-HDTTaskSequence.FullOsStateMirror.Tests.ps1  10
Get-HDTConsoleValidateCheck.Tests.ps1               13
                                                   ---
                                                    155
```

Zero `-Skip` and zero `Set-ItResult` across all eight — no test in this phase
hides a gap behind a skip.

---

## Anti-Pattern Scan

| Pattern | Result |
|---|---|
| TODO / FIXME / XXX / HACK in phase files | none found |
| Skipped tests hiding a gap | none — zero `-Skip`, zero `Set-ItResult` in the eight new files |
| A test that names the one new thing instead of the set | not found; the guard table, the preserved names and the check scopes are all asserted over sets |
| Template parsed and schema-checked but never planned | **closed** — `RefreshTemplate.EndToEnd.Tests.ps1` executes it on both legs |
| Unproven "unchanged" claims | none made |
| **A documented guarantee the code does not make** | **FOUND — gap 1.** This is the scan's one hit, and it is the important one |

**A name collision worth recording so nobody counts it twice.**
`tests/unit/ConsoleEditorRefresh.Tests.ps1`,
`tests/unit/ConsoleMonitorRefresh.Tests.ps1` and
`tests/unit/Get-HDTConsoleMonitorRefresh.Tests.ps1` match a search for "Refresh"
and are **not** M9. They are about refreshing a console view and predate this
phase. M9's console file is `Get-HDTConsoleValidateCheck.Tests.ps1`.

---

## Hyper-V Lab Safety

**Not enumerated.** This pass ran no Hyper-V command, read no VM and touched
nothing on the host — which is the only claim it is entitled to make.

What can be said from the diff: **the phase's eight commits contain no VM code,
no e2e test and no integration test**, so there is nothing in M9 that could have
created, modified or removed a virtual machine. `build.ps1 test` runs neither
suite by design.

That is also the shape of the problem. The M9 exit criteria all require a VM, and
M9 built none of the harness for one.

---

## Requirements Coverage

| Requirement (ROADMAP M9) | Status | Note |
|---|---|---|
| `HDTDeploymentType` becomes derived and stops being writable | SATISFIED (fakes) | The map row is the change; refusal is by column |
| A full-OS entry point | SATISFIED (fakes) | `Get-HDTDeploymentPhase`; but see the launcher gap — the engine can derive `FullOS`, and nothing tells an admin how to get it there |
| No `DiskPartition` in the Refresh sequence | SATISFIED (fakes) | Absent from `refresh.yaml`; still forbidden on a resumed leg for every type |
| A clean-the-volume step type | SATISFIED (fakes) | `CleanVolume`, with the preserved set as a set |
| It fails where MDT warns | SATISFIED (fakes) | `step.fail` on a refused delete, asserted by a test |
| `ApplyImage` permitted on a resumed leg of a `REFRESH`, and only there | SATISFIED (fakes) | Four cases hold |
| …and the exception cannot be forged | **NOT SATISFIED** | **Gap 1.** The code reads the state document; DESIGN and ROADMAP say it does not |
| `Suspend` on `IBitLockerService`, and the step that calls it | SATISFIED (fakes) | Fifth operation, branch-free; step is `runIn: FullOS`, `rebootCount` defaults to `0` |
| Refresh-only validation — three guards | SATISFIED (fakes) | Plus a `Scope` column that re-scoped two existing checks |
| `BootToWinPE` reused unchanged | SATISFIED | No M9 commit touches `Invoke-HDTBootToWinPEStep`, `Get-HDTLocalWinPePlan` or `Get-HDTBcdCommand` |
| No confirmation screen | SATISFIED | None added, deliberately, as ROADMAP records |
| **Exit: a real machine refreshed without touching its boot media** | **NOT MET** | Not attempted |
| **Exit: encrypted before the run; the boot after the arm reached WinPE** | **NOT MET** | Not attempted |
| **Exit: the partition table is identical before and after** | **NOT MET** | Structural evidence only |
| **Exit: every leg's `state.json` carries a DERIVED `REFRESH`** | **NOT MET** | Fakes only |

---

## Gaps Summary

**Seven, structured in the frontmatter above. Two of them matter now.**

### 1. A documented guarantee the code does not make

This is the finding. DESIGN §3.2 and ROADMAP M9 both promise that the
`ApplyImage` exception keys on a value **derived on the resumed leg**, which
nothing on the disk can forge. The shipped guard reads `$state.deploymentType` —
the state document it exists to disbelieve. The divergence is deliberate, argued
at length in `Get-HDTResumePermittedStepType.ps1:21-52`, and the argument is
convincing: after the reboot the machine genuinely cannot tell you what the run
was for, and the cost is bounded because `DiskPartition` is refused for every
type without exception, so the worst a forged document buys is an image apply
rather than a formatted disk.

**The code is probably right. The documents are certainly wrong.** CLAUDE.md's
rule is that a document believed wrong gets *updated*, not diverged from. Two
have been left standing, and one of them is a tests-first row — the exact place a
verifier looks to decide whether a milestone is done.

Not corrected here: this was a documentation pass and rewriting DESIGN §3.2 is a
design edit nobody has been asked for. **It needs a decision.**

### 2. All four exit criteria are open, and the E2E does not exist

`tests/e2e/Refresh.E2E.Tests.ps1` appears in no commit. No machine has run a
Refresh, encrypted or otherwise. The three checks ROADMAP attaches to the exit —
the encrypted boot reaching WinPE, the partition table unchanged, every leg's
`state.json` carrying a derived `REFRESH` — exist precisely because each is a way
the run can look green and be wrong, and a fake can produce a green for all
three.

**The phase did not overclaim this.** ROADMAP M9 writes "Proven against fakes
only" twice in its own text, of the suspend and of the guards. What was missing
until now is anywhere outside ROADMAP that records the milestone as open — which
is what this document is for.

### What would close them

| Criterion | The evidence that closes it |
|---|---|
| Refreshed with no boot media | A Windows 11 VM on `HDT External`, deployed by HDT first so the starting state is known, then refreshed with no ISO attached, no PXE and no F12. The absence of boot media is half the claim: the VM's DVD drive empty and its boot order recorded |
| Encrypted, and the boot reached WinPE | BitLocker on with a virtual TPM and `manage-bde -status` showing protection **On** before the run. Afterwards: the WinPE leg's own log **existing** is the proof — a machine that landed in recovery writes none — plus `manage-bde -status` from before and after |
| Partition table identical | `Get-Disk` and `Get-Partition` captured before the run and after it, compared on layout, offsets and partition GUIDs. Not "no partition step ran"; the table itself |
| Every leg derived `REFRESH` | Both legs' `state.json` retained, each carrying `deploymentType: REFRESH`; the full-OS leg's log showing provenance source `engine` / property `Phase`, and the WinPE leg's showing source `state` with the carried-from-checkpoint sentence. A WinPE leg showing `engine` would mean it re-derived, and would have called the run a `NEWCOMPUTER` |

**And two things have to happen before any of that can be attempted**, which is
why they are gaps in their own right:

- **How a Refresh is started has to be decided and designed.** The engine derives
  `FullOS`; nothing in the product opens that door. Whoever writes the E2E will
  otherwise invent a launch mechanism inside a test, which is how it ends up
  existing only there.
- **`C:\HDTLab\Share` has to carry `refresh.yaml`** — spliced, never replaced.
  The next deployment runs the share's copy.

---

## Recommendation

**Accept the phase against its stated goal: M9's code is built, wired,
set-tested and internally consistent, and the two hardest details in it — the
type that must not be re-derived, and the preserved set that must not be an
example — were both got right.**

**Do not mark M9 complete.** All four exit criteria are open and none has been
attempted.

**Two things want a decision before anything else in M9 moves:**

1. **Gap 1.** Either correct DESIGN §3.2 and ROADMAP M9 to describe the guard
   that was built and why no better signal exists, or treat the divergence as a
   defect. Whichever way it goes, the ROADMAP tests-first row must stop asserting
   a test that cannot exist.
2. **How a Refresh is launched**, because the E2E cannot be written until it is
   answered.

**And this verification should be re-run properly** — gate executed, module
imported, TDD replayed at `<commit>~1`, lab enumerated — the way every other
phase's was. Nothing here is contradicted by that; it is simply weaker evidence
than this project's standard, and it says so rather than dressing itself up.

---

_Verified: 2026-09-07, retrospectively, against `c9893d5`_
_Verifier: Claude — static documentation pass_
_Suites run by the verifier: **none**. No module imported, no VM touched, no hardware involved._
