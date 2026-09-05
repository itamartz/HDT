---
phase: 08-windows-update
plan: 08-01-02
subsystem: injected-services
tags: [windows-update, wua, com, adapter, contract-test, fake]
requires:
  - 08-01-01
provides:
  - New-HDTUpdateSessionService
  - New-HDTFakeUpdateSessionService
  - "New-HDTServiceCatalog -UpdateSession"
affects:
  - src/Hephaestus/Public/New-HDTServiceCatalog.ps1
  - src/Hephaestus/Hephaestus.psd1
  - docs/command-categories.psd1
  - docs/command-reference.html
  - NOTICE.md
tech-stack:
  added:
    - "Windows Update Agent COM (Microsoft.Update.Session / UpdateColl / SystemInfo)"
  patterns:
    - "The COM lives behind an adapter the step is handed; every behavioural assertion runs against a hand-written fake"
    - "A -ForEach implementation table with the real row's skip decided at DISCOVERY, on a Context INSIDE the Describe"
    - "The fake mutates its seeded state the way the agent does, so a loop's termination is provable rather than a test of maxPasses"
key-files:
  created:
    - src/Hephaestus/Public/New-HDTUpdateSessionService.ps1
    - tests/contract/UpdateSessionService.Contract.Tests.ps1
  modified:
    - tests/helpers/HDTFakes/HDTFakes.psm1
    - tests/helpers/HDTFakes/HDTFakes.psd1
    - src/Hephaestus/Public/New-HDTServiceCatalog.ps1
    - src/Hephaestus/Hephaestus.psd1
    - tests/unit/New-HDTServiceCatalog.Tests.ps1
    - docs/command-categories.psd1
    - docs/command-reference.html
    - NOTICE.md
decisions:
  - "SearchUpdate is flat and unfiltered: categories, excludes and KB numbers are the step's decision, not the adapter's"
  - "SetServer is on the adapter, because writing four policy values and restarting wuauserv is IO rather than a decision - and that is what keeps the adapter branch-free"
  - "The contract asserts on the fake's DEFAULT update set: a discovery-time $script: variable is out of scope when the Factory scriptblock RUNS, and the failure is silent"
  - "A session per call, not one held on the service: the state belongs to the machine and the IUpdate objects, and DESIGN 10.1's loop reboots in the middle"
metrics:
  duration: "~50 min"
  completed: 2026-09-06
---

# Phase 08 Plan 01-02: IUpdateSessionService, the COM behind an adapter — Summary

`IUpdateSessionService` — a hand-written fake, a branch-free real adapter over
`Microsoft.Update.Session`, one contract file that runs the same shape
assertions over both, and an `UpdateSession` slot in the service catalog. The
`WindowsUpdate` step can now be written and proved without a machine, a WSUS
server or a single update installed.

## The interface, and the shapes plan 08-01-03 writes against

Six methods. **These property names are the contract; do not re-derive them.**

| Method | Signature | Returns |
|---|---|---|
| `SetServer` | `([string] $Url)` | nothing |
| `SearchUpdate` | `([string] $Criteria)` | `object[]`, one row per update |
| `AcceptEula` | `([string] $UpdateId)` | nothing |
| `DownloadUpdate` | `([string[]] $UpdateId)` | a result object |
| `InstallUpdate` | `([string[]] $UpdateId)` | a result object |
| `GetRebootRequired` | `()` | `[bool]` |

An update row:

```
UpdateId     [string]    the agent's Identity.UpdateID, a GUID string
Title        [string]
KBArticleId  [string[]]  WITHOUT the KB prefix - '5031354', not 'KB5031354'
Category     [string[]]  category NAMES: 'Security Updates', 'Windows 11'
IsDownloaded [bool]
EulaAccepted [bool]
SizeByte     [long]      MaxDownloadSize
```

A download or install result:

