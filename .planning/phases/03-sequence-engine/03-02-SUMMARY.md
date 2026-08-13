---
phase: 03-sequence-engine
plan: 02
subsystem: engine
tags: [sequence, yaml, json-schema, step-contract, discovery, dependency-injection, pester, tdd, powershell-5.1]

# Dependency graph
requires:
  - phase: 01-foundations
    provides: the module skeleton, New-HDTErrorRecord, Test-HDTSchemaVersion, ConvertFrom-HDTYaml, the naming/5.1/MDT contract tests, the pscustomobject adapter shape
  - phase: 02-rules
    provides: Expand-HDTVariableToken, ConvertTo-HDTComparableString, Assert/Import-HDTRuleDocument as the shape to mirror, the six service fakes
  - phase: 03-sequence-engine
    plan: 01
    provides: the shared journal, IClock, New-HDTFileSystem, New-HDTLogContext/Write-HDTLog, New-HDTRunState
provides:
  - "The closed step condition grammar: ConvertFrom-HDTStepCondition and Test-HDTStepCondition"
  - "sequence.yaml as a validated, flattened, execution-ordered object graph, with schemas/sequence.schema.json"
  - "The step contract: New-HDTStepResult, New-HDTServiceCatalog, New-HDTExecutionContext"
  - "Discovery by convention: Get-HDTStepType and Import-HDTStepModule"
  - "The three dispatchers: Invoke-HDTStep, Test-HDTStepApplicable, Get-HDTStepDescription"
  - "IProcessService and IPowerService, fake and real; IScriptInvoker gains GetTranscript"
  - "The five step types M2 ships: NoOp, SetVariable, PowerShell, CommandLine, Restart"
  - "tests/contract/StepContract.Tests.ps1, which holds every step type ever added to the same bar by enumeration"
affects: [03-03-reboot-resume, 03-04-the-loop, 03-05-headline-test, 04-imaging, 06-drivers, 07-applications]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Flattening: nested groups become one linear 1-based step list, so resume by index survives nesting"
    - "Discovery by convention over a registry: a step type is a function name, enumerated through Get-Module"
    - "A pre-built -StepType registry passed to every dispatcher, so the loop pays discovery once per run"
    - "GetRequired(service, caller): a missing service is a sentence, not a StrictMode property error"
    - "A contract test driven by -ForEach at discovery time, so a type added later is covered without editing the file"
    - "PROJECT constraint 4 made mechanical: every step file is grepped for the cmdlets it may not name"

key-files:
  created:
    - schemas/sequence.schema.json
    - src/Hephaestus/Private/ConvertFrom-HDTStepCondition.ps1
    - src/Hephaestus/Private/Assert-HDTSequenceDocument.ps1
    - src/Hephaestus/Public/Test-HDTStepCondition.ps1
    - src/Hephaestus/Public/Import-HDTSequenceDocument.ps1
    - src/Hephaestus/Public/Get-HDTStepType.ps1
    - src/Hephaestus/Public/Import-HDTStepModule.ps1
    - src/Hephaestus/Public/New-HDTStepResult.ps1
    - src/Hephaestus/Public/New-HDTServiceCatalog.ps1
    - src/Hephaestus/Public/New-HDTExecutionContext.ps1
    - src/Hephaestus/Public/Invoke-HDTStep.ps1
    - src/Hephaestus/Public/Test-HDTStepApplicable.ps1
    - src/Hephaestus/Public/Get-HDTStepDescription.ps1
    - src/Hephaestus/Public/New-HDTProcessService.ps1
    - src/Hephaestus/Public/New-HDTPowerService.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTNoOpStep.ps1
    - src/Hephaestus/Public/Steps/Get-HDTNoOpStepDescription.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTSetVariableStep.ps1
    - src/Hephaestus/Public/Steps/Get-HDTSetVariableStepDescription.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTPowerShellStep.ps1
    - src/Hephaestus/Public/Steps/Test-HDTPowerShellStepApplicable.ps1
    - src/Hephaestus/Public/Steps/Get-HDTPowerShellStepDescription.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTCommandLineStep.ps1
    - src/Hephaestus/Public/Steps/Get-HDTCommandLineStepDescription.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTRestartStep.ps1
    - src/Hephaestus/Public/Steps/Get-HDTRestartStepDescription.ps1
    - tests/contract/SequenceSchema.Contract.Tests.ps1
    - tests/contract/StepContract.Tests.ps1
    - tests/contract/ProcessService.Contract.Tests.ps1
    - tests/contract/PowerService.Contract.Tests.ps1
    - tests/fixtures/scripts/Write-HostAndObject.ps1
    - tests/fixtures/sequences/ (15 fixtures)
  modified:
    - src/Hephaestus/Hephaestus.psd1
    - src/Hephaestus/Public/New-HDTScriptInvoker.ps1
    - tests/helpers/HDTFakes/HDTFakes.psm1
    - tests/helpers/HDTFakes/HDTFakes.psd1
    - tests/helpers/README.md
    - tests/unit/FakeJournal.Tests.ps1
    - tests/unit/New-HDTFakeScriptInvoker.Tests.ps1
    - tests/contract/ScriptInvoker.Contract.Tests.ps1

