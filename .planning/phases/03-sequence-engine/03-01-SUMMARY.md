---
phase: 03-sequence-engine
plan: 01
subsystem: infra
tags: [logging, jsonl, cmtrace, state-machine, json-schema, pester, tdd, powershell-5.1]

# Dependency graph
requires:
  - phase: 01-foundations
    provides: the module skeleton, the naming/5.1/MDT contract tests, New-HDTErrorRecord, Test-HDTSchemaVersion, the pscustomobject adapter shape
  - phase: 02-rules
    provides: New-HDTFakeFileSystem and the four real adapters, Resolve-HDTVariable and its provenance records, Get-HDTMachineFact, Export-HDTVariableProvenance's formatted-timestamp rule
provides:
  - "A shared cross-service operation journal on every fake and every real adapter, numbered globally"
  - "IClock as a fake (New-HDTFakeClock) and a real adapter (New-HDTClock)"
  - "New-HDTFileSystem, the real IFileSystem adapter, with AppendAllText and UTF-8 without a BOM"
  - "DESIGN 4.4 structured logging: Get-HDTLogPath, New-HDTLogContext, Write-HDTLog, Write-HDTStatus, Write-HDTVariableLog, Export-HDTMachineFact, Copy-HDTLog"
  - "DESIGN 4.3's state document: New/Save/Import/Update-HDTRunState* and Test-HDTRunStateAbandoned, with schemas/state.schema.json"
affects: [03-02-flattening, 03-03-reboot-resume, 03-04-retry-and-errors, 03-05-headline-test, 04-imaging, 07-applications]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Shared -Journal ArrayList across every service double, numbered globally"
    - "IClock injection so a multi-minute backoff is proven in microseconds"
    - "Two-formats-one-write logging through an injected IFileSystem"
    - "Every timestamp formatted to an invariant round-trip string before serialisation"
    - "Two validators, one verdict: a JSON Schema plus an engine validator that must agree"

key-files:
  created:
    - src/Hephaestus/Public/New-HDTFileSystem.ps1
    - src/Hephaestus/Public/New-HDTClock.ps1
    - src/Hephaestus/Public/Get-HDTLogPath.ps1
    - src/Hephaestus/Public/New-HDTLogContext.ps1
    - src/Hephaestus/Public/Write-HDTLog.ps1
    - src/Hephaestus/Public/Write-HDTStatus.ps1
    - src/Hephaestus/Public/Write-HDTVariableLog.ps1
    - src/Hephaestus/Public/Export-HDTMachineFact.ps1
    - src/Hephaestus/Public/Copy-HDTLog.ps1
    - src/Hephaestus/Public/New-HDTRunState.ps1
    - src/Hephaestus/Public/Save-HDTRunState.ps1
    - src/Hephaestus/Public/Import-HDTRunState.ps1
    - src/Hephaestus/Public/Update-HDTRunStateStep.ps1
    - src/Hephaestus/Public/Test-HDTRunStateAbandoned.ps1
    - src/Hephaestus/Private/ConvertTo-HDTLogRecord.ps1
    - src/Hephaestus/Private/ConvertTo-HDTCmTraceLine.ps1
    - src/Hephaestus/Private/Assert-HDTRunStateDocument.ps1
    - schemas/state.schema.json
    - tests/contract/ClockService.Contract.Tests.ps1
    - tests/contract/StateSchema.Contract.Tests.ps1
    - tests/unit/FakeJournal.Tests.ps1
  modified:
    - tests/helpers/HDTFakes/HDTFakes.psm1
    - tests/helpers/README.md
    - tests/contract/FileSystemService.Contract.Tests.ps1
    - src/Hephaestus/Hephaestus.psd1