```
Success        [bool]      ResultCode -eq 2
ResultCode     [int]       0 NotStarted 1 InProgress 2 Succeeded
                           3 SucceededWithErrors 4 Failed 5 Aborted
HResult        [int]       the first non-zero one in the batch
RebootRequired [bool]      THIS BATCH asked for a restart. Always false from
                           DownloadUpdate - IDownloadResult carries no such
                           property and nothing is installed yet
PerUpdate      [object[]]  one element per update id, in the order given:
                           UpdateId, ResultCode, HResult
```

`GetRebootRequired()` is a **different question** from a result's
`RebootRequired`: it reads the machine (`ISystemInformation.RebootRequired`), so
it counts a servicing stack update that went in first or a restart pending from
before the deployment ran. The step needs both.

## The fake, and what a test can say with it

`New-HDTFakeUpdateSessionService`, hand-written in `HDTFakes.psm1` in the file's
existing class-plus-factory style.

| Parameter | What it says |
|---|---|
| `-Update` | the rows `SearchUpdate` answers with; hashtables or `[pscustomobject]`, any field omitted takes a default. `-Update @()` is a search that matched nothing |
| `-UpdatePerPass` | an array of arrays: pass 1, pass 2, …, last element repeating. The only way to say "installing that revealed another one" |
| `-InstallResult` | update id to `@{ ResultCode; HResult; RebootRequired }` |
| `-DownloadResult` | the same, for downloads |
| `-RebootRequired` | what `GetRebootRequired` answers |
| `-FailSearch`, `-FailInstall` | the agent throwing rather than returning a failure |
| `-Journal` | the shared cross-service journal |

Omitting `-Update` and `-UpdatePerPass` seeds a default pair — `1111…` a security
update (KB 5031354, not downloaded, EULA accepted) and `2222…` a cumulative
update (KB 5029351, downloaded, EULA **not** accepted) — and that pair is what
the contract file asserts on.

**It mutates its state the way the agent does**, which is the whole reason it is
worth trusting: a successful install removes its update from the next
`SearchUpdate`, because the real criteria is `IsInstalled = 0`; a **failed** one
stays; a download flips `IsDownloaded`; `AcceptEula` flips `EulaAccepted`. A fake
that kept returning an installed update would turn the multi-pass loop's
termination test into a test of `maxPasses` and hide an infinite loop.

## Deviations from Plan

### 1. [Rule 1 - Bug] The contract's seed rows could not be a `$script:` variable

**Found during:** Task 1, on the first green-ish run.
**Issue:** The plan sketched `Factory = { New-HDTFakeUpdateSessionService -Update @( … ) }` and the file-scope rows were written into `$script:HDTUpdateRow`. A discovery-time file-scope variable is **not in scope when the Factory scriptblock runs** — Pester evaluates it in the run phase — so the fake was seeded with nothing and eleven assertions read 0 rows. The failure is silent and looks exactly like a broken fake.
**Fix:** The rows moved into the fake as its documented default set, the variable is gone, and the file carries a comment saying why. `FeatureService.Contract` avoids the same trap by putting its literal inside the scriptblock.
**Commit:** d8de2c0

### 2. [Rule 3 - Blocking] A PowerShell class method may not name a local after a property

**Found during:** Task 1.
**Issue:** `$update = $this.FindUpdate($id)` inside `DownloadUpdate` failed to compile — "Cannot assign property, use '$this.Update'" — because the class has an `$Update` property and the parser treats the assignment as one.
**Fix:** the local is `$stored`.
**Commit:** d8de2c0

### 3. [Rule 1 - Bug] An `.EXAMPLE` named `$fs` and `$clock` from nowhere

**Found during:** Task 2, caught by `ExampleQuality.Contract.Tests.ps1`.
**Fix:** the catalog example builds both inline — `-FileSystem (New-HDTFileSystem) -Clock (New-HDTClock)`.
**Commit:** ceb46ea

### 4. The real row got a Context the plan did not name

The plan's `Context 'the shape, on a machine with no Windows Update Agent'` reads
as the opposite of what its skip expression does. It is
`Context 'the machine, through the real agent'`, skipped unless the row is real
**and** WUA is registered, and it asserts the one WUA call this plan is allowed
to make for real: `GetRebootRequired()`. It runs on this laptop — the agent is
registered here — so the real adapter is proved to reach the agent rather than
only to parse.

