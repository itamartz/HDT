---
phase: 08-windows-update
plan: 08-01-03
subsystem: steps
tags: [windows-update, wua, multi-pass, reboot-reenter, checkpoint, step-type]
requires:
  - 08-01-02
provides:
  - Invoke-HDTWindowsUpdateStep
  - Get-HDTFullOsOnlyStepType
  - Test-HDTStepPhaseForbidden
  - Get-HDTUpdateKbNumber
  - Test-HDTUpdateExcluded
  - Select-HDTApplicableUpdate
  - Get-HDTUpdateResultName
  - "Start-HDTResume -UpdateSession"
affects:
  - src/Hephaestus/Public/Import-HDTSequenceDocument.ps1
  - src/Hephaestus/Payload/Start-HDTResume.ps1
  - src/Hephaestus/Hephaestus.psd1
  - tests/contract/StepProgress.Contract.Tests.ps1
  - tests/contract/StepVariableExpansion.Contract.Tests.ps1
  - docs/command-categories.psd1
  - docs/command-reference.html
tech-stack:
  patterns:
    - "An authoring-time refusal that walks a SET, so a type added later is refused by construction"
    - "The refusal lives in the flattener, where the INHERITED runIn exists - the validator sees the raw document"
    - "A checkpointed pass counter, so maxPasses bounds the STEP across legs rather than the leg"
    - "Every filter decision returns a REASON, so the log can say why an expected patch did not install"
key-files:
  created:
    - src/Hephaestus/Public/Steps/Invoke-HDTWindowsUpdateStep.ps1
    - src/Hephaestus/Private/Get-HDTFullOsOnlyStepType.ps1
    - src/Hephaestus/Private/Test-HDTStepPhaseForbidden.ps1
    - src/Hephaestus/Private/Get-HDTUpdateKbNumber.ps1
    - src/Hephaestus/Private/Test-HDTUpdateExcluded.ps1
    - src/Hephaestus/Private/Select-HDTApplicableUpdate.ps1
    - src/Hephaestus/Private/Get-HDTUpdateResultName.ps1
    - tests/unit/SequenceFullOsOnlyStep.Tests.ps1
    - tests/unit/UpdateFilter.Tests.ps1
    - tests/unit/Invoke-HDTWindowsUpdateStep.Tests.ps1
  modified:
    - src/Hephaestus/Public/Import-HDTSequenceDocument.ps1
    - src/Hephaestus/Payload/Start-HDTResume.ps1
    - src/Hephaestus/Hephaestus.psd1
    - tests/contract/StepProgress.Contract.Tests.ps1
    - tests/contract/StepVariableExpansion.Contract.Tests.ps1
    - tests/unit/Import-HDTSequenceDocument.Tests.ps1
    - docs/command-categories.psd1
    - docs/command-reference.html
decisions:
  - "The refusal goes in Import-HDTSequenceDocument and not the validator: only the flattener knows a step's INHERITED runIn, which is the WinPE-group case DESIGN 10.1 is about"
  - "An exclude entry is a KB number if it looks like one and a title wildcard otherwise; a bare number is NEVER a title substring, because excluding too much is invisible"
  - "StepProgress classifies WindowsUpdate QUIET, for the 'somebody else's program' shape - MEASURED: BeginInstall(null,null,null) rejects the null callback before it reads the collection, so WUA's only progress-bearing form is unavailable to a PowerShell adapter"
  - "The maxPasses line names what the LAST PASS found applicable rather than searching again; a fresh search after the last install is a further pass in all but name"
metrics:
  duration: "~2h"
  completed: 2026-09-06
---

# Phase 08 Plan 01-03: the WindowsUpdate step, and its multi-pass loop — Summary

`Invoke-HDTWindowsUpdateStep` — DESIGN 10.1's online, full-OS patching step: it
searches, installs, restarts and **searches again** until a pass finds nothing
applicable or `maxPasses` is hit, counting passes across legs through a
checkpointed variable and coming back `RebootRequested -Reenter` in between. With
it: an authoring-time refusal that walks a set, four pure decision helpers that
report a reason for every row, and the resume payload that gives the step a
service on the machine rather than only in a test.