key-decisions:
  - "-Event keeps its DESIGN 4.4.2 name and carries a PSAvoidAssignmentToAutomaticVariable suppression, rather than being renamed away from the design's vocabulary"
  - "The event ValidateSet holds thirteen names: DESIGN 4.4.2's eleven plus reboot.teardown and message. DESIGN 4.4.2's list must be updated to thirteen in 03-05"
  - "Every -Clock and -Timestamp parameter that stamps a document is Mandatory, so no engine function can fall back to a real clock"
  - "Import-HDTRunState normalises timestamps back to strings, because ConvertFrom-Json rehydrates ISO 8601 into [datetime] under pwsh 7 and not under 5.1"
  - "A corrupt state.json is a terminating HDTConfigurationError; a missing one is HDTStateNotFound. They are different answers because only the second may restart from step 1"
  - "Copy-HDTLog classifies a child as a file with GetLength rather than widening IFileSystem with an IsDirectory method"

patterns-established:
  - "Journal: every Record() appends to $Operations and, when supplied, to a shared globally numbered journal; ServiceName names the service without a type literal"
  - "Timestamps: .ToUniversalTime().ToString('o', InvariantCulture) before any ConvertTo-Json, asserted on the file text rather than through ConvertFrom-Json"
  - "Verbosity: a dropped log call consumes no seq number and performs no I/O"
  - "Contract exception assertions unwrap to the innermost exception, so one assertion serves a class fake and a ScriptMethod adapter"

# Metrics
duration: 175min
completed: 2026-08-13
---

# Phase 03 Plan 01: Journal, Logging and State Summary

**The three pieces the rest of phase 03 writes through: one globally numbered cross-service operation journal, DESIGN 4.4's two-formats-one-write logging with a reboot-surviving `seq`, and DESIGN 4.3's `state.json` — all provable against fakes with nothing on disk and no wall clock.**

## Performance

- **Duration:** ~175 min
- **Tasks:** 3 of 3
- **Files created:** 21 · **Files modified:** 8
- **Suite:** 1326 passed / 0 failed / 9 skipped under pwsh 7.5.8 (`-Task ci`, exit 0); 1278 passed / 0 failed / 57 skipped under Windows PowerShell 5.1.26100.8655 (`-Task test`, exit 0). Baseline before this plan was 863 passed.

## Accomplishments

- **The shared journal.** All six `New-HDTFake*` factories and both new real adapters take `-Journal`. `Record()` appends to `$Operations` *and* to the journal, which numbers globally across services, so 03-05's headline test can assert `'FileSystem.ReadAllText', 'Clock.GetUtcNow', 'FileSystem.AppendAllText'` in one list. `tests/unit/FakeJournal.Tests.ps1` enforces it over a `-ForEach` list of every factory, so a fake added later that forgets it turns the suite red.
- **The two missing services.** `IClock` exists as `New-HDTFakeClock` (UTC-normalised, frozen by default, `Sleep` advances without waiting) and `New-HDTClock`. `IFileSystem` gained `AppendAllText` on both sides, and `New-HDTFileSystem` is the real adapter the 02 verification report asked for — writing UTF-8 **without a BOM** through `System.IO.File`, verified by hand under both engines (`123,34,97`, not `239,187,191`).
- **DESIGN 4.4 logging.** One `Write-HDTLog` call emits a JSONL record and a CMTrace line, plus the per-step line when a step log is set, all through the injected filesystem, with `seq` monotonic within a leg and continuable across one.
- **DESIGN 4.3 state.** A run's state is creatable, mirrorable, readable back with validation, updatable per step and classifiable as abandoned — with `schemas/state.schema.json` and `Assert-HDTRunStateDocument` agreeing on all six enumerated fixtures plus two writer round trips.

## Task Commits

1. **Task 1: the shared journal, IClock and the real IFileSystem** — `b29bc90` (test) → `fb05465` (feat)
2. **Task 2: Write-HDTLog, two formats one write** — `2e029fd` (test) → `c82e626` (feat)
3. **Task 3: state.json, the run state document** — `d486135` (test) → `470cc5d` (feat)

`git log --oneline` shows `test(03-01)` before every `feat(03-01)`.

## Reference for the rest of phase 03

### Journal entry shape

| Property | Meaning |
|---|---|
| `Sequence` | 1-based, **global across every service** sharing the journal |
| `Service` | the recorder's `ServiceName` |
| `Operation` | the method name |
| `Arguments` | `object[]`, in declaration order |

