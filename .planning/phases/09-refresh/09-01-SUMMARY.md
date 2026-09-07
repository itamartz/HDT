---
phase: 09-refresh
plan: 09-01
subsystem: deployment-type
retrospective: true
tags: [refresh, deployment-type, bitlocker, clean-volume, validate, resume-guard, template]
requires:
  - 08-windows-update
provides:
  - Get-HDTDeploymentPhase
  - Get-HDTDeploymentType
  - Get-HDTResumePermittedStepType
  - Invoke-HDTCleanVolumeStep
  - Invoke-HDTSuspendBitLockerStep
  - "Templates/refresh.yaml"
  - "IBitLockerService.Suspend"
  - "Get-HDTValidateCheckDefinition Scope column"
affects:
  - src/Hephaestus/Payload/Start-HDTDeployment.ps1
  - src/Hephaestus/Public/Get-HDTMachineFact.ps1
  - src/Hephaestus/Public/Get-HDTVariableMap.ps1
  - src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1
  - src/Hephaestus/Public/New-HDTRunState.ps1
  - src/Hephaestus/Public/New-HDTBitLockerService.ps1
  - src/Hephaestus/Public/Write-HDTLog.ps1
  - src/Hephaestus/Public/Steps/Invoke-HDTValidateStep.ps1
  - src/Hephaestus/Private/Assert-HDTRuleDocument.ps1
  - src/Hephaestus/UI/Console/HDTSequenceEditor.xaml
  - schemas/state.schema.json
  - docs/DESIGN.md
  - docs/ROADMAP.md
tech-stack:
  added:
    - "Suspend-BitLocker (BitLocker module) behind the existing IBitLockerService adapter"
  patterns:
    - "One mapping in one private function, because two callers publish the same answer into two documents"
    - "A Scope column on the check table, so the table that declares the checks also says who runs them"
    - "The deployment type is decided on the run's FIRST leg and carried; the phase is re-derived on every leg"
    - "An absent value unlocks nothing - an older state document loses a permission rather than gaining one"
key-files:
  created:
    - src/Hephaestus/Public/Get-HDTDeploymentPhase.ps1
    - src/Hephaestus/Private/Get-HDTDeploymentType.ps1
    - src/Hephaestus/Private/Get-HDTResumePermittedStepType.ps1
    - src/Hephaestus/Private/Assert-HDTCleanVolumeTarget.ps1
    - src/Hephaestus/Private/Get-HDTCleanVolumePreservedName.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTCleanVolumeStep.ps1
    - src/Hephaestus/Public/Steps/Get-HDTCleanVolumeStepTemplate.ps1
    - src/Hephaestus/Public/Steps/Get-HDTCleanVolumeStepDescription.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTSuspendBitLockerStep.ps1
    - src/Hephaestus/Public/Steps/Get-HDTSuspendBitLockerStepTemplate.ps1
    - src/Hephaestus/Public/Steps/Get-HDTSuspendBitLockerStepDescription.ps1
    - src/Hephaestus/Templates/refresh.yaml
    - tests/unit/Get-HDTDeploymentPhase.Tests.ps1
    - tests/unit/DeploymentTypePersistence.Tests.ps1
    - tests/unit/Invoke-HDTCleanVolumeStep.Tests.ps1
    - tests/unit/Invoke-HDTSuspendBitLockerStep.Tests.ps1
    - tests/unit/Invoke-HDTValidateStep.Refresh.Tests.ps1
    - tests/unit/RefreshTemplate.EndToEnd.Tests.ps1
    - tests/unit/Invoke-HDTTaskSequence.FullOsStateMirror.Tests.ps1
    - tests/unit/Get-HDTConsoleValidateCheck.Tests.ps1
    - tests/fixtures/cim/Win32_OperatingSystem.json
  modified:
    - src/Hephaestus/Payload/Start-HDTDeployment.ps1
    - src/Hephaestus/Private/Test-HDTResumeStepForbidden.ps1
    - src/Hephaestus/Private/Assert-HDTRunStateDocument.ps1
    - src/Hephaestus/Private/Get-HDTValidateCheckDefinition.ps1
    - src/Hephaestus/Private/Get-HDTConsoleStepCatalog.ps1
    - src/Hephaestus/Private/Get-HDTStepPropertyDefinition.ps1
    - src/Hephaestus/Private/Get-HDTConsoleValidateCheck.ps1
    - src/Hephaestus/Public/Get-HDTMachineFact.ps1
    - src/Hephaestus/Public/Get-HDTVariableMap.ps1
    - src/Hephaestus/Public/Get-HDTResumeCandidate.ps1
    - src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1
    - src/Hephaestus/Public/New-HDTRunState.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTGatherStep.ps1
    - src/Hephaestus/Hephaestus.psd1
    - schemas/state.schema.json
    - tests/helpers/HDTFakes/HDTFakes.psm1