key-decisions:
  - "A node is a GROUP when it declares `steps`, not when it declares `group`. DESIGN 4.1's own ApplyDrivers step carries `group: \"%HDTDriverGroup%\"` as a type-specific property, so the planned discriminator would have rejected the design's own document"
  - "DESIGN 4.1 needs THREE corrections to import, not the two the plan found: the condition value, the condition's YAML quoting, and the variable names OSImage/DiskLayout, which DESIGN 3.2 requires to be HDT-prefixed"
  - "Get-HDTStepType enumerates Get-Module, not Get-Command -All: from inside a module's own session state, -All returns only the winning definition of a shadowed name, so the duplicate this function exists to report would be invisible from where it runs"
  - "The Get-Command fallback for a dot-sourced step type carries -ListImported, because a wildcard Get-Command without it scans every module on every PSModulePath and was observed hanging for minutes on a cold cache"
  - "timeoutMinutes: 0 is refused at import. Unbounded is the ABSENCE of the key; writing 0 is far more likely to be a mistake"
  - "The flattened step's Retry is a pscustomobject, never a hashtable: on a hashtable, .Count is ICollection.Count and would silently shadow the retry count the loop reads"
  - "Steps combine paths with [System.IO.Path]::Combine, never Join-Path, which resolves the drive qualifier through the provider and throws for a workspace drive the session cannot see"
  - "SetVariable throws HDTConfigurationError for a bad variable NAME but returns Failed for a missing assignment: the first is broken authoring, the second is a step that could not do its job"
  - "CommandLine checks rebootCodes BEFORE successCodes, so an installer that lists 3010 in both still gets its reboot"
  - "The real IPowerService contract row is Skip = $true permanently: a contract test may not reboot the machine running it"

patterns-established:
  - "The flattened step record and its defaults, which 03-04's loop is written directly against"
  - "Every dispatcher takes an optional pre-built -StepType registry"
  - "A step's provenance is a log record, not an entry in 02-03's closed Source set"
  - "A step that cannot do its job returns Failed; a step that was authored wrongly throws"

# Metrics
duration: 210min
completed: 2026-08-13
---

# Phase 03 Plan 02: The Sequence Document and the Step Contract Summary

**`sequence.yaml` becomes a validated, flattened, execution-ordered object graph; a step type becomes a function name any module can supply; and five step types run end-to-end under Pester with no process started, no file written and no machine rebooted.**

## Performance

- **Duration:** ~210 min
- **Tasks:** 4 of 4
- **Files created:** 46 · **Files modified:** 8
- **Suite:** **1848 passed / 0 failed / 12 skipped** under pwsh 7.5.8 (`build.ps1 -Task ci`, exit 0); **1772 passed / 0 failed / 88 skipped** under Windows PowerShell 5.1.26100.8655 (`build.ps1 -Task test`, exit 0). Baseline before this plan was 1326 / 1278.
- PSScriptAnalyzer: 0 diagnostics across 158 files.

## Task Commits