`ServiceName` values: `FileSystem`, `Clock`, `CimProvider`, `RegistryService`, `EnvironmentProvider`, `ScriptInvoker`. Seeding is never recorded in either sink; `$Operations` keeps its own independent 1-based numbering.

### IClock

```
GetUtcNow()               -> [datetime], Kind = Utc
Sleep([int] $Millisecond) -> void
```

Fake extras (seeding, never recorded): `Advance([int])`, `TotalSleepMillisecond`, `TickMillisecond`. `-UtcNow` is normalised: `Unspecified` is taken as already UTC, anything else goes through `ToUniversalTime()`.

### IFileSystem — nine methods

`TestPath`, `ReadAllText`, `WriteAllText`, **`AppendAllText`**, `CreateDirectory`, `RemoveItem`, `CopyItem`, `GetChildItem`, `GetLength`.

### JSONL key order (DESIGN 4.4.2)

```
ts, runId, seq, level, phase, stepIndex, stepName, stepType,
component, event, message, durationMs, data
```

`stepIndex`/`stepName`/`stepType` are **omitted** when no step is set; `durationMs` and `data` are **omitted** when not supplied. `ts` is always a formatted string.

### The `event` vocabulary — thirteen names

DESIGN 4.4.2's eleven: `run.start`, `run.end`, `phase.change`, `step.start`, `step.complete`, `step.fail`, `step.skip`, `var.resolve`, `native.exec`, `reboot.arm`, `reboot.resume`.

**This plan added two, and DESIGN 4.4.2's list must be edited to thirteen by 03-05's docs task:**

- **`reboot.teardown`** — the DESIGN 4.5.3 autologon teardown, emitted by 03-03.
- **`message`** — the default when a call supplies no `-Event`, which is what every custom step's bare `Write-HDTLog "..."` produces (DESIGN 4.4.4).

`Write-HDTLog.Tests.ps1` reads the `ValidateSet` off the parameter metadata and asserts the exact sorted list of thirteen, so a fourteenth name cannot be added silently.

### Log context

**Properties:** `RunId`, `Phase`, `LogPath`, `FileSystem`, `Clock`, `Level`, `Seq`, `StepIndex`, `StepName`, `StepType`, `StepLogPath`, `Component`, `ThreadId`, `JsonlPath`, `MasterLogPath`.

**Methods:** `SetStep($index, $name, $type, $stepLogPath)`, `ClearStep()`, `NextSeq()`.

It performs **no I/O at construction**. Severity order is `Error` < `Warning` < `Info` < `Debug`; a call above the context's level is dropped without consuming a `seq` number and without touching the filesystem or the clock.

### state.json fields

| Field | Meaning |
|---|---|
| `schemaVersion` | 1 |
| `runId` / `sequenceId` | the run and the sequence it is executing |
| `status` | `Running` \| `Succeeded` \| `Failed` |
| `phase` | `WinPE` \| `FullOS` |
| **`leg`** | 1-based; **incremented on every resume** (03-03 owns the increment) |
| **`seq`** | the last JSONL seq written — seed `New-HDTLogContext -Seq` from it and DESIGN 4.4.2's counter survives the reboot |
| `startedUtc` / `updatedUtc` | round-trip strings; `updatedUtc` is stamped by every `Save-HDTRunState` |
| **`stepIndex`** | the 1-based index of the **NEXT** step to run |
| `pauseOnError` | bool |
| `variable` | ordered, case-insensitive name → value |
| `step[]` | `index`, `name`, `type`, `group[]`, `status`, `attempt`, `resumable`, `startedUtc`, `endedUtc`, `durationMs`, `exitCode`, `message` |
| `autoLogon` | `armed`, `userName`, `domainName`, `countSet`, `secretName`, `runOnceName` |
| `deploymentPassword` | the per-deployment secret, or `null` after teardown |

### `Update-HDTRunStateStep` and `stepIndex`

