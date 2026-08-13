---
phase: 03-sequence-engine
plan: 04
subsystem: engine
tags: [execution-loop, conditions, continue-on-error, retry, backoff, timeout, reboot-resume, teardown, checkpointing, pester, tdd, powershell-5.1]

# Dependency graph
requires:
  - phase: 03-sequence-engine
    plan: 01
    provides: the shared journal, IClock, IFileSystem, New-HDTLogContext/Write-HDTLog/Write-HDTStatus/Copy-HDTLog, New-HDTRunState/Save-HDTRunState/Import-HDTRunState
  - phase: 03-sequence-engine
    plan: 02
    provides: Import-HDTSequenceDocument's flattened steps, Test-HDTStepCondition, Get-HDTStepType, Invoke-HDTStep, Test-HDTStepApplicable, New-HDTStepResult, New-HDTExecutionContext, the five step types
  - phase: 03-sequence-engine
    plan: 03
    provides: Set-HDTAutoLogon, Clear-HDTAutoLogon, Invoke-HDTBootReconciliation, New-HDTDeploymentPassword, Get-HDTAutoLogonArtifact
provides:
  - "Invoke-HDTTaskSequence - DESIGN 4.3's execution loop: ordering, runIn, conditions, continueOnError, retry, timeout, checkpointing, the reboot ceremony and the finally teardown"
  - "Invoke-HDTStepAttempt - retry with fixed or exponential backoff taken from the injected clock, timeout measurement, failure classification"
  - "Get-HDTFailureClass - DESIGN 12.1's three classes, unwrapping to the innermost exception"
  - "Test-HDTStepRunInPhase and Get-HDTStepLogName - the phase filter and DESIGN 4.4.2's numbered per-step log name"
  - "Test-HDTTaskSequence - the authoring lint the schema cannot express"
  - "Start-HDTResume.ps1 - the RunOnce payload, reconcile before resume"
  - "New-HDTSequenceTestHarness and Get-HDTLogRecord - the assembly line and the JSONL reader every loop test leans on"
  - "The state document's per-step leg field"
affects: [03-05-headline-test, 04-imaging, 05-boot-image, 07-applications, 08-console]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A scriptblock local to a function for a repeated multi-line action (the checkpoint, the skip, the unresolved report), rather than a private function that would need its own contract"
    - "The finally block's own order: clear the step, stamp the status, checkpoint, tear down, log run.end, heartbeat, copy back - teardown before run.end so the copied log carries it and run.end is the last line"
    - "A second, seq-only checkpoint after run.end on a pending reboot, so the next leg's log numbering continues"
    - "The test harness attaches the shared journal LAST, so its own setup reads never appear in it"
    - "Several legs share one fake filesystem, so a multi-leg assertion runs over one physical log file"
    - "A fake filesystem path seeded to refuse writes, for proving a finally block survives its own checkpoint failing"

key-files:
  created:
    - src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1
    - src/Hephaestus/Public/Test-HDTTaskSequence.ps1
    - src/Hephaestus/Private/Invoke-HDTStepAttempt.ps1
    - src/Hephaestus/Private/Get-HDTFailureClass.ps1
    - src/Hephaestus/Private/Test-HDTStepRunInPhase.ps1
    - src/Hephaestus/Private/Get-HDTStepLogName.ps1
    - src/Hephaestus/Payload/Start-HDTResume.ps1
    - tests/helpers/HDTTestTools/tools/New-HDTSequenceTestHarness.ps1
    - tests/helpers/HDTTestTools/tools/Get-HDTLogRecord.ps1
    - tests/fixtures/sequences/valid-conditional-group.yaml
    - tests/fixtures/sequences/valid-continue-on-error.yaml
    - tests/fixtures/sequences/valid-reboot-legs.yaml
    - tests/unit/Invoke-HDTTaskSequence.Ordering.Tests.ps1
    - tests/unit/Invoke-HDTTaskSequence.Failure.Tests.ps1
    - tests/unit/Invoke-HDTTaskSequence.Retry.Tests.ps1
    - tests/unit/Invoke-HDTTaskSequence.Reboot.Tests.ps1
    - tests/unit/Invoke-HDTTaskSequence.Resume.Tests.ps1
    - tests/unit/Invoke-HDTTaskSequence.Teardown.Tests.ps1
    - tests/unit/Test-HDTTaskSequence.Tests.ps1
    - tests/unit/Test-HDTStepRunInPhase.Tests.ps1
    - tests/unit/Get-HDTStepLogName.Tests.ps1
    - tests/unit/Get-HDTFailureClass.Tests.ps1
    - tests/unit/StartHDTResumePayload.Tests.ps1
    - tests/unit/New-HDTSequenceTestHarness.Tests.ps1
    - tests/unit/Get-HDTLogRecord.Tests.ps1
  modified:
    - schemas/state.schema.json
    - src/Hephaestus/Hephaestus.psd1
    - src/Hephaestus/Public/New-HDTRunState.ps1
    - src/Hephaestus/Public/Update-HDTRunStateStep.ps1
    - tests/helpers/HDTFakes/HDTFakes.psm1
    - tests/helpers/HDTTestTools/HDTTestTools.psd1
    - tests/unit/New-HDTFakeFileSystem.Tests.ps1