1. **Task 1: the condition grammar** — `7dd38e1` (test) → `a252354` (feat)
2. **Task 2: sequence.yaml — schema, validator, import, flattening** — `b98d2c8` (test) → `6664fe9` (feat)
3. **Task 3: the step contract, discovery, execution context** — `06b499e` (test) → `ab4eae5` (feat)
4. **Task 4, in six pairs:**
   - services — `b80f6db` (test) → `edb194a` (feat)
   - NoOp — `5a98f20` → `7dbde26`
   - SetVariable — `3491505` → `88fc73b`
   - PowerShell — `827f556` → `af68e99`
   - CommandLine — `18c2b84` → `b9b9920`
   - Restart — `ef2b5d9` → `f708e12`
   - the step contract test — `80088cb`

`git log --oneline` shows `test(03-02)` before every `feat(03-02)`.

## Reference for 03-03, 03-04 and 03-05

### The flattened step record

`Import-HDTSequenceDocument -Path -FileSystem` returns
`Path, SchemaVersion, Id, Name, Description, Variable, Step, Group`.
`Variable` is an ordered case-insensitive dictionary; `Group` is one record per
group node (`Path [string[]]`, `Condition`, `RunIn`). Each element of `Step`:

| Property | Meaning | Default |
|---|---|---|
| `Index` | 1-based position in execution order | — |
| `Name` / `Type` | from the document | — |
| `GroupPath` | `[string[]]`, outermost first, `@()` at the root | `@()` |
| `Condition` | the step's own condition | `$null` |
| `GroupCondition` | `[object[]]` of `{ Group; Condition }`, outermost first, only ancestors that declare one | `@()` |
| `ContinueOnError` | `[bool]` | `$false` |
| `TimeoutMinutes` | `[int]`, 0 = unbounded | `0` |
| `RunIn` | `WinPE` \| `FullOS` \| `Any`; inherited from the nearest ancestor group | `Any` |
| `Retry` | **pscustomobject** `{ Count; DelaySecond; Backoff }` | `0 / 0 / fixed` |
| `Resumable` | `[bool]` | `$false` |
| `Log` | per-step log file name (DESIGN 4.4.4) | `$null` |
| `Property` | ordered, case-insensitive: every key that is **not** a common property | — |

Common properties, and therefore the keys that never appear in `Property`:
`name`, `type`, `condition`, `continueOnError`, `timeoutMinutes`, `runIn`,
`retry`, `resumable`, `log`.

**`Retry` is a pscustomobject on purpose.** On a hashtable, `$step.Retry.Count`
resolves to `ICollection.Count` — the number of keys — and would silently shadow
the retry count. With `@{ Count = 3; DelaySecond = 15; Backoff = 'exponential' }`
it even returns 3, so the bug would hide behind a coincidence.

### The step result

```
New-HDTStepResult -Status <Completed|Failed|RebootRequested> [-ExitCode] [-Message] [-Data]
  -> [pscustomobject] @{ Status; ExitCode = 0; Message = ''; Data = $null }
```

The set is closed at three names by `ValidateSet`. **`RebootRequested` does not
mean the step rebooted.** The ceremony — arm autologon → save state → log
`reboot.arm` → restart — belongs to the loop, which owns the state document; a
step that rebooted itself could not be checkpointed. `Invoke-HDTRestartStep`
carries the delay in `Data.DelaySecond` for the loop to hand to `IPowerService`.

### The step type registry

```
Get-HDTStepType [-Name <string[]>]
  -> [pscustomobject] @{ Type; InvokeCommand; TestCommand; DescriptionCommand; Source }
```

Sorted by `Type`. `TestCommand` and `DescriptionCommand` are `$null` when the
type declares none; companions are taken from the **same source module** as the
invoke command, so a third party cannot half-override another vendor's type.

**Naming reservation: no future HDT function may be named `Invoke-HDT*Step`
unless it is a step type.** The name *is* the registry.
`Invoke-HDTStep` itself does not match — its type part is empty — so the
dispatcher never discovers itself.

Two modules exporting one type is a terminating `HDTConfigurationError` naming
both sources.

All three dispatchers take an optional pre-built registry:

```
Invoke-HDTStep         -Step -Context [-StepType]  -> the step's result, unchanged
Test-HDTStepApplicable -Step -Context [-StepType]  -> [bool]
Get-HDTStepDescription -Step         [-StepType]   -> [string], never empty
```