| Status set | Does `stepIndex` advance to `Index + 1`? |
|---|---|
| `Completed` | **Yes** |
| `Skipped` | **Yes** |
| `Running` | No |
| `Failed` | **No** — a failed run resumes *at* the failure, not after it |
| `Pending` | No |

`Test-HDTRunStateAbandoned` returns `$true` when `status` is `Succeeded` or `Failed`, when `status` is `Running` and `updatedUtc` is older than `-MaxAgeHour` (default 12), or when `updatedUtc` is missing or unparseable.

## Decisions Made

1. **`-Event` kept its name.** PSScriptAnalyzer's `PSAvoidAssignmentToAutomaticVariable` (Warning, and the analyzer settings promote Warnings to build failures) fires on a parameter named `Event`. Renaming it would have put the engine's public surface out of step with DESIGN 4.4.2's field name, so `Write-HDTLog` and `ConvertTo-HDTLogRecord` carry a targeted suppression instead. Verified by probe that the suppression silences the rule.
2. **Mandatory clocks and timestamps.** `New-HDTRunState -Clock`, `Save-HDTRunState -Clock` and `Export-HDTMachineFact -Timestamp` are all `Mandatory = $true`. The plan wrote them optional, but an optional one needs a default, and the only honest default is a real clock reading inside engine code — exactly what PROJECT constraint 4 forbids.
3. **`Copy-HDTLog` never throws.** DESIGN 4.4.1 copies logs back *on failure too*; a copy-back that threw would mask the failure it exists to preserve evidence of. It logs a Warning and returns nothing.
4. **File-vs-directory via `GetLength`.** `IFileSystem` has no "is this a directory" method. `GetLength` succeeds for a file and throws `FileNotFoundException` for a directory on **both** implementations, so `Copy-HDTLog` uses it rather than widening the interface for one caller.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] `-Event` fails the linter, which fails `-Task ci`**
- **Found during:** Task 2
- **Issue:** `PSAvoidAssignmentToAutomaticVariable` flags a parameter named `Event`. `PSScriptAnalyzerSettings.psd1` sets `Severity = @('Error','Warning')` with `ExcludeRules = @()`, so it breaks the build.
- **Fix:** Targeted `[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Event', ...)]` on `Write-HDTLog` and `ConvertTo-HDTLogRecord`, keeping DESIGN 4.4.2's field name.
- **Verification:** A two-function probe confirmed the rule fires without the attribute and is silent with it; `-Task lint` reports 0 diagnostics across 113 files.
- **Committed in:** `c82e626`

**2. [Rule 1 — Bug] Existing `IFileSystem` contract assertions could not pass against a real adapter**
- **Found during:** Task 1
- **Issue:** Five assertions used `Should -Throw -ExceptionType`. Per `tests/helpers/README.md` §5, that passes against a class fake and **fails** against a `ScriptMethod` adapter, whose exception arrives wrapped twice. Adding the real row would have turned them red.
- **Fix:** Converted all five to the innermost-exception unwrapping shape the README prescribes. Also gave each test a fresh temp directory, because the real adapter genuinely writes and `$TestDrive` reuse across `BeforeEach` would have let one test see another's files.
- **Verification:** Both contract rows pass; 66 assertions across the two implementations.
- **Committed in:** `fb05465`

**3. [Rule 1 — Bug] `ReadAllText` on a missing file in a missing directory is `DirectoryNotFoundException`**
- **Found during:** Task 1
- **Issue:** The contract asserted `FileNotFoundException` for a missing file, but the real adapter reported the missing *parent directory* first — a different and equally correct answer that says nothing about the file.
- **Fix:** The test creates the directory first, so it asks the question it means to ask.
- **Committed in:** `fb05465`

