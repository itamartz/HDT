---
phase: 06-offline-media
plan: 03
subsystem: engine / logging
tags: [media, logging, copy-back, roadmap]
requires: ["06-01", "06-02"]
provides:
  - "Get-HDTLogDestination answers Source 'Media' with an empty Path and a Skipped destination"
  - "both legs say at Info why the copy-back did not happen"
  - "the failure screen degrades to the machine's own log path instead of a blank row"
affects:
  - src/Hephaestus/Public/Get-HDTLogDestination.ps1
  - src/Hephaestus/Payload/Start-HDTDeployment.ps1
  - src/Hephaestus/Payload/Start-HDTResume.ps1
tech-stack:
  added: []
  patterns:
    - "one gate inside the command both callers already use, never two gates at two call sites"
    - "a positive test (-eq 'MEDIA') so an absent value keeps the old behaviour"
key-files:
  created:
    - tests/unit/MediaLogCopyBack.Tests.ps1
  modified:
    - src/Hephaestus/Public/Get-HDTLogDestination.ps1
    - src/Hephaestus/Payload/Start-HDTDeployment.ps1
    - src/Hephaestus/Payload/Start-HDTResume.ps1
    - tests/unit/Get-HDTLogDestination.Tests.ps1
    - tests/unit/DeploymentMethodPublication.Tests.ps1
    - tests/contract/GeneratedDocument.Contract.Tests.ps1
    - docs/ROADMAP.md
decisions:
  - "the media check sits AFTER the HDTSLShare branch, so an admin naming a log share still wins"
  - "-eq 'MEDIA' and not -ne 'UNC', so every state.json written before this behaves as before"
  - "Skipped is on all four return shapes, empty on three, because StrictMode"
  - "the skip is Info, not Warning: nothing failed, and an admin needs it to understand the run"
  - "the failure screen falls back to the local log path, which this phase would otherwise have blanked"
metrics:
  duration: "~35 min"
  completed: 2026-09-03
---

# Phase 06 Plan 03: The Log Copy-Back Under Media Summary

Under `HDTDeploymentMethod = MEDIA` the end-of-run copy-back to
`<deployRoot>\Logs` no longer happens — network or not — and both legs say so at
`Info`, naming the destination they skipped and the method that skipped it.

## What was built

**One gate, inside `Get-HDTLogDestination`.** Both legs already call it — the
WinPE leg at `Start-HDTDeployment.ps1:~1463`, the full-OS leg at
`Start-HDTResume.ps1:~722` — so gating inside the command is one change that
covers both, where gating at the two call sites would have been two changes that
can drift. `Start-HDTResume.ps1`'s own comment already said why it uses that
command: *"A second answer to 'where do logs go' is a second place for them to be
missing from."*

It answers a fourth shape: `Source = 'Media'`, an empty `Path`, and `Skipped`
carrying the destination a share deployment would have used. `Skipped` is on all
four return shapes and empty on three, because a property that exists on one
branch is what makes `Set-StrictMode -Version Latest` throw in a caller three
files away.

The check is **`-eq 'MEDIA'` and not `-ne 'UNC'`**. Every `state.json` and every
hand-assembled bag predating phase 06 has no `HDTDeploymentMethod` at all, and a
negative test would have turned each of them into a silent skip.

**The sentence, on both legs.** Neither leg needed logic to stop copying — the
gate empties the path for them. What they needed was the line, because without
it the log ends on *"no log destination was resolved"*: true, reads like a
failure to resolve one, and sends the reader hunting a share that is working
perfectly well. It is `Info` rather than `Warning` because nothing failed, and
`Info` is where an administrator sees it without re-running anything.

The WinPE leg checks the method **first** in the `$logTarget` chain — under
MEDIA the path is empty by design, so an empty-path clause ahead of it would
have printed the symptom instead of the reason.

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 1 - Bug] The failure screen's Log row went blank under MEDIA.**