`Invoke-HDTStep` **does not catch**: classification, retry and `continueOnError`
are the loop's. An unknown type is a configuration error listing the known types.
`Test-HDTStepApplicable` returns `$true` for a type not in the registry —
reporting an unknown type from two places would give the loop two messages for
one fault.

### The service catalog

```
New-HDTServiceCatalog -FileSystem -Clock [-Registry] [-Lsa] [-Process] [-Power]
                      [-ScriptInvoker] [-Cim] [-Environment]
```

Nine properties, **all defined even when `$null`**, because a missing property
under `Set-StrictMode -Version Latest` throws an error that names nothing.

```
$catalog.GetRequired('Process', 'CommandLine')
```

returns the service or throws naming both it and the step type that asked.
`FileSystem` and `Clock` are mandatory; a `NoOp` sequence runs on those two alone.

### The execution context

```
New-HDTExecutionContext -RunId -Phase -WorkspaceRoot -Variable -Service -Log [-State]

  RunId, Phase, WorkspaceRoot, Variable (LIVE), Service, Log, State, Attempt (1-based)
  SetStep($index, $name, $type [, $stepLogPath])
```

It seeds `_HDTRunId`, `_HDTPhase`, `_HDTLogPath`, `_HDTDeployRoot`, `_HDTVersion`
into the live dictionary at construction, and `_HDTStepName` / `_HDTStepType` on
every `SetStep`. `SetStep` forwards to the log context in the same call, so the
variables and the log cannot drift — DESIGN 4.4.4's "attributable without the
author doing anything". **It performs no I/O**: it is built in WinPE before a
disk exists.

`Attempt` is set by the loop before each call. `NoOp`'s `failAttempt` reads it.

### The condition grammar, as implemented

```
<condition> := <operand> <operator> <operand>
<operand>   := '"' anything-but-a-double-quote '"'  |  a token with no whitespace and no double quote
<operator>  := == | != | -eq | -ne | -like | -notlike
```

`ConvertFrom-HDTStepCondition` returns `{ Left; Operator; Right; Text }` with the
operands' surrounding quotes stripped, or throws `HDTConfigurationError` naming
the condition. It runs at **import**, from `Assert-HDTSequenceDocument`.

An unquoted operand may not contain a double quote — that is what turns
`"%A% == "1"` into a refusal instead of a silent misparse into two odd operands.

`Test-HDTStepCondition -Condition -Variable [-Unresolved] [-Path]` expands both
operands, renders both through `ConvertTo-HDTComparableString` and compares
case-insensitively. An absent, empty or whitespace-only condition is `$true`. An
unresolved `%Var%` stays **literal**, so the comparison simply fails and the name
is reported through `-Unresolved`; it is not an error and it does not become `""`.

**YAML form:** because a condition carries double quotes as part of its grammar,
it must be a single-quoted YAML scalar:

```yaml
condition: '"%_HDTPhase%" == "FullOS"'
```

### The two schema blind spots

Listed in `tests/contract/SequenceSchema.Contract.Tests.ps1` with a test that
asserts the schema *accepts* each, so the day draft-07 can express one, the test
goes red rather than the exclusion going stale.

| Fixture | Why the schema cannot say it |
|---|---|
| `invalid-bad-condition.yaml` | JSON Schema cannot parse HDT's condition grammar. To the schema a condition is a string, so `"%A% =~ 1"` is well formed |
| `invalid-group-and-step.yaml` | `oneOf` accepts a node carrying `group`, `name`, `type` **and** `steps`, because the step branch requires only `name` and `type` and tolerates extra properties, so exactly one branch matches |

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 1 — Design bug] A node is a group when it declares `steps`, not `group`**

- **Found during:** Task 2, writing `valid-design-example.yaml`
- **Issue:** The plan specified "a node with both `group` and `type` is an error".
  But DESIGN 4.1's own `ApplyDrivers` step declares `group: "%HDTDriverGroup%"` as
  a *type-specific property* — a driver group. Keying the discriminator off
  `group` would have rejected the very document the fixture exists to prove.
- **Fix:** The discriminator is `steps`. A node declaring both `steps` and `type`
  is the error, and it is still the JSON Schema blind spot the plan predicted
  (the fixture now carries `group`, `name`, `type` and `steps`). `group` stays in
  a step's `Property` bag, with a test asserting it.