### 5. One `if` survives in the adapter, and it is the journal's

`New-HDTUpdateSessionService` contains no `if`, no `switch` and no `try` in any of
the six interface methods. The single `if` in the file is
`if ($null -ne $this.Journal)` inside `Record`, copied verbatim from
`New-HDTFeatureService`: it is the shared operation-journal plumbing every
service carries, not a decision about the agent.

### 6. The manifest commit carries a version bump this plan did not make

`src/Hephaestus/Hephaestus.psd1` already held an uncommitted `0.20.0 -> 0.21.0`
bump and new source hashes from another session when this plan started. Staging
the manifest to export the new command carried them along. Nothing was reverted;
the hashes had to be recomputed anyway once a new source file existed.

## Nothing was searched, downloaded or installed

The verification the plan asked for, run afterwards:

```
Microsoft-Windows-WindowsUpdateClient/Operational, last 20 events:
  a PAIR of event 26 every ten minutes, unbroken from 00:27 to 01:38 -
  before this session began and through it. That is the machine's own
  scheduled scan cadence and it did not change.

HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate carries
  DeferFeatureUpdates, DeferFeatureUpdatesPeriodInDays,
  PauseFeatureUpdatesStartTime - and NO WUServer, NO WUStatusServer,
  which is exactly what SetServer would have written. It was never called.
```

The real adapter's behaviour Context is skipped by design; the only real WUA call
the suite makes is `GetRebootRequired()`, which answered `False` and recorded one
operation.

## Verification

Real output, Windows PowerShell 5.1 (the gate; the pwsh pass is off):

```
./build.ps1 test   ->  14192 passed, 0 failed, 296 skipped   (499 files, 8 workers)
./build.ps1 lint   ->  0 diagnostics across 1162 files       (separate process)

Invoke-Pester tests/contract/UpdateSessionService.Contract.Tests.ps1,
              tests/unit/New-HDTServiceCatalog.Tests.ps1
                   ->  58 passed, 0 failed, 28 skipped
```

The RED runs, recorded before each implementation:

```
contract, before the fake and the adapter  ->  0 passed, 34 failed, 28 skipped
                                               every failure CommandNotFound
catalog, before the UpdateSession slot     ->  20 passed, 4 failed
```

And the module itself, imported and run rather than only faked:

```
New-HDTUpdateSessionService
  ServiceName        UpdateSessionService
  ScriptMethods      AcceptEula, DownloadUpdate, GetOperationName,
                     GetRebootRequired, InstallUpdate, Record, SearchUpdate,
                     SetServer
  GetRebootRequired  False
  GetOperationName   GetRebootRequired
```

## What plan 08-01-03 inherits

- A catalog slot: `New-HDTServiceCatalog -UpdateSession …`, and
  `GetRequired('UpdateSession', 'WindowsUpdate')` throwing "the run was started
  without one" when a sequence forgot it.
- A fake that can drive every branch the step has: the multi-pass loop
  (`-UpdatePerPass`), a refused install (`-InstallResult` with `ResultCode = 4`),
  an agent that throws (`-FailSearch` / `-FailInstall`), and a machine with a
  restart already pending (`-RebootRequired`).
- The decisions the adapter deliberately did **not** make, and therefore the
  step's whole job: which updates match `categories:`, which `exclude:` patterns
  rule out, whether to normalise `5031354` to `KB5031354`, whether to call
  `SetServer` at all, whether to run another pass, and whether to reboot.

## Self-Check: PASSED

Every file claimed above exists on disk and every commit hash resolves:

```
FOUND  src/Hephaestus/Public/New-HDTUpdateSessionService.ps1
FOUND  tests/contract/UpdateSessionService.Contract.Tests.ps1
FOUND  d8de2c0  test(08-01-02): IUpdateSessionService, asserted over a fake that behaves like the agent
FOUND  ceb46ea  feat(08-01-02): New-HDTUpdateSessionService, and the catalog slot the step reads it from
```