decisions:
  - "The loop iterates from state.stepIndex, so case 1 (already Completed on a previous leg) is a CRASH-WINDOW recovery rather than the normal resume path; the resume test was rewritten to exercise it as such"
  - "step.start is logged by Invoke-HDTStepAttempt, once per attempt, not by the loop - the plan asked for both and only one placement satisfies both"
  - "The finally tears down BEFORE run.end and before copy-back, so the copied-back log carries the teardown record and run.end is genuinely the last line"
  - "state.seq is checkpointed with the variables, and once more after run.end on a pending reboot, because DESIGN 4.4.2 requires the counter to survive the reboot"
  - "The state document's per-step records gained leg, extending 03-01's document, so a resume can name the leg a step completed on"
  - "A run whose checkpoint cannot be written FAILS - a run that cannot be checkpointed cannot survive a reboot - but the teardown still runs"
  - "-StatePath defaults to state.json in the log directory (DESIGN 4.4.2's listing); Start-HDTResume.ps1 passes DESIGN 4.3's C:\\HDT\\state.json explicitly"

metrics:
  duration: ~4h
  completed: 2026-08-13
---

# Phase 03 Plan 04: The execution loop Summary

`Invoke-HDTTaskSequence` — ordering, `runIn`, conditions, `continueOnError`,
retry with backoff, `timeoutMinutes`, checkpointing either side of every step,
the reboot ceremony whose order is asserted from the operation journal, and the
`finally` teardown that disarms a machine however the run ended.

## The signature and the result

```
Invoke-HDTTaskSequence -Sequence <object> -Context <object>
                       [-State <object>]
                       [-StatePath <string>] [-MirrorStatePath <string>]
                       [-StepType <object[]>]
                       [-StatusPath <string>] [-LogDestination <string>]
                       [-AutoLogonUserName <string>] [-AutoLogonDomainName <string>]
                       [-ResumeCommand <string>]
    -> [pscustomobject] @{
           Status      Succeeded | Failed | RebootPending
           State       the state document as it stands
           Result      [object[]] one row per step the loop reached, in order
           FailedStep  the flattened step that ended the run, or $null
       }
```

`SupportsShouldProcess`. Under `-WhatIf` nothing runs and nothing is returned.

Each `Result` row carries `Index, Name, Type, Status, ExitCode, Message,
Attempt, DurationMs, TimedOut, FailureClass, Reason`. `Status` on a row is
`Completed`, `Failed`, `Skipped` or `RebootRequested`; `Reason` is the skip
reason and is `$null` for a step that ran.

`-StatePath` and `-StatusPath` default to `state.json` and `status.json` in the
log directory, which is where DESIGN 4.4.2's directory listing puts them. DESIGN
4.3 names `X:\HDT\state.json` and `C:\HDT\state.json` instead; the two sections
disagree, so every caller that cares passes the path — `Start-HDTResume.ps1`
does.