- **Files:** `src/Hephaestus/Private/Assert-HDTSequenceDocument.ps1`,
  `src/Hephaestus/Public/Import-HDTSequenceDocument.ps1`,
  `tests/fixtures/sequences/invalid-group-and-step.yaml`
- **Commits:** `b98d2c8`, `6664fe9`

**2. [Rule 1 — Design bug] DESIGN 4.1 needs a third correction, not two**

- **Found during:** Task 2
- **Issue:** The plan documented two bugs in DESIGN 4.1's condition line. A third
  exists: the example declares `variables: { OSImage: ..., DiskLayout: ... }`, and
  DESIGN 3.2 requires every deployment variable to be `HDT`-prefixed — which
  `Assert-HDTSequenceDocument` enforces, exactly as `Assert-HDTRuleDocument` does.
  As printed, the design's own sequence would not import.
- **Fix:** `valid-design-example.yaml` uses `HDTOSImage` and `HDTDiskLayout`, with
  all three corrections listed in a header comment on the fixture.
- **Carried to 03-05:** the docs task must correct DESIGN 4.1 for **all three**,
  and note the `steps` discriminator.
- **Commit:** `b98d2c8`

**3. [Rule 3 — Blocking] `Get-Command -All` cannot see a shadowed function from inside a module**

- **Found during:** Task 3, when the "two modules export one type" test stayed green
- **Issue:** Probed and confirmed on this machine: from inside the Hephaestus
  module's session state, `Get-Command -Name 'Invoke-HDT*Step' -All` returns only
  the *winning* definition of a shadowed name. The duplicate `Get-HDTStepType`
  exists to report would have been invisible from exactly where it runs.
- **Fix:** Discovery enumerates every loaded module's `ExportedFunctions` table,
  which is per module and cannot be shadowed, plus a `-ListImported` `Get-Command`
  for a step type dot-sourced into the session with no module.
- **File:** `src/Hephaestus/Public/Get-HDTStepType.ps1` · **Commit:** `ab4eae5`

**4. [Rule 3 — Blocking] A wildcard `Get-Command` scans every module path**

- **Found during:** Task 3, when a test run hung past five minutes
- **Issue:** `Get-Command -Name 'Invoke-HDT*Step','Test-HDT*StepApplicable','Get-HDT*StepDescription'`
  with a cold command-analysis cache scans every module on every `PSModulePath`.
  Discovery runs once per dispatch when the loop passes no registry, so it may not
  do that.
- **Fix:** `-ListImported`, with the reason in a comment. Measured at 13 ms.
- **File:** `src/Hephaestus/Public/Get-HDTStepType.ps1` · **Commit:** `ab4eae5`

**5. [Rule 1 — Bug] `Join-Path` throws for a drive the session cannot see**

- **Found during:** Task 4(d)
- **Issue:** `Join-Path -Path 'X:\Deploy' -ChildPath 'Scripts\x.ps1'` resolves the
  drive qualifier through the PowerShell provider and throws *"Cannot find drive.
  A drive with the name 'X' does not exist."* Every WinPE-side path evaluated from
  a technician's desk — and every test — hits this.
- **Fix:** `[System.IO.Path]::Combine`, which is pure string work.
- **File:** `src/Hephaestus/Public/Steps/Invoke-HDTPowerShellStep.ps1` · **Commit:** `af68e99`

**6. [Rule 1 — Bug] The step contract test caught its first hit immediately**

- **Found during:** Task 4, first run of `StepContract.Tests.ps1`
- **Issue:** `Invoke-HDTPowerShellStep`'s comment-based help said "never with a
  bare `&` or `Start-Process`", and the forbidden-call grep is deliberately crude.
- **Fix:** The prose no longer names the cmdlet, and says why. This is the check
  working, not a false positive: a grep that made an exception for comments would
  make one for a commented-out call too.
- **Commit:** `80088cb`

### Test defects fixed while red

- `{ $result = ... } | Should -Not -Throw` never reaches the assertion: the
  scriptblock runs in a child scope, so `$result` stayed `$null` and the test
  would have passed for the wrong reason. Replaced with `try/catch` and an
  explicit "no record was caught" assertion.