- **Found during:** Task 2, and the plan predicted it ("a regression this phase
  would introduce, and it is in scope because this phase causes it").
- **Issue:** both legs passed the copy-back destination alone to
  `Get-HDTDeploymentFailure -LogPath`. That is empty under MEDIA, so a media
  deployment that failed showed a technician a blank Log row — on the very
  machine whose local log is the whole point of behaviour 3.
- **Fix:** both legs fall back to the local path when the copy-back destination
  is empty: `$result['logPath']` on the WinPE leg (declared in the result
  document, filled before a single step runs, refreshed at the tail) and
  `$logRoot` on the full-OS leg (set before anything can throw).
- **Commit:** `60ad03d`

**2. [Rule 1 - Bug] The tail repeated the resolution warning under MEDIA.**

- **Found during:** Task 2. The plan called the tail's copy-back "already
  guarded on non-empty — ships nothing — correct, no edit needed", which is true
  of the *copy* and not of its `else` branch, which said *"no log destination was
  resolved"* whenever there was none.
- **Fix:** an `elseif` on `Media` at the tail, carrying a new
  `$result['logDestinationSkipped']` — needed because the tail runs **outside**
  the big `try`, where `$logTarget` may never have been assigned. `RESULT.json`
  now carries the skipped destination too.
- **Commit:** `60ad03d`

**3. [Rule 1 - Bug] A phase record that names a generator was collected as a
generated document.**

- **Found during:** Task 3's gate — two failures in
  `tests/contract/GeneratedDocument.Contract.Tests.ps1`.
- **Issue:** a document is discovered as generated by a line containing
  `generat` near a `tools\*.ps1` path. `06-02-SUMMARY.md:244` says *"regenerated
  with `tools/New-HDTCommandReference.ps1`, never hand-edited"* — the same
  sentence a generated page carries. It was then failed for stating `0.16.1`
  after this phase bumped the manifest to `0.16.2`.
- **Why it was latent:** **it passed its own gate and failed the next one.** A
  SUMMARY is committed *after* the gate that approves it, so `git ls-files`
  cannot see it while it is being written. Every summary that ever named a
  generator carried this.
- **Fix:** `.planning/` is skipped, the same class as the existing `tools/` and
  `.ps1` exclusions — prose *about* a generator is not a generator's output.
- **Commit:** `46c1c13`

**4. [Rule 1 - Bug] A 06-02 contract test read this phase's gate as a second
derivation.**

- **Found during:** Task 3's gate. `DeploymentMethodPublication.Tests.ps1`'s
  *"compares against MEDIA only on the one derived value"* flagged
  `[string] $logTarget.Source -eq 'Media'`.
- **Issue:** the test's intent is right — a second place that works out UNC vs
  MEDIA for itself is an answer that can disagree. But this is the opposite of
  that: the gate lives inside `Get-HDTLogDestination`, and the payload reads
  **that one verdict**. The string is spelled the same; the fact is a different
  one.
- **Fix:** the allowed set now names the verdict and its carried copy
  (`$result['logDestinationSource']`, which the tail needs), and still refuses
  anything else.
- **Commit:** `46c1c13`

## Task 3A — the leave-alone evidence

ROADMAP carry-over 2 stays a warning, not a task, and its test had to be green
when media arrived. Run on 2026-09-02, Windows PowerShell 5.1:

```
  [+] leaves a local root alone, because a drive letter moves 96ms
Tests Passed: 18, Failed: 0, Skipped: 0
```

And the diff across the **whole phase** (`3003650~1..HEAD`), which is the claim
that matters:

```
$ git diff --stat 3003650~1..HEAD -- src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1 \
                                     src/Hephaestus/Public/Resolve-HDTDeployRoot.ps1
(no output)
$ git diff --stat 3003650~1..HEAD -- src/Hephaestus/Private/Get-HDTMachineFact.ps1
(no output)
```

Zero lines in all three. `Invoke-HDTTaskSequence.ps1:~999` — the
`$resolvedRoot.StartsWith('\\')` guard — is untouched, and so is the
`<osvolume>\HDT\Logs` copy in its restart path, which
`MediaLogCopyBack.Tests.ps1` now guards by AST: *"is reached by no code path this
phase added a method check to"* asserts that the enclosing statement mentions
neither `HDTDeploymentMethod` nor `$deploymentMethod` nor `'Media'`.

## Task 3B — against the real module, not the fakes

`Import-Module ./src/Hephaestus/Hephaestus.psd1 -Force`, Windows PowerShell 5.1:

```
Local  -> MEDIA
Smb    -> UNC

HDTName             MdtName          Writable Origin
-------             -------          -------- ------
HDTDeploymentType   DeploymentType       True engine
HDTDeploymentMethod DeploymentMethod    False engine
HDTDeploymentStart                       True engine
HDTDeploymentEnd                         True engine
```

The refusal, against real YAML through `Import-HDTRuleDocument` rather than a
hand-built hashtable (probe written to `$env:TEMP`, deleted by explicit
`-LiteralPath`):

```
REFUSED: ...\hdt-06-03-probe.yaml: rule 1 ('Wrong'): 'HDTDeploymentMethod'
cannot be set by a rule. It is a fact about how this machine booted, published
by the engine from the boot image's own provider - not a preference. A share
that declares MEDIA gets a deployment that skips the network it is actually
using, and every symptom of that points somewhere else. Run Get-HDTVariableMap
to see which variables a rule may set.
```

And this plan's own four answers, from the real command:

| `-WorkspaceRoot` | `-Variable` | `Path` | `Source` | `Skipped` |
|---|---|---|---|---|
| `D:\Deploy` | `HDTDeploymentMethod = MEDIA` | *(empty)* | `Media` | `D:\Deploy\Logs` |
| `\\srv\HDTShare$` | `HDTDeploymentMethod = UNC` | `\\srv\HDTShare$\Logs` | `DeployRoot` | *(empty)* |
| `\\srv\HDTShare$` | *(none — every old state.json)* | `\\srv\HDTShare$\Logs` | `DeployRoot` | *(empty)* |
| `D:\Deploy` | `MEDIA` + `HDTSLShare` | `\\logs-01\HDTLogs` | `HDTSLShare` | *(empty)* |

## Task 3D — the gap, stated plainly

**This phase was proven entirely against hand-written fakes and ASTs. No VM
booted from a disc, no ISO was built, no USB stick was written, and
`New-HDTMedia` does not exist.**

Every assertion here is unit-level. The two payloads are scripts, so running them
for real means a booted machine to power off — which is what `tests/e2e` is —
and their assertions are therefore read off the parsed source: that the Media
clause comes first, that it says `Skipped` and `MEDIA` through `$say`, that it
carries no severity argument, that the `<osvolume>\HDT\Logs` copy has no method
check in it. Those prove the *shape* of the code. They do not prove a disc.

That is what the phase asked for, and saying so is the same discipline
`.planning/PROJECT.md` applies to `JoinDomain` having no live DC.

**The ROADMAP's "Exit — media" criterion — a USB stick built from the share
deploys a machine with no network — is NOT met and the ROADMAP now says so.**
`New-HDTMedia`, the content projection and the ISO/USB layouts remain deferred,
and nothing here was stubbed towards them. What this phase did is narrower and
worth naming exactly: **it made the engine ready for media by teaching it which
method it is running under.**

## Verification

Full gate, Windows PowerShell 5.1 only, 2026-09-03 00:03:54. The pwsh 7 pass was
deliberately not run.

```
version: 0.16.2 unchanged (unchanged, 612 file(s))
lint: 0 diagnostics across 1113 file(s)
test: 13534 passed, 0 failed, 268 skipped
selfcheck: 4 of 4 checks passed
BUILD SUCCEEDED (clean, version, bundle, build, lint, test, selfcheck)
  on PowerShell 5.1.26100.8655
```

The first run of that gate was **red — 13531 passed, 3 failed** — and both
causes are written up as deviations 3 and 4 above. Neither was a defect in what
this plan built; one was latent in the contract suite and one was a 06-02 test
reading this phase's single gate as a second derivation.

## Commits

| Commit | What |
|---|---|
| `bb28689` | `Get-HDTLogDestination` refuses the deploy root under MEDIA |
| `60ad03d` | both legs say why; failure screens keep a usable log path |
| `46c1c13` | the two gate fixes, and the ROADMAP |

## Self-Check: PASSED

All three artefacts exist on disk and all three commits resolve in `git log`.
`Get-HDTLogDestination.ps1` names `HDTDeploymentMethod` (5 occurrences, the
must_haves key link) and `Start-HDTDeployment.ps1` names `Skipped` (6).