decisions:
  - "The resume exception keys on state.json's deploymentType, NOT on a value derived on the resumed leg - and DESIGN 3.2 and ROADMAP M9 still say the opposite. See Contradictions below; this is the phase's single most important open item"
  - "The deployment type is read ONCE above the step loop rather than per step, because it cannot change while the loop runs and a per-step read would invite somebody to make it changeable"
  - "CleanVolume deletes rather than formats, because the run's own state is on the volume it is emptying"
  - "CleanVolume FAILS a refused delete where MDT logs a warning and continues"
  - "SuspendBitLocker rebootCount defaults to 0 - until explicitly resumed - because a Refresh reboots more than once"
  - "No confirmation screen before a Refresh, deliberately: MDT has none either"
  - "refresh.yaml needs no registration - Get-HDTSequenceTemplate walks the Templates directory"
metrics:
  duration: "~14 hours elapsed across two sittings on 2026-09-06"
  completed: 2026-09-06
  merged: 2026-09-07
---

# Phase 09 Plan 01: Refresh — Summary

**Retrospective.** M9 was built and merged without a plan file; this summary was
written afterwards from the tree and the git history, on 2026-09-07. It records
what shipped. It is not a report an executor wrote while executing, and nothing
in it should be read as one.

A wipe-and-load launched from the running Windows. Eight commits on
`feat/refresh`, merged at `33ca8bc` and released as 0.23.0 (`d86158a`).

## What actually shipped

| Commit | What |
|---|---|
| `0ab8009` `484126f` | DESIGN §3.2 and ROADMAP M9 — **written before the code**, which is the one part of the GSD shape M9 did keep |
| `f663780` | `HDTDeploymentType` derived from the phase; the map row gains `Writable = $false`; `Assert-HDTRuleDocument` refuses it by column |
| `1953113` | `Get-HDTDeploymentPhase` — the full-OS entry point; the payload's four `-Phase WinPE` literals become the derived value |
| `1b0711a` | `Get-HDTDeploymentType`, `deploymentType` on the state document and in `state.schema.json`, and `Get-HDTResumePermittedStepType` — the `ApplyImage`-on-`REFRESH` exception |
| `48526ae` | `Suspend` — the fifth `IBitLockerService` operation — and the five `volume.*` log event names |
| `53f4260` | `CleanVolume`: the step, its target assertion and its preserved-name set |
| `1d9def7` | Three `REFRESH`-scoped `Validate` guards and a `Scope` column on the check table |
| `4f3a8c2` | `SuspendBitLocker`, `Templates/refresh.yaml`, and every surface both new step types had to reach |
| `dd7093a` | The console's Validate pane shows each row's scope, projected from the same table |

### The believed list, corrected

The task brief's list was right in substance. Four corrections and two additions:

1. **`Get-HDTDeploymentPhase` is public and exported; `Get-HDTDeploymentType` is
   private.** They are two functions, not one. The first answers *which leg is
   this* from `SystemDrive`; the second maps that to *what is this run*. The
   split is what lets the phase be re-derived every leg while the type is not.
2. **The `Validate` guards are three checks plus a `Scope` column, and the column
   re-scoped two existing checks as well.** `imageVersion`, `imageSizeMB` and
   `allowOtherPartition` are `Scope = 'REFRESH'`; two target-disk checks became
   `Scope = 'NEWCOMPUTER'`; the remaining six are `'Any'`. Describing M9 as "three
   new guards" undercounts it — five rows changed behaviour.
3. **The resume-guard exception is a whole private function**
   (`Get-HDTResumePermittedStepType`) plus a parameter on
   `Test-HDTResumeStepForbidden` plus a read in `Invoke-HDTTaskSequence`, not a
   condition. And it reads the **state document** — see Contradictions.
4. **`state.schema.json` gained an optional `deploymentType` enum.** The brief did
   not mention the schema, and it is the thing that carries the whole feature
   across the reboot.
5. **Five new log-event names** (`volume.clean`, `volume.delete`,
   `volume.preserve`, `volume.retry`, `volume.target`) — the vocabulary is a
   closed contract set, so `CleanVolume` could not write a line until they landed.