**4. [Rule 1 — Bug] `ConvertFrom-Json` rehydrates ISO 8601 into `[datetime]` under pwsh 7 and not under 5.1**
- **Found during:** Task 3
- **Issue:** `Assert-HDTRunStateDocument` required `startedUtc`/`updatedUtc` to be strings, which is true of what is *written* and false of what pwsh 7 *reads back*. Fifteen tests went red, including the schema-agreement tests — the engine validator was rejecting the very documents the schema accepts. This is the mirror image of 02-03's `\/Date(...)\/` trap and had not been recorded anywhere.
- **Fix:** The validator accepts a string or a `[datetime]` for the two stamps (both name the same instant, and the schema still requires a string in the raw JSON). `Import-HDTRunState` normalises every timestamp — the document's two and each step's two — back to the invariant round-trip string, so an imported document has one shape rather than one shape per engine. `Test-HDTRunStateAbandoned` handles a `[datetime]` directly for a document parsed elsewhere.
- **Verification:** Cross-engine round trip run by hand — written under pwsh 7.5.8, read under 5.1 through the *real* `New-HDTFileSystem`, all values matching and `startedUtc.GetType().Name` = `String`.
- **Committed in:** `470cc5d`

**5. [Rule 3 — Blocking] Three test-authoring defects that only appear under the real harness**
- **Found during:** Tasks 2 and 3
- **Issue:** (a) `Should -BeLike` treats `[` as a character class, so every `<![LOG[...` pattern silently failed to match; (b) `build.ps1` sets `Set-StrictMode -Version Latest`, which propagates into the tests, so `$_.level` on a record without that property threw where an ad-hoc run had passed; (c) Pester expands `<Name>` in a test name as a `-ForEach` placeholder, so the literal name `copies into <Destination>\<ComputerName>-<RunId>` failed under Detailed output.
- **Fix:** `StartsWith` for bracketed formats, presence-checked property access, and a plain test name. All three are now commented in place so the next author does not repeat them.
- **Committed in:** `c82e626`, `470cc5d`

---

**Total deviations:** 5 auto-fixed (2 × Rule 3 blocking, 3 × Rule 1 bug). No Rule 4 architectural decisions arose.
**Impact on plan:** None on scope. Every deviation was a correctness fix inside planned work; deviation 4 is the one that matters downstream and is recorded above as a decision as well.

## Issues Encountered

- **The plan's `[-Clock]` / `[-Timestamp]` optional signatures are unsatisfiable** without a real clock reading in engine code. Made mandatory; every test already passed one explicitly, so no test changed.
- **`Copy-HDTLog -ComputerName`** defaults to `[System.Environment]::MachineName`, which is untested by design (a test asserting it would assert the developer's machine name). The engine passes `%HDTComputerName%`. `PSAvoidUsingComputerNameHardcoded` is an *Error* and fires on a string literal bound to `-ComputerName` even in a test, so the test value lives in a variable.
- **Not proven:** nothing here has run in WinPE. `X:\HDT\Logs` is a string produced by pure logic and `[System.IO.Path]::GetFullPath('X:\HDT\Logs')` was confirmed to normalise on a machine with no `X:` drive, but the first real WinPE write happens in phase 05.

## Next Phase Readiness

Ready for 03-02 (flattening) — `New-HDTRunState -Step` already accepts both dictionaries and objects, so the flattener's output shape is not constrained by this plan.

Ready for 03-03 (reboot/resume) — `leg`, `seq`, `autoLogon` and `Test-HDTRunStateAbandoned` are in place, and `reboot.arm` / `reboot.resume` / `reboot.teardown` are all in the event vocabulary.

**Carried debt for 03-05:** DESIGN 4.4.2 lists **eleven** event names and the engine validates **thirteen**. 03-05's docs task must write `reboot.teardown` and `message` into that list — adding one of the two is not finished.

---
*Phase: 03-sequence-engine*
*Completed: 2026-08-13*

## Self-Check: PASSED

Every file this summary claims exists is on disk (11 of 11 spot-checked, including
all six `must_haves.artifacts` paths), and every commit hash it names is in
`git log` (6 of 6). `Write-HDTLog.ps1` is 198 lines against a 120 minimum;
`New-HDTFileSystem.ps1` is 227 against a 90 minimum. `AppendAllText`,
`WriteAllText` and `Journal` all appear at their required link sites.