## The branch order per step

Each branch is a test, and the order is the design:

| # | Branch | Outcome |
|---|---|---|
| 1 | already `Completed` or `Skipped` on a previous leg | `step.skip`, naming the leg |
| 2 | left `Running` by an interrupted leg | `resumable: true` re-runs it; anything else **fails the run** |
| 3 | `runIn` does not match this leg's phase | `step.skip`, naming both |
| 4 | a group condition is false, outermost first | `step.skip`, naming **the group** |
| 5 | the step's own condition is false | `step.skip`, naming the condition |
| 6 | the step type says it does not apply | `step.skip` |
| 7 | — | mark `Running`, checkpoint, run it, checkpoint the outcome |

Case 2 is the one worth spelling out. A step recorded `Running` was started and
never finished. Re-running it silently would repeat half-applied work; skipping
it silently would build on work that never happened. HDT refuses, names the
step, and says what `resumable: true` would have done.

Case 1 turns out to be a **crash-window recovery**, not the normal resume path:
the loop iterates from `state.stepIndex`, so a step behind the index is never
revisited. It fires when the state on disk records a step `Completed` while
`stepIndex` still points at it — exactly what a crash between the ceremony's
first save and its second would leave. `Invoke-HDTTaskSequence.Resume.Tests.ps1`
has a `Context 'a leg that died after the checkpoint'` that rewinds `stepIndex`
by hand and proves the steps are skipped rather than re-run.

Checkpoints bracket every step: `Save-HDTRunState` when it is marked `Running`
and again when its outcome is known. The `Running` checkpoint is what makes case
2 detectable at all. Every checkpoint also copies the **live variable
dictionary** and the **log's `seq`** into the document, so a variable set in
WinPE is there for a condition in the full OS and the JSONL numbering continues
across the reboot.

## The reboot ceremony, and why saving precedes arming

On `RebootRequested`, in exactly this order:

1. mark the step `Completed`, which advances `stepIndex` past it;
2. **`Save-HDTRunState`** — the durable checkpoint;
3. take the deployment password from `state.deploymentPassword`, generating one
   with `New-HDTDeploymentPassword` on the first reboot;
4. `Set-HDTAutoLogon -RemainingLeg (1 + the Restart steps still ahead)`;
5. **`Save-HDTRunState`** again, so `autoLogon.armed` is durable;
6. `Write-HDTStatus`;
7. `IPowerService.Restart($delaySecond)`.

**Why save first.** If arming succeeds and the save then fails, the machine
reboots, autologons and resumes at the *old* index — re-running the `Restart`
step, which reboots again: an infinite loop that needs a technician and a boot
menu. If the save succeeds and arming then fails, the machine reboots and stops
at the logon screen: stuck, but safe and diagnosable. Between a loop and a stop,
choose the stop.

That ordering is asserted **from the 03-01 cross-service journal**, not inferred
from effects: `FileSystem.WriteAllText(state.json)` precedes the first
`RegistryService.SetValue`, another `WriteAllText(state.json)` follows the last
one, and both precede `PowerService.Restart`.

`RemainingLeg` is **a bound, not a prediction**. It is one for this reboot plus
one for every `Restart` step still ahead — one more `Restart` ahead means
`AutoLogonCount = 2`, two more means 3, none means 1. A `CommandLine` step
returning 3010 can add a leg nobody counted, so the number is not exact. Every
arm re-sets the count, so the bound is refreshed on each reboot and Windows'
own `AutoLogonCount` teardown stays the *third* backstop behind the `finally`
and the boot reconcile, exactly as DESIGN 4.5.2 says.

The `reboot.arm` record is written by `Set-HDTAutoLogon` (03-03) when it is
handed `-LogContext`, so it lands between the two saves rather than after the
second. One record per arm, which is what the test asserts.

## Retry, backoff and the timeout limitation

`Invoke-HDTStepAttempt` runs attempts 1 through `1 + retry.count`. The delay
before attempt *N* is `DelaySecond` for `fixed` and `DelaySecond * 2^(N-2)` for
`exponential`, taken through `IClock.Sleep`. Twenty minutes of configured
backoff is proven in **3.7 seconds**, and the whole retry file runs in that time.