## What the E2E in 08-01-04 needs, and it is the reason this section is first

**The two checkpoint variables**, both written into `$Context.Variable` and
therefore into `state.json`:

| Variable | Holds |
|---|---|
| `_HDTWindowsUpdatePass` | `[int]`, passes **completed** by this run, across every leg |
| `_HDTWindowsUpdateInstalled` | `[string[]]`, the KB numbers put on, across every leg, deduped |

**The exact `Data` keys the result carries**, in this order:

```
pass               [int]       the pass this leg finished on
maxPasses          [int]
server             [string]    '' when the step named none
searched           [int]       what the last search returned, unfiltered
applicable          [int]      what the filter kept in the last pass
installed          [string[]]  KB numbers, across every leg
installedThisPass  [string[]]  KB numbers, this pass only
skippedExcluded    [string[]]  the administrator's own exclude patterns ruled these out
skippedCategory    [string[]]  these were outside the categories the step named
failed             [object[]]  kb, title, resultCode, hresult, message
rebootRequired     [bool]
elapsedSecond      [long]
```

`skippedExcluded` and `skippedCategory` are deliberately two keys and never one
number, for the reason `InstallApplications` keeps its two skips apart: one says
the administrator excluded it and the other says it was never in scope, and
merging them loses the answer to "why did this machine not get that patch".

## The refusal, and why it is in the flattener

`Get-HDTFullOsOnlyStepType` is one list in one place and
`Test-HDTStepPhaseForbidden` is the decision over it, so the refusal walks a
**set** — a type added to that list next year is refused without anybody finding
`Import-HDTSequenceDocument.ps1`. The importer contains no `WindowsUpdate`
literal, and a test asserts that.

**It could not have gone in `Assert-HDTSequenceDocument`.** The validator sees
the RAW document, where a step inheriting its group's `runIn` declares none of
its own — so a refusal there would have missed

```yaml
- group: Preinstall
  runIn: WinPE
  steps:
    - name: Patch the machine
      type: WindowsUpdate      # declares no runIn at all
```

which is the case DESIGN 10.1 is actually about. The flattener is the only place
the effective `runIn` exists.

Only an explicit `WinPE` is refused. `Any`, empty and `$null` are allowed,
because `Any` is the default every sequence written before `runIn` existed
carries, and the engine already skips such a step during the WinPE leg.

`InstallRoles`, `EnableBitLocker` and `JoinDomain` are **deliberately not** in
the set, and the help says why at length: their own failures explain themselves,
and adding them would be refusal-by-list creeping outward until the set became a
policy.

## The filters, and the two readings of an exclude entry

`exclude: ["*Preview*", "KB5001234"]` is one array holding two kinds of thing,
and `Test-HDTUpdateExcluded` owns the decision: **an entry is a KB number if it
looks like one and a title wildcard otherwise.** `KB5001234`, `kb5001234` and
`5001234` are all the same article; everything else is `-like` against the title.

**A bare number is never matched against the title**, and that is the guard worth
naming. Titles are full of numbers — build numbers, years, the `11` in `Windows
11` — so reading `5001234` as a substring would let one exclusion silently remove
half a catalogue, and the log would report the exclusion working. Excluding too
much is invisible; excluding too little is not.

`Select-HDTApplicableUpdate` returns **one row per input update, never a silent
drop**: `Update`, `Applicable`, and a `Reason` of `no category filter`,
`category SecurityUpdates`, `excluded by *Preview*` or `no category matched`.
Categories compare with whitespace and hyphens removed, because WUA reports
`Security Updates` and DESIGN 10.1's YAML writes `SecurityUpdates` — and the
reason names the spelling **the author wrote**, so they can find it in their own
file.

## Deviations from Plan