6. **A console change** (`dd7093a`): the sequence editor's Validate pane shows
   each check's scope, so an author can see which rows their sequence will
   actually run.

Not in M9, and worth saying because the names look like it: the
`ConsoleEditorRefresh`, `ConsoleMonitorRefresh` and `Get-HDTConsoleMonitorRefresh`
test files are about **refreshing a console view**. They predate this phase and
have nothing to do with the deployment type.

## The three pieces of reasoning worth not re-deriving

**The type is about the run; the phase is about the leg.** A Refresh starts in
the full OS and its second leg runs in WinPE. A leg that re-derived the type
would call the same run a `NEWCOMPUTER` halfway through — and it would do it at
precisely the moment the resume guard is consulted. So
`Get-HDTMachineFact` takes the carried value when there is one, derives only
when there is not, and says which it did: source `state` with a sentence naming
the leg that decided it, or source `engine` with the property `Phase`.

**An absent value unlocks nothing.** `deploymentType` is optional in the schema,
because a document written by an older engine belongs to a run that is still
going. `Get-HDTResumePermittedStepType` returns an empty set for an absent or
unknown type, so an older document *loses* a permission rather than gaining one.
`Invoke-HDTTaskSequence` reads the property with an existence check, because
under `Set-StrictMode -Version Latest` reading one that is not there is
terminating.