**A `Configuration` failure is never retried.** `Get-HDTFailureClass` reads, in
order: a timeout is `Environment`; a `FullyQualifiedErrorId` starting
`HDTConfigurationError` is `Configuration`; after unwrapping to the innermost
exception, `System.IO.*`, `Win32Exception`, `TimeoutException` and
`UnauthorizedAccessException` are `Environment`; everything else, including a
`Failed` result with an exit code and no exception at all, is `Transient`.

The unwrap is load-bearing. Every real adapter is a `ScriptMethod` on a
`pscustomobject`, which wraps whatever it threw in `MethodInvocationException`
over `RuntimeException` (tests/helpers/README.md section 5). A classifier reading
only the outer type would call every adapter failure `Transient` and retry a
missing `install.wim` three times.

**The timeout limitation, stated plainly so phase 04 does not assume otherwise:**
`timeoutMinutes` is passed to the step — only `CommandLine` can enforce it,
through `IProcessService`, as milliseconds — **and** measured by the loop
afterwards. A step that overran becomes `Failed` with `TimedOut = $true` even
when it returned success. But **HDT does not preempt a synchronous step**: one
that hangs in-process hangs the sequence, exactly as MDT's does. Running steps in
a child runspace to make timeouts pre-emptive is a post-v1 idea, and
`ForEach-Object -Parallel` is not available to an engine that must run under
Windows PowerShell 5.1.

## What `PauseOnError` does and does not do

It is read from `state.pauseOnError`. When it is set and a step fails
terminally, the loop logs at `Error` that the run is paused, names the state
path, writes the heartbeat and **returns** with `Status = Failed` and the state
loaded and saved.

It does **not** call `Read-Host` and does not start a nested prompt. Dropping to
a live prompt is the caller's job (`Start-HDTDeployment.ps1`, phase 05): an
engine that blocked on input could not be unit tested and would hang CI. A test
asserts `Read-Host` appears nowhere under `src/`.

## The four teardown scenarios

DESIGN 4.5.2's failsafe runs from `finally` on every terminal outcome. The one
outcome that does **not** tear down is `RebootPending` — the machine has to stay
armed to come back, and four assertions in
`Invoke-HDTTaskSequence.Reboot.Tests.ps1` `Context 'no teardown while a reboot
is pending'` say so.

ROADMAP M2's four scenarios, and where each is proven:

| Scenario | File | Context |
|---|---|---|
| after a successful run | `Invoke-HDTTaskSequence.Teardown.Tests.ps1` | `after a successful run` |
| after a **failed** run | `Invoke-HDTTaskSequence.Teardown.Tests.ps1` | `after a failed run` |
| after an **abandoned** run (state present but stale) | `Invoke-HDTBootReconciliation.Tests.ps1` (03-03) | `an abandoned run` |
| after a run whose state document is **missing** | `Invoke-HDTBootReconciliation.Tests.ps1` (03-03) | `no state document` |

Each asserts `Get-HDTAutoLogonArtifact | Should -BeNullOrEmpty` — one assertion
that lists every survivor rather than nine that stop at the first.

Three more cases the `finally` has to survive, all in the same file:

- a step that **threw** rather than returning `Failed`;
- a sequence that was **unusable** (an unknown type on its only step);
- **a checkpoint that itself failed** — a fake filesystem whose `WriteAllText`
  refuses `state.json`. The run fails (a run that cannot be checkpointed cannot
  survive a reboot) and the machine is still disarmed. That is the failsafe's own
  failsafe.

A teardown that could not finish is **reported, never promoted**: the run's own
`Status` and `FailedStep` are unchanged and a Warning names the unfinished
items.

## `Start-HDTResume.ps1`