### 1. [Rule 4 → decided on measurement] `StepProgress` classifies the step QUIET, not reporting

**Found during:** Task 4.
**The plan said:** "Add to `$script:HDTReportingStep`, NOT to
`$script:HDTQuietStep`", plus a `$script:HDTProgressDriveCase` entry seeded with
"ONE unit of work that takes a long time — one applicable update, one pass".

**Why that could not be done honestly.** Those two instructions contradict each
other. A drive case must clear `$script:progressFloor`, which is **ten** distinct
moving records from one long unit, and `IUpdateSessionService.InstallUpdate` is a
single blocking call. One applicable update in one pass can produce exactly one
frame. The only way to clear the floor would be to drive the step with ten fast
updates, which is precisely the dishonesty that context was written to catch —
its own header says so about `ApplyUpdates`.

**So the question became whether the interface could tick**, the way
`ApplyUnattend` and `Sysprep` do through a polled adapter. **Measured on this
laptop on 2026-09-06, with an EMPTY update collection so nothing could install:**

```
$installer.BeginInstall($null, $null, $null)
  -> "Object reference not set to an instance of an object."
     It rejects the null callback BEFORE it looks at the collection.

$installer.Install()            the same empty collection
  -> "Value does not fall within the expected range."
     It reaches the collection, which is as far as an empty one gets.
```

The two messages differ in kind, which is what makes the probe decisive: WUA's
only progress-bearing form needs an `IInstallationCompletedCallback`, PowerShell
cannot implement a COM interface, so `Install()` is the only call available to
this adapter. **That is a fact about the agent, not an omission in the step.**