**`CleanVolume` deletes because the run is standing on the volume.** `state.json`,
the staged boot WIM under `<volume>\HDT\Boot` and the logs are all on the volume
being emptied — a format would take the run with it. The preserved set is `HDT`,
`System Volume Information` and `$Recycle.Bin`, each with the reason it is exempt
recorded beside it, and the tests enumerate the set rather than naming `HDT\`.

## Contradictions between the code and the documents

**One, and it is load-bearing.**

`docs/DESIGN.md:418-424` says:

> *"So the exception keys on the deployment type the engine **derived** at the
> start of the leg, from the phase it is running in, which nothing on the disk
> can forge."*

`docs/ROADMAP.md:1331` repeats it as a tests-first requirement:

> *"**The exception cannot be forged** — a `state.json` claiming `REFRESH` on a
> leg the engine derived as `NEWCOMPUTER` does not unlock `ApplyImage`."*

**The shipped code does the opposite.** `Invoke-HDTTaskSequence.ps1:589-591`
reads `$state.deploymentType` — the state document — and hands that to the guard.
A `state.json` claiming `REFRESH` on a WinPE leg **does** unlock `ApplyImage`.

The divergence is deliberate and argued at length in
`Get-HDTResumePermittedStepType.ps1:21-52`, which is the honest part:

> *"After the reboot the machine cannot tell you what the run was for. Its
> SystemDrive says `X:` on a Refresh's second leg exactly as it does on a
> bare-metal first leg … The evidence that distinguishes them was on the leg
> BEFORE this one, and the only thing that crosses a reboot is the state
> document."*

It also states the cost plainly and bounds it: `DiskPartition` is refused for
every deployment type without exception, so the worst a forged document buys is
an image apply, never a formatted disk.

**The reasoning is sound. The problem is that neither document was updated.**
CLAUDE.md is explicit — *"If you believe one is wrong, say so and update the
document — don't quietly diverge in code."* Two documents still assert a
guarantee the code does not make, and one of them is the tests-first row a
verifier would check against. Left alone, the next person to read DESIGN §3.2
will believe the exception is unforgeable.

**Not fixed here**, because this phase's paperwork is documentation-only and
correcting DESIGN and ROADMAP is a design edit the user has not been asked about.
It is carried as the first gap in `09-VERIFICATION.md`.

## What TDD looked like, and what it did not

Every implementation commit carries its tests in the same commit. That is the
repository's normal shape and is consistent with TDD, but **it is not evidence of
it** — the red-first check the phase 06 verifier ran (check the tests out against
the previous commit and watch them fail) was never run for M9, by anyone, and is
not run here either.

Static count of the phase's own test files, by `It` block — **counted, not run**:

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

Zero `-Skip` and zero `Set-ItResult` across all eight. Existing files
(`Get-HDTMachineFact`, `Assert-HDTRuleDocument`, `Get-HDTVariableMap`,
`Invoke-HDTGatherStep`, `Invoke-HDTTattooStep`, `Get-HDTResumeCandidate`,
`Invoke-HDTTaskSequence.ResumedWinPE`, `ConsoleEditorWindow`, and four contract
suites) gained more.

`RefreshTemplate.EndToEnd.Tests.ps1` is the strongest of them: it does not parse
and schema-check the shipped template, it **runs** it through
`Invoke-HDTTaskSequence` against the fakes on the full-OS leg and again on the
resumed WinPE leg, and asserts the ordered operation list. That is the
`client.yaml` failure CLAUDE.md records, closed.

## What is NOT built, and was never claimed

- **`tests/e2e/Refresh.E2E.Tests.ps1` does not exist**, and appears in no commit
  of this phase. Every M9 behaviour is proven against hand-written fakes only.
- **No documented way to launch a Refresh.** The engine now *derives* `FullOS`
  when its system drive is not `X:`, but nothing tells an administrator how to
  start it. DESIGN §12 documents only the WinPE entry —
  `startnet.cmd` → `X:\HDT\Start-HDTDeployment.ps1` — and there is no full-OS
  equivalent of MDT's `\\share\Scripts\LiteTouch.vbs`, no seeded launcher in
  `New-HDTWorkspace`'s tree, and no section in DESIGN describing one. The
  capability is in the engine; the door to it is not in the product.
- **`C:\HDTLab\Share` was not brought up to `refresh.yaml`.** CLAUDE.md rule 8's
  corollary: the next deployment runs the share's copy, not the repository's.
- **The suspend has never met a TPM.** Whether a real `Suspend-BitLocker` leaves
  the one-shot boot entry reachable is not something a hand-written double can
  answer, and ROADMAP M9 says so in as many words.

## Verification

**No suite was run for this summary.** Other agents are working in this tree and
the brief forbade it. The last recorded gate for this code is the one that
preceded the 0.23.0 release commit `d86158a`; this document does not restate a
number it did not produce.

What was verified, by reading the tree at `c9893d5`:

```
FOUND  src/Hephaestus/Public/Get-HDTDeploymentPhase.ps1
FOUND  src/Hephaestus/Private/Get-HDTDeploymentType.ps1
FOUND  src/Hephaestus/Private/Get-HDTResumePermittedStepType.ps1
FOUND  src/Hephaestus/Private/Assert-HDTCleanVolumeTarget.ps1
FOUND  src/Hephaestus/Private/Get-HDTCleanVolumePreservedName.ps1
FOUND  src/Hephaestus/Public/Steps/Invoke-HDTCleanVolumeStep.ps1
FOUND  src/Hephaestus/Public/Steps/Invoke-HDTSuspendBitLockerStep.ps1
FOUND  src/Hephaestus/Templates/refresh.yaml     (6 mentions of DiskPartition, all comments)
FOUND  schemas/state.schema.json                 deploymentType enum NEWCOMPUTER|REFRESH
FOUND  Hephaestus.psd1                           both step commands exported
FOUND  Get-HDTConsoleStepCatalog.ps1:189,199     both types, Category 'Disks'
FOUND  Get-HDTStepPropertyDefinition.ps1:266,276 both types
FOUND  Get-HDTValidateCheckDefinition.ps1        Scope on all 11 rows; 3 REFRESH, 2 NEWCOMPUTER, 6 Any
FOUND  New-HDTBitLockerService.ps1:201           Suspend, branch-free
FOUND  Write-HDTLog.ps1                          volume.clean/delete/preserve/retry/target
ABSENT tests/e2e/Refresh.E2E.Tests.ps1
```

## Self-Check: PASSED

Every commit named above resolves and every file claimed exists at `c9893d5`.

```
FOUND  0ab8009  docs(M9): a Refresh is where the run STARTED, not what survived it
FOUND  f663780  feat(M9): HDTDeploymentType is derived from the phase, and no rule may set it
FOUND  484126f  docs(M9): the Refresh, written down before the code that implements it
FOUND  1953113  feat(M9): a deployment may start in the running Windows, and says which leg it is on
FOUND  1b0711a  feat(M9): the run keeps its own name across the reboot, and the WinPE leg can find it
FOUND  48526ae  feat(M9): a fifth operation on IBitLockerService, and five names for emptying a volume
FOUND  53f4260  feat(M9): CleanVolume, which empties the volume DISM would only have overlaid
FOUND  1d9def7  feat(M9): the three guards a Refresh runs, and the two disk checks it does not
FOUND  4f3a8c2  feat(M9): SuspendBitLocker, refresh.yaml, and every surface that had to learn them
FOUND  dd7093a  feat(M9): the row says which run it belongs to, in the table's own word
FOUND  33ca8bc  Merge feat/refresh: the Refresh deployment type (M9)
FOUND  d86158a  chore(release): Hephaestus 0.23.0
```