`src/Hephaestus/Payload/Start-HDTResume.ps1`. Not a module file — the loader
dot-sources `Private\` and `Public\` only — so it ships as a script, is staged to
`C:\HDT\`, and is launched by the `RunOnce` entry `Set-HDTAutoLogon` writes.

It imports the module from `-ModulePath` (default
`C:\HDT\Modules\Hephaestus`), builds the **real** adapters, calls
`Invoke-HDTBootReconciliation` **before anything else**, exits 0 when the
reconcile said `Teardown`, and otherwise rebuilds the log context from the
state's `runId` and `seq`, re-imports the sequence from
`<WorkspaceRoot>\Sequences\<sequenceId>\sequence.yaml`, and calls
`Invoke-HDTTaskSequence -State $state -StatePath C:\HDT\state.json`.

It is tested by **parsing and inspecting** it: that it exists, parses with no
error under both engines, passes the 5.1 syntax scanner, defines no unprefixed
function, takes `-ModulePath` and `-StatePath` with the documented defaults,
names no fake, and — the two that matter — that the reconcile's `CommandAst`
offset precedes the loop's and that a `Teardown` guard sits between them.
Running it for real needs a machine to reboot and belongs to phase 04's
integration layer.

## The test harness

`New-HDTSequenceTestHarness` (HDTTestTools) assembles a journal, seven fakes, a
service catalog, a log context, a run state and an execution context from one
`-Yaml`. `Get-HDTLogRecord` reads `HDT.jsonl` back out of an `IFileSystem` and
parses it, with `-Event`, `-Severity` and `-Raw`. Both have their own unit
tests.

Two properties of the harness are load-bearing:

- **The journal is attached last.** The harness reads the sequence back out of
  the fake filesystem to import it, and seeding is not an operation the code
  under test performed. So the first journal entry belongs to the loop.
- **`-FileSystem` reuses an existing fake and `-StateJson` imports a state from
  its saved TEXT.** Together they make a three-leg run share one physical
  `HDT.jsonl` and pass the state document through `Import-HDTRunState` between
  legs, which is what a real second leg does after the RAM disk it was written
  from has gone. Passing the in-memory object between legs would prove nothing
  about the document.

## Verification

| # | Item | Result |
|---|---|---|
| 1 | `pwsh -NoProfile -File ./build.ps1 -Task ci` | exit 0 — **2722 passed, 0 failed, 24 skipped**, lint 0 diagnostics across 195 files, selfcheck 4/4 |
| 2 | `powershell.exe -NoProfile -File ./build.ps1 -Task test` | exit 0 — **2640 passed, 0 failed, 106 skipped** |
| 3 | `git log --oneline` shows `test(03-04)` before every `feat(03-04)` | confirmed, three pairs in order |
| 4 | ROADMAP M2's "Tests first" bullets | conditions skipping groups (Ordering), `continueOnError` (Failure), retry/backoff (Retry), a simulated reboot resuming at the right index (Resume), an interrupted non-resumable step (Resume), teardown after success and after failure (Teardown) |
| 5 | the retry file completes in seconds | **3.74 s** against 20 minutes of configured backoff |
| 6 | `Invoke-HDTTaskSequence.ps1` names no `Read-Host`, `Start-Sleep`, `Get-Date`, or direct registry/filesystem/process call | scan returned nothing |
| 7 | `Start-HDTResume.ps1` parses under both engines and calls the reconcile before the loop | 0 parse errors under 5.1; offsets 4859 (reconcile) < 6403 (loop) |

Hand-run, three legs over one shared fake filesystem, printed and read:

```
leg 1 -> RebootPending
leg 2 -> RebootPending
leg 3 -> Succeeded