**Fix:** `WindowsUpdate` is in `$script:HDTQuietStep`, under the list's SECOND
shape — somebody else's program — which is where `InstallRoles` already sits for
the same argument ("reporting would mean a new output channel on
IFeatureService"). The entry carries the measurement above verbatim, and says
plainly that the step *does* write a frame per update and that what it cannot do
is write a second one *during* an install. No drive case was added, because a
classification of quiet does not require one.
**Commit:** d6c12a8

### 2. [Rule 1 - Bug] The unknown-step-type test predicted its own failure and it came true

**Found during:** the full gate.
**Issue:** `tests/unit/Import-HDTSequenceDocument.Tests.ps1` derived its example
of "a type this engine does not implement" from `valid-design-example.yaml`, and
its own comment said: *"WindowsUpdate would rot the same way when it lands."* It
landed, it was the last unimplemented type that fixture named, and the test went
red.
**Fix:** the example is now a third party's — `ContosoBios`, shipped in a
workspace's `Modules\` — which is the case the pluggability property is actually
about and cannot rot. The fixture was **not** touched: it is DESIGN 3.3's worked
example character for character and eight other tests count its steps.
**Commit:** e77d087

### 3. [Rule 2 - Missing] `Get-HDTUpdateResultName`, which the plan did not name

**Found during:** Task 3.
**Issue:** CLAUDE.md's logging rule is "the command AND its exit code AND what
that code means", and the plan asks for "the result code AND what that code
means". Nothing existed to turn `4` into `failed`.
**Fix:** a seventh helper, written test-first like the rest. A code outside the
set is reported by number rather than as an empty string, so a log never reads
`result code 9 ()`.
**Commit:** 9acc273

### 4. [Rule 2 - Missing] An unresolved `%token%` in `server:` is refused

**Found during:** Task 3, writing the server tests.
**Issue:** `Expand-HDTVariableToken` leaves an unsupplied token LITERAL by design
(02-03), so a rule that never set `HDTWSUSServer` would have reached `SetServer`
with the text `%HDTWSUSServer%` — writing that into the `WUServer` policy value
takes a machine off Windows Update without putting it onto anything.
**Fix:** the step refuses, naming the token and both ways out. Covered by a test.
**Commit:** 9acc273

### 5. The maxPasses line does not search again to find out what is outstanding

**Found during:** Task 3 — the extra search made two pass-count assertions fail,
which is how it was noticed.
The plan's loop sketch ends "reached maxPasses (N) with updates still
applicable". Searching after the last install to discover that is **a further
pass in everything but name** — minutes against a WSUS server on a step that has
just been told to stop — and its answer would still be provisional, because
installing what it found could reveal more again. The line now reports what the
LAST PASS found applicable, and says which pass it is talking about.
**Commit:** 9acc273

### 6. [Rule 3 - Blocking] `-replace` inside a `[pscustomobject] @{}` literal does not parse

**Found during:** Task 2.
**Issue:** `Normalised = (ConvertTo-HDTComparableString -Value $text) -replace '[\s\-]', ''` inside a hashtable literal fails to parse in Windows PowerShell 5.1 — the comma is read as a hashtable separator, giving "Unexpected token ','" and "The hash literal was incomplete".
**Fix:** the whole expression is parenthesised.
**Commit:** d31be4a

### 7. The expansion probe learned to run a type with no template yet

**Found during:** Task 4.
`$script:newTemplateStep` builds a probe's starting bag from the type's own
template, and `WindowsUpdate` has none until 08-01-04. Without a fallback, adding
the three rows the plan requires would have thrown; without the rows, the
coverage guard fails. A type with no `TemplateCommand` now gets an empty starting
bag, with a comment saying why — the row supplies every key it needs through
`Key` and `Extra`, and `Get-HDTStepType`'s own help already says a missing
template is a real answer rather than an oversight.
**Commit:** d6c12a8

### 8. `docs/command-reference.html` carries another session's changes

The file was already modified in the working tree when this plan started.
Regenerating it for the new command carried that along. Nothing was reverted.

## The resume payload, which is the one that costs a deployment

`Start-HDTResume.ps1` now builds `New-HDTUpdateSessionService` and passes
`-UpdateSession` to the catalog. **The red that specified it was run first**, as
the plan asked:

```
[-] hands the catalog every service any step type can ask for
    Expected '-UpdateSession' to be found in collection @('New-HDTServiceCatalog',
    '-FileSystem', ...), because a step type calls GetRequired('UpdateSession'),
    and a catalog without it fails at the machine rather than here
```

That test regexes `GetRequired` out of every step FILE rather than out of the
shipped templates, which is why it could see a step type no shipped sequence
uses. Proven afterwards by parsing rather than by trusting the regex:

```
parse errors: 0
New-HDTUpdateSessionService CommandAst count: 1
catalog carries -UpdateSession: True
```

## Verification

Real output, Windows PowerShell 5.1 only (the gate; the pwsh pass is off):

```
./build.ps1 test  ->  14315 passed, 9 failed, 296 skipped   (502 files, 8 workers)
./build.ps1 lint  ->  0 diagnostics across 1172 files       (separate process)
```

**The 9 failures are exactly the permitted set**, and every one of them needs a
TEMPLATE, which plan 08-01-04 owns:

| Failing | Count |
|---|---|
| `the step contract … names exactly the step files under Public/Steps` | 1 |
| `the step template contract …` | 7 |
| `Get-HDTConsoleStepCatalog … offers all of them and invents none` | 1 |

Nothing belonging to this plan is red: the resume payload, `StepProgress`,
`StepVariableExpansion`, `LogEventVocabulary`, `PayloadExportedCommand`,
`CommandReference` and the importer's own suite are all green.

Per-file, and the RED runs recorded before each implementation:

```
tests/unit/SequenceFullOsOnlyStep.Tests.ps1
  RED     2 passed, 18 failed   (CommandNotFound; the 2 were the "accepts" guards)
  GREEN   with Import-HDTSequenceDocument.Tests.ps1: 62 passed, 0 failed

tests/unit/UpdateFilter.Tests.ps1
  RED     0 passed, 26 failed   (every one CommandNotFound)
  RED     26 passed, 2 failed   (Get-HDTUpdateResultName, added later)
  GREEN   28 passed, 0 failed

tests/unit/Invoke-HDTWindowsUpdateStep.Tests.ps1
  RED     0 passed, 46 failed   (every one CommandNotFound)
  GREEN   with UpdateFilter: 74 passed, 0 failed

tests/unit/StartHDTResumePayload.Tests.ps1
  RED     83 passed, 1 failed   (the set test, naming UpdateSession)
  GREEN   with PayloadExportedCommand.Contract: 87 passed, 0 failed

tests/contract/StepProgress + LogEventVocabulary   ->  110 passed, 0 failed
tests/contract/StepVariableExpansion               ->   38 passed, 0 failed
tests/contract/StepContract                        ->  275 passed, 1 failed (08-01-04)
```

And the module itself, imported and run rather than only faked:

```
Get-HDTStepType -Name WindowsUpdate

Type            : WindowsUpdate
InvokeCommand   : Invoke-HDTWindowsUpdateStep
TemplateCommand :
CanAdd          : False
```

`CanAdd = False` is the done criterion, not a defect: the type runs in an
existing sequence and no authoring surface offers it until 08-01-04 writes the
template.

## Nothing was searched, downloaded or installed

The only Windows Update Agent calls this plan made for real were the two probes
in deviation 1, both against an **empty** update collection, and both of which
threw. No search ran, no update was downloaded and nothing was installed. The
step's every behavioural assertion runs against
`New-HDTFakeUpdateSessionService`.

## What plan 08-01-04 inherits

- The nine reds above, all closed by writing `Get-HDTWindowsUpdateStepTemplate`
  and adding the type to `StepContract`'s hand-written list.
- The `Data` keys and the two checkpoint variable names at the top of this file,
  which its E2E asserts on out of `state.json`.
- The `StepProgress` classification decided here on a measurement — if 08-01-04's
  E2E finds the bar genuinely motionless for fifteen minutes, the answer is not
  to reclassify the step but to record the measurement in `.planning/SPIKES.md`,
  because the interface cannot carry a tick.

## Self-Check: PASSED

Every file claimed above exists on disk, every commit hash resolves, and the
plan's four `key_links` are present in the files it named:

```
FOUND  src/Hephaestus/Public/Steps/Invoke-HDTWindowsUpdateStep.ps1   (663 lines, min_lines 250)
FOUND  src/Hephaestus/Private/Get-HDTFullOsOnlyStepType.ps1
FOUND  src/Hephaestus/Private/Test-HDTStepPhaseForbidden.ps1
FOUND  src/Hephaestus/Private/Get-HDTUpdateKbNumber.ps1
FOUND  src/Hephaestus/Private/Test-HDTUpdateExcluded.ps1
FOUND  src/Hephaestus/Private/Select-HDTApplicableUpdate.ps1
FOUND  src/Hephaestus/Private/Get-HDTUpdateResultName.ps1
FOUND  tests/unit/SequenceFullOsOnlyStep.Tests.ps1
FOUND  tests/unit/UpdateFilter.Tests.ps1
FOUND  tests/unit/Invoke-HDTWindowsUpdateStep.Tests.ps1

FOUND  7a15faa  feat(08-01-03): refuse a full-OS-only step in a WinPE group, by walking a set
FOUND  d31be4a  feat(08-01-03): the update filters, as pure logic that reports a reason for every row
FOUND  9acc273  feat(08-01-03): the WindowsUpdate step, and the multi-pass loop that is the point
FOUND  d6c12a8  feat(08-01-03): the three set-based surfaces the new step type turns red
FOUND  e77d087  fix(08-01-03): the two surfaces the new export turned red, and neither is deferred

key_links   GetRequired('UpdateSession'          in the step            1
            Test-HDTStepPhaseForbidden           in the importer        2
            RebootRequested -Reenter             in the step            1
            New-HDTUpdateSessionService          in Start-HDTResume.ps1 1
```