- An `It` name containing `<Type>` is expanded by Pester as a `-ForEach`
  placeholder. With no matching data it throws *"The variable '$Type' cannot be
  retrieved"* — but **only at Normal/Detailed verbosity**, so the test passed
  under `-Verbosity None` and failed under `build.ps1`'s default. Renamed.
- Five refusal assertions were tightened from a bare `Should -Throw` to
  `FullyQualifiedErrorId -BeLike 'HDTConfigurationError*'` after they were
  observed passing against `CommandNotFoundException` before any implementation
  existed (tests/helpers/README.md section 12).

### Structural choices worth recording

- **`New-HDTStepResult.Tests.ps1` was added**, though the plan's file list folded
  those assertions elsewhere. A closed three-name `Status` set deserves its own file.
- **Flattening stayed inside `Import-HDTSequenceDocument`** rather than moving to
  `Expand-HDTSequenceNode.ps1`. It is an explicit-stack walk, not recursion, and
  extracting it would have produced a private function whose only caller is one
  line away.
- **`Assert-HDTSequenceDocument` also walks with an explicit stack**, so every
  message is raised by `$PSCmdlet.ThrowTerminatingError` from the function that
  owns the error id, rather than from a nested scriptblock.

## Verification

| # | Item | Result |
|---|---|---|
| 1 | `pwsh -NoProfile -File ./build.ps1 -Task ci` | exit **0** — 1848 passed, 0 failed, 12 skipped; lint 0 diagnostics; selfcheck 4/4 |
| 2 | `powershell.exe -NoProfile -File ./build.ps1 -Task test` | exit **0** — 1772 passed, 0 failed, 88 skipped |
| 3 | `test(03-02)` before every `feat(03-02)` | confirmed, all nine pairs |
| 4 | `valid-design-example.yaml` imports into the exact ordered step list | confirmed by hand: 10 steps, `State Restore`'s four carrying that group and `'"%_HDTPhase%" == "FullOS"'` |
| 5 | Schema and engine validator agree on every fixture | 15 fixtures; both blind spots listed and justified in the contract file |
| 6 | `Get-HDTStepType` discovers an in-memory module; two modules is a named error | confirmed by test and by hand (`ContosoBeep` / `Contoso.HDTSteps`) |
| 7 | No file under `Public/Steps/` calls the filesystem, registry, CIM or a process | `Select-String` scan returns nothing; also enforced permanently by `StepContract.Tests.ps1` |

### Not verified, and honestly so

- **`New-HDTPowerService` has never been executed.** Its contract row is
  `Skip = $true` permanently, because a contract test may not reboot the machine
  running it. Phase 04's integration layer runs it on a throwaway VM.
- **Whether `shutdown.exe` works inside WinPE, or whether it must be
  `wpeutil reboot`, is unverified.** Recorded for phase 05. `-Command` exists so
  the answer can be supplied without changing a step or the adapter.
- **`Import-HDTStepModule` is exercised only through its own shape.** It is a thin
  branch-free adapter over `Import-Module`; the discovery tests use
  `New-Module | Import-Module` instead, which is stronger and writes no file.

## Carried debt

- **DESIGN 4.1 needs three corrections in 03-05's docs task**, not two: the
  condition value (`"OS"` → `"FullOS"`), the condition's YAML quoting (single-quoted
  scalar), and the variable names (`OSImage`/`DiskLayout` → `HDTOSImage`/`HDTDiskLayout`).
  The `steps` discriminator should be documented alongside them.
- **DESIGN 4.4.2 still documents eleven event names; the engine validates thirteen**
  (carried from 03-01). 03-05's docs task writes both.
- **`Invoke-HDT*Step` is now a reserved name shape.** Worth a line in DESIGN 15.1.
- **`New-HDTScriptInvoker.ResolvePath` still uses `Join-Path`** and would throw for
  a workspace on an unseen drive. It is not reached by any current caller, because
  the PowerShell step now hands it an absolute path — but 03-04 should either fix
  it or record it.

## Self-Check: PASSED

All 46 created files exist on disk; all 19 commit hashes cited above are present
in `git log`; both build commands were run to completion and exited 0.