seq continuity across three legs: 30 records, first 1, last 30, contiguous True
artifacts left behind: (none)
```

## Deviations from Plan

### Auto-fixed and design-level decisions

**1. [Rule 1 — Design] `step.start` is logged by `Invoke-HDTStepAttempt`, not by the loop**

- **Found during:** Task 1, reconciling two of the plan's own requirements.
- **Issue:** the plan's pseudocode logs `step.start` in the loop before calling
  `Invoke-HDTStepAttempt`, and its Retry test list requires "one `step.start` per
  attempt". Both placements together would double the record for attempt 1.
- **Fix:** the attempt function logs it, once per attempt, carrying
  `data.attempt`. Both requirements hold.
- **Commit:** `9fbdf17`, `eac0f02`

**2. [Rule 2 — Correctness] The `finally` tears down before `run.end`**

- **Found during:** Task 1, `It 'logs run.start first and run.end last'` failed
  because `Clear-HDTAutoLogon`'s `reboot.teardown` record came after `run.end`.
- **Issue:** the plan's `finally` order puts copy-back and teardown after
  `run.end`, which means the log copied back to the share ends before the
  teardown that DESIGN 4.4.1 says is exactly what you want to read.
- **Fix:** clear the step, stamp the status, checkpoint, **tear down**, log
  `run.end`, heartbeat, copy back. The copied log carries the teardown record and
  `run.end` is genuinely the last line of the run.
- **Commit:** `9fbdf17`

**3. [Rule 2 — Correctness] `state.seq` is checkpointed, and once more after `run.end` on a pending reboot**

- **Found during:** Task 3, writing the seq-continuity assertion.
- **Issue:** nothing had ever written `state.seq`. `New-HDTRunState` set it to 0
  and no one updated it, so DESIGN 4.4.2's "seq survives reboots" was not true —
  a second leg seeded from the document would have restarted at 1. Worse, a save
  taken before `run.end` would leave the next leg one number behind and produce a
  duplicate.
- **Fix:** every checkpoint copies `$log.Seq` into the document alongside the
  variables, and a `RebootPending` run takes one final seq-only checkpoint after
  `run.end`. Asserted over one physical `HDT.jsonl` across three legs: 30 records,
  1 to 30, contiguous.
- **Commit:** `6ead144`

**4. [Rule 2 — Correctness] The state document's per-step records gained `leg`**

- **Found during:** Task 1, implementing "names the leg they completed on".
- **Issue:** 03-01's step record carried no leg, so a skip message could only say
  "an earlier leg".
- **Fix:** `leg` added to `New-HDTRunState`'s record, to `schemas/state.schema.json`
  (whose step definition is `additionalProperties: false`), and as
  `Update-HDTRunStateStep -Leg`. `Assert-HDTRunStateDocument` needed no change —
  it does not reject unknown step keys — and no existing fixture or test broke.
- **Files modified:** `src/Hephaestus/Public/New-HDTRunState.ps1`,
  `src/Hephaestus/Public/Update-HDTRunStateStep.ps1`, `schemas/state.schema.json`
- **Commit:** `9fbdf17`

**5. [Rule 3 — Test correction] The resume test's "skipped on a previous leg" moved to the crash-window case**

- **Found during:** Task 3, `It 'logs step.skip for steps completed on a previous
  leg'` found zero such records.
- **Issue:** the plan's own algorithm starts the loop at `state.stepIndex`, so
  steps completed on a previous leg are *behind* the index and are never visited.
  Case 1 of the branch order is therefore not the normal resume path.
- **Fix:** the behaviour was left as the plan specifies, and the tests were
  rewritten to assert it precisely. A new `Context 'a leg that died after the
  checkpoint'` rewinds `stepIndex` in the saved document — the exact state a crash
  between the ceremony's two saves would leave — and asserts the completed steps
  are skipped naming leg 1 and are not started a second time. The "exactly once"
  assertion moved from `step.complete` to `step.start` records, because a
  `Restart` step's completion is reported as `reboot.arm` rather than
  `step.complete`.
- **Commit:** `6ead144`

**6. [Rule 3 — Test correction] "reports a teardown failure without hiding the run failure" split in two**

- **Found during:** Task 3.
- **Issue:** the plan drove this from the failing-checkpoint fake, but a
  filesystem that refuses `state.json` fails the run at the *first* checkpoint, so
  there is no failing step to still be named.
- **Fix:** two contexts. `when the checkpoint itself fails` asserts the teardown
  ran anyway, the log says the state could not be checkpointed, and `run.end` was
  still written. `a teardown that could not finish` mocks `Clear-HDTAutoLogon` to
  report a `Failed` item and asserts `Status` is still `Failed`, `FailedStep` is
  still `Fatal`, and a Warning names the unfinished item.
- **Commit:** `6ead144`

**7. [Rule 2 — Correctness] `Copy-HDTLog` is called inside its own `try`**

- **Found during:** Task 3, writing "does not fail the run when copy-back fails".
- **Issue:** `Copy-HDTLog` is documented never to throw, and the loop relied on
  that. Nothing in a `finally` block should be allowed to replace the run's
  outcome with its own failure.
- **Fix:** guarded, with a Warning on failure. Proven by mocking `Copy-HDTLog` to
  throw.
- **Commit:** `6ead144`

**8. [Rule 3 — Blocking] Two new test helpers rather than a per-file `BeforeEach`**

- The plan forbids `New-HDTTestHarness` outside `tests/helpers` and offers
  `New-HDTSequenceTestHarness` in `HDTTestTools` with its own unit test. Taken,
  plus `Get-HDTLogRecord` for the same reason — six files were about to repeat
  the same split-and-parse. Both have their own unit tests (28 assertions).
- **Commit:** `9fbdf17`, `6ead144`

**9. [Rule 3 — Blocking] `HDTFakeFileSystem` gained `-WriteFailure`**

- "Tears down even when `Save-HDTRunState` throws" needs a filesystem where one
  path, and only one, refuses to be written. `SeedWriteFailure` /
  `-WriteFailure`, checked after the operation records, throwing
  `System.IO.IOException`. Six new assertions in
  `tests/unit/New-HDTFakeFileSystem.Tests.ps1`.
- **Commit:** `6ead144`

**10. [Rule 1 — Bug] Two analyzer findings fixed in test code**

- `PSAvoidGlobalVars`: the "discovers step types once" test captured the real
  registry in a `$global:` variable to reach it from inside a module-scoped mock.
  Replaced with a mock returning `@()` — the assertion is about the call count,
  not the run's outcome, so no captured value is needed.
- `PSReviewUnusedParameter`: a parameter used only inside a nested predicate
  scriptblock is invisible to the analyzer. Copied to a local first, with the
  reason in a comment.
- **Commit:** `9fbdf17`, `6ead144`

### Recorded as unverified

- **`Start-HDTResume.ps1` has never been executed.** It is asserted through its
  AST and its text only. Running it needs a staged module under `C:\HDT\Modules`,
  real adapters and a machine to reboot — phase 04's integration layer.
- **No real reboot has happened.** `IPowerService.Restart` is a fake in every test
  here, and `New-HDTPowerService` remains the never-executed adapter 03-02
  recorded.
- **`timeoutMinutes` has never bounded a real process.** The `CommandLine` step's
  1 800 000 ms is asserted against the fake process service.

### Carried debt

- 03-01's debt stands: DESIGN 4.4.2 documents eleven event names and the engine
  validates thirteen. 03-05's docs task must write both `reboot.teardown` and
  `message` into DESIGN 4.4.2.
- DESIGN 4.3 and DESIGN 4.4.2 disagree about where `state.json` lives
  (`X:\HDT\state.json` versus inside `_HDTLogPath`). The loop defaults to 4.4.2's
  location and every caller that cares passes `-StatePath`. 03-05's docs task
  should settle it.
- `.planning/STATE.md` does not exist in this repository, so the state-update
  step was skipped again.

## Self-Check: PASSED

All 25 files this summary claims were created exist on disk. All six commits
(`7357b3f`, `9fbdf17`, `d3495c5`, `eac0f02`, `9440a86`, `6ead144`) are reachable
from `main`. The plan's `min_lines` artifacts all clear their thresholds:
`Invoke-HDTTaskSequence.ps1` 714 (min 280), `Invoke-HDTStepAttempt.ps1` 185
(min 90), `Invoke-HDTTaskSequence.Resume.Tests.ps1` 315 (min 120). Both build
legs were run for real and their output read: pwsh 7.5.8 `ci` exit 0 with 2722
passed / 0 failed, Windows PowerShell 5.1.26100.8655 `test` exit 0 with 2640
passed / 0 failed.
