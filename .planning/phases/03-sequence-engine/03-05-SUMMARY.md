---
phase: 03-sequence-engine
plan: 05
subsystem: testing
tags: [pester, html-report, jsonl, task-sequence, end-to-end, samples, documentation]

# Dependency graph
requires:
  - phase: 03-01
    provides: the cross-service operation journal, IClock, structured JSONL logging and state.json
  - phase: 03-02
    provides: sequence.yaml import and flattening, the condition grammar, the step contract and the five M2 steps
  - phase: 03-03
    provides: the autologon lifecycle, the teardown checklist and the boot reconcile
  - phase: 03-04
    provides: the execution loop, retry, reboot-and-resume and Start-HDTResume.ps1
provides:
  - "ConvertTo-HDTReport: DESIGN 4.4.2's self-contained HTML report, rendered from the JSONL"
  - "ConvertTo-HDTHtmlText: the escaper everything in the report goes through"
  - "tests/unit/TaskSequence.EndToEnd.Tests.ps1: the DESIGN 12.2.1 headline test, 44 assertions over three legs"
  - "samples/workspace/TaskSequences/DEMO-M2/sequence.yaml: the runnable multi-group, multi-reboot sample"
  - "samples/workspace/TaskSequences/STD-CLIENT/sequence.yaml: DESIGN 4.1's client build, schema-valid ahead of its step types"
  - "tests/contract/LogEventVocabulary.Contract.Tests.ps1: DESIGN 4.4.2's event table pinned to Write-HDTLog's ValidateSet"
  - "the M2 exit criterion, demonstrated twice: automated over fakes and live on disk"
affects: [04-imaging, 05-bootimage, 07-apps-fullos, 09-console]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "The headline test builds every service double ONCE and shares them across all three legs, because that is what a machine is"
    - "A leg after a reboot is driven exactly as Start-HDTResume.ps1 drives it: boot log context, reconcile, then the loop"
    - "The exact ordered operation list is filtered to the services whose calls are side effects on a machine"
    - "A sample file's text is seeded into the fake filesystem, so the sample and the test cannot drift"
    - "A documentation contract test: the design's own table is parsed and pinned to the engine's ValidateSet"

key-files:
  created:
    - src/Hephaestus/Public/ConvertTo-HDTReport.ps1
    - src/Hephaestus/Private/ConvertTo-HDTHtmlText.ps1
    - tests/unit/TaskSequence.EndToEnd.Tests.ps1
    - tests/unit/ConvertTo-HDTReport.Tests.ps1
    - tests/unit/ConvertTo-HDTHtmlText.Tests.ps1
    - tests/contract/LogEventVocabulary.Contract.Tests.ps1
    - samples/workspace/TaskSequences/DEMO-M2/sequence.yaml
    - samples/workspace/TaskSequences/STD-CLIENT/sequence.yaml
    - samples/workspace/Scripts/Set-CorpBaseline.ps1
  modified:
    - src/Hephaestus/Payload/Start-HDTResume.ps1
    - src/Hephaestus/Public/New-HDTRunState.ps1
    - src/Hephaestus/Hephaestus.psd1
    - tests/contract/SequenceSchema.Contract.Tests.ps1
    - tests/unit/StartHDTResumePayload.Tests.ps1
    - tests/unit/New-HDTRunState.Tests.ps1
    - docs/DESIGN.md
    - docs/ROADMAP.md
    - .planning/ROADMAP.md
    - README.md
    - samples/README.md

key-decisions:
  - "The headline assertion is filtered to RegistryService, LsaService, PowerService, ProcessService and ScriptInvoker: an unfiltered journal is thousands of log writes and breaks on every added log line"
  - "Legs 2 and 3 go through Invoke-HDTBootReconciliation rather than being hand-assembled, so the test drives the code path a real boot does"
  - "The log directory moves with the phase and the test carries the master log forward, because DESIGN 4.4.1 says the history follows the deployment"
  - "The report reads only status, leg and the step records from -State; the computer name comes from the JSONL or an explicit parameter, never from the variable map, which may carry a credential"
  - "The live demonstration keeps power, registry and LSA fake: a demonstration may write files and run cmd.exe, and may not reboot the developer's machine"

patterns-established:
  - "Read the artifact a human reads: three defects were found by looking at the rendered report, not by running tests"
  - "A documentation claim that says 'a test asserts this' gets a test that asserts it"

# Metrics
duration: 63min
completed: 2026-08-13
---

# Phase 03 Plan 05: The M2 Headline Test, the Report and the Exit Demonstration Summary

**A multi-group sequence with two reboots runs to completion in three seconds under Pester against fakes, asserting the exact ordered list of the 31 operations it would have performed on a machine — plus `ConvertTo-HDTReport`, the two samples, and the same sequence run live with its report opened in a browser.**

## Performance

- **Duration:** 63 min
- **Started:** 2026-08-13T09:53Z (local 09:53)
- **Completed:** 2026-08-13T10:56Z
- **Tasks:** 3
- **Files created/modified:** 20

## Accomplishments

- **ROADMAP M2's exit criterion is met by an automated test.** `tests/unit/TaskSequence.EndToEnd.Tests.ps1` — 44 assertions, ~3.0 s under pwsh, ~3.9 s under 5.1 — runs the `DEMO-M2` sample across three legs and two reboots against one shared set of service doubles.
- **The exact ordered operation list is asserted**, 31 entries with a comment per line. It is the specification of what HDT does to a machine; a future refactor that changes it announces itself as a diff.
- **`ConvertTo-HDTReport`** renders the JSONL to one self-contained HTML file: inline CSS, no script, no CDN, no network. It survives a truncated final line — the normal state of a log from a machine that died — by counting the unparseable lines and reporting them in the report.
- **The M2 exit criterion is demonstrated twice**, the standard 02-03 set for M1: once as the automated test over fakes, once live at `C:\HDTLab\scratch\m2demo` against the real filesystem, clock, process service and script invoker, with the report opened in a browser.
- **Four real defects found and fixed**, each with a failing test first. Three of them were found by *reading the report a technician would read*.
- **The design says what the code does**, including the three corrections DESIGN 4.1 needed and the two limitations M2 ships with — and DESIGN 4.4.2's "controlled vocabulary" is now pinned to the engine by a contract test rather than by memory.

## Task Commits

1. **Task 1: ConvertTo-HDTReport** — `442ce9a` (test) → `10b67a0` (feat)
2. **Task 2: the headline test and the samples** — `a8adca0` (test); the engine defect it exposed: `11f7f44` (fix)
3. **Task 3: samples, docs and the live demonstration** — `ef78c9b` (fix, the three defects the live run exposed) → `51e11cf` (docs)

## The headline test

### Structure

`BeforeAll` builds **one machine's worth of doubles** — filesystem, clock, registry, LSA, power, process, script invoker, CIM, environment — and attaches the shared journal **last**, after every seed, so its first entry is the first thing the engine did. The sequence text is read off `samples/workspace/TaskSequences/DEMO-M2/sequence.yaml` and seeded into the fake filesystem, so the sample an administrator copies and the sequence under test cannot drift.

Then three legs:

| Leg | Phase | Log path | Driven by | Ends |
|---|---|---|---|---|
| 1 | WinPE | `X:\HDT\Logs` | a fresh `New-HDTRunState` | `RebootPending` at step 4 |
| 2 | FullOS | `C:\HDT\Logs` | `Invoke-HDTBootReconciliation` over the checkpointed `state.json` | `RebootPending` at step 7 |
| 3 | FullOS | `C:\HDT\Logs` | the same | `Succeeded` |

The state goes between legs **through the file**, and each resumed leg begins the way a real one does: a boot log context, then the reconcile, then the loop with the state the reconcile handed back — the same order `Start-HDTResume.ps1` uses. The log directory moves with the phase (DESIGN 4.4.1) and the test carries `HDT.jsonl`, `HDT.log`, `status.json` and `state.json` forward at the transition, which is the mirror DESIGN 4.4.1 describes and which phase 04 will own.

### The exact ordered operation list

Filtered to the services whose calls are **side effects on a machine**:

```
# leg 1, in WinPE: Preinstall runs, the first Restart arms
RegistryService.SetValue      # Winlogon AutoAdminLogon = 1
RegistryService.SetValue      # Winlogon DefaultUserName = Administrator
RegistryService.SetValue      # Winlogon DefaultDomainName (empty: a workgroup machine mid-build)
RegistryService.SetValue      # Winlogon AutoLogonCount = 2, the legs still to come
RegistryService.RemoveValue   # any registry DefaultPassword, unconditionally and defensively
LsaService.SetSecret          # the per-deployment password, as an LSA secret (DESIGN 4.5.2)
RegistryService.SetValue      # RunOnce\HDTResume
PowerService.Restart
# leg 2, in the full OS: the installer, then the second Restart
ProcessService.Start          # cmd.exe /c echo HDT demo installer
RegistryService.SetValue      # AutoAdminLogon
RegistryService.SetValue      # DefaultUserName
RegistryService.SetValue      # DefaultDomainName
RegistryService.SetValue      # AutoLogonCount = 1, the last leg
RegistryService.RemoveValue   # the registry DefaultPassword again
LsaService.SetSecret          # the SAME password: one machine, one secret per run
RegistryService.SetValue      # RunOnce\HDTResume, re-registered every leg
PowerService.Restart
# leg 3: the user script, then the DESIGN 4.5.3 teardown
ScriptInvoker.Invoke          # Scripts\Set-CorpBaseline.ps1
RegistryService.GetValue      # AutoAdminLogon - present
RegistryService.RemoveValue
RegistryService.GetValue      # DefaultUserName - present
RegistryService.RemoveValue
RegistryService.GetValue      # DefaultDomainName - present
RegistryService.RemoveValue
RegistryService.GetValue      # DefaultPassword - ABSENT, so nothing to remove
RegistryService.GetValue      # AutoLogonCount - present
RegistryService.RemoveValue
LsaService.GetSecret          # the secret itself, never behind an earlier item's failure
LsaService.RemoveSecret
RegistryService.GetValue      # RunOnce\HDTResume
RegistryService.RemoveValue
```

That list was **derived from the design before it was run** and matched the engine on the first execution.

Alongside it: the filesystem is asserted separately (11 `state.json` writes in leg 1, 20 across legs 2 and 3, and a `Running` checkpoint recorded for every step that ran), every step is accounted for exactly once in the state document, the JSONL `seq` runs 1..N with no gap and no repeat across all three legs, `Get-HDTAutoLogonArtifact` is empty at the end, the deployment password appears nowhere in the log or the report, and `Test-Path` is false for every path the run "wrote".

## Test counts

| Engine | Whole suite | The headline test alone |
|---|---|---|
| pwsh 7.5.8 | **2838 passed, 0 failed, 24 skipped**; lint 0 diagnostics across 201 files; selfcheck 4/4 | 44 passed, **3.02 s** |
| Windows PowerShell 5.1.26100.8655 | **2752 passed, 0 failed, 110 skipped** | 44 passed, **3.88 s** |

Three seconds is itself part of the claim, and the test asserts it: `DEMO-M2` configures five seconds of retry backoff and two machine restarts, so a run that waited on anything real could not finish that fast. (`build.ps1 -Task ci` under 5.1 still fails at `lint` on this machine for the reason documented in phase 01 — PSScriptAnalyzer is not importable by that edition — so the 5.1 leg is `-Task test`, as it has been since M0.)

## ROADMAP M2 "Tests first" — every bullet mapped

| ROADMAP M2 bullet | Where it is proven |
|---|---|
| the DESIGN 12.2.1 target: a full sequence against fakes asserting the exact ordered operation list | `tests/unit/TaskSequence.EndToEnd.Tests.ps1` — *'performed exactly these operations, in this order'* (03-05 task 2) |
| conditions skipping groups | `Invoke-HDTTaskSequence.Ordering.Tests.ps1` (03-04 task 1); end to end as *'skipped both Server Only steps, naming the group'* |
| `continueOnError` semantics | `Invoke-HDTTaskSequence.Failure.Tests.ps1` (03-04 task 1); end to end as *'tolerated Optional Task and carried on'* |
| retry / backoff | `Invoke-HDTTaskSequence.Retry.Tests.ps1` (03-04 task 2); end to end as *'retried Flaky Preflight once and succeeded on the second attempt'* (attempt = 2, asserted from the state) |
| a simulated reboot mid-sequence resuming at the right index | `Invoke-HDTTaskSequence.Resume.Tests.ps1` (03-04 task 3); end to end as *'resumed the second leg at Record Stage'* / *'resumed the third leg at Corp Baseline'* |
| an interrupted non-resumable step failing rather than re-running | `Invoke-HDTTaskSequence.Resume.Tests.ps1`, context *'an interrupted step'* (03-04 task 3) |
| the teardown checklist empty after success **and** after failure | `Invoke-HDTTaskSequence.Teardown.Tests.ps1` (03-04 task 3); end to end as *'leaves no autologon artifact'* |
| …after an **abandoned** run and one with **no state document** | `Invoke-HDTBootReconciliation.Tests.ps1` (03-03 task 4) |
| a different password every run | `New-HDTDeploymentPassword.Tests.ps1` (03-03 task 2) |
| `AutoLogonCount` matching the remaining legs | `Set-HDTAutoLogon.Tests.ps1` (03-03 task 3); end to end as the `AutoLogonCount = 2` then `= 1` pair in the operation list |
| arming idempotent across repeated restarts | `Set-HDTAutoLogon.Tests.ps1` (03-03 task 3) |
| the spike: LSA secret + `AutoLogonCount` on a real build | `.planning/SPIKES.md` entry S8, and DESIGN 4.5.2 (03-03 task 1) |
| structured JSONL logging + `ConvertTo-HDTReport` | `Write-HDTLog.Tests.ps1` (03-01), `ConvertTo-HDTReport.Tests.ps1` + `ConvertTo-HDTHtmlText.Tests.ps1` (03-05 task 1) |

## The live M2 exit demonstration

Run from `C:\HDTLab\scratch\Invoke-M2Demo.ps1` (a scratch area — **not committed**), three legs, with the **real** `IFileSystem`, `IClock`, `IProcessService` and `IScriptInvoker` and **fake** power, registry and LSA. The script refuses to start if a staged unattend exists anywhere the teardown looks, because the filesystem is the real one.

```
leg 1: RebootPending
leg 2: RebootPending
leg 3: Succeeded
```

### The report's step table

| # | Group | Name | Type | Status | Attempts | Duration | Exit |
|---|---|---|---|---|---|---|---|
| 1 | Preinstall | Announce | NoOp | Completed | 1 | 11 ms | 0 |
| 2 | Preinstall | Record Stage | SetVariable | Completed | 1 | 14 ms | 0 |
| 3 | Preinstall | Flaky Preflight | NoOp | Completed | **2** | 4 ms | 0 |
| 4 | Preinstall | Reboot Into Install | Restart | Completed | 1 | 7 ms | 0 |
| 5 | Install | Record Stage | SetVariable | Completed | 1 | 2 ms | 0 |
| 6 | Install | Run Installer | CommandLine | Completed | 1 | 89 ms | 0 |
| 7 | Install | Reboot After Install | Restart | Completed | 1 | 5 ms | 0 |
| 8 | State Restore | Corp Baseline | PowerShell | Completed | 1 | 37 ms | 0 |
| 9 | State Restore | WinPE Only Task | NoOp | Skipped | 0 | | |
| 10 | State Restore | Optional Task | NoOp | Failed | 1 | 6 ms | 0 |
| 11 | State Restore | Finish | NoOp | Completed | 1 | 3 ms | 0 |
| 12 | Server Only | Install Roles Placeholder | NoOp | Skipped | 0 | | |
| 13 | Server Only | Configure Roles Placeholder | NoOp | Skipped | 0 | | |

Header: run id `demo-20260813-104041`, sequence `DEMO-M2`, computer `LAP-AMMSO01`, phases `WinPE, FullOS`, duration `6.0 s`, outcome **Succeeded**. Summary: 9 completed, 1 failed, 3 skipped, 13 total, with step 10 called out. (Read back out of the rendered file, not out of the run object.)

### On disk

```
Logs\HDT.jsonl                                    16907   50 records, seq 1..50 contiguous
Logs\HDT.log                                       8780
Logs\status.json                                    217
Logs\Steps\001-Announce.log                         463
Logs\Steps\002-Record-Stage.log                     517
Logs\Steps\003-Flaky-Preflight.log                  980
Logs\Steps\004-Reboot-Into-Install.log              510
Logs\Steps\005-Record-Stage.log                     514
Logs\Steps\006-Run-Installer.log                    885
Logs\Steps\007-Reboot-After-Install.log             511
Logs\Steps\008-Corp-Baseline.log                    735
Logs\Steps\009-WinPE-Only-Task.log                  210
Logs\Steps\010-Optional-Task.log                    682
Logs\Steps\011-Finish.log                           454
Logs\Steps\012-Install-Roles-Placeholder.log        207
Logs\Steps\013-Configure-Roles-Placeholder.log      207
report.html                                       20023
state.json                                         6725
workspace\...                                             the samples, copied
```

DESIGN 4.4's "the directory listing itself tells you the sequence", for real.

Verified on the artifacts themselves:

- **UTF-8 with no BOM.** First three bytes: `HDT.jsonl` `123,34,116` (`{"t`), `HDT.log` `60,33,91` (`<![`), `report.html` `60,33,68` (`<!D`), `state.json` and `status.json` `123,13,10`.
- **`state.json` parses:** `status=Succeeded`, `leg=3`, `deploymentPassword=` (empty — torn down).
- **`status.json` parses** and reports `Succeeded`.
- **The transcript was captured for real.** `Steps\008-Corp-Baseline.log` carries `<![LOG[applying corporate baseline to LAP-AMMSO01]LOG]!>` with `component="PowerShell"` and `file="Scripts\Set-CorpBaseline.ps1"` — DESIGN 4.4.4's `Write-Host` capture, proven by a real script actually running.
- **`report.html` contains zero `http://`/`https://` references and zero `<script` tags**, and was opened in a browser.
- **The machine is untouched.** `HKLM\...\Winlogon` has no `AutoAdminLogon`, no `AutoLogonCount` and no `DefaultUserName`; `RunOnce` has no `HDTResume`; the only two restarts were recorded by the fake power service.

## Defects found and fixed

**All four were found by this plan's work, not by the tests it was told to write.** Three came from looking at the rendered report.

### 1. `Start-HDTResume.ps1` restarted the JSONL `seq` at every boot — `11f7f44`

The boot log context that the reconcile writes its `reboot.resume` record through was built with no `-Seq`, so it reissued `1, 2, …` in the middle of a stream that had already reached several hundred; and the run log was then seeded from `$state.seq`, reissuing the number `reboot.resume` had just taken. DESIGN 4.4.2 says `seq` survives reboots — on a real machine it did not. Found by writing the headline test's leg driver *against the payload*: the driver could only keep `seq` continuous by doing something the payload did not do. Fixed by seeding the boot context from the state document (read-only, best-effort, before the reconcile acts) and continuing the run context from `$bootLog.Seq`.

### 2. The state document's group array was empty on every real run — `ef78c9b`

`New-HDTRunState` read `Group` off a flattened step; `Import-HDTSequenceDocument`'s flattener emits `GroupPath`. Only hand-written test dictionaries ever said `Group`, which is exactly why no test caught it. `state.schema.json` promises "the group path this step sits under" and the report renders a Group column from it — both were blank. Found by reading the report's empty Group column. The new test builds a state from a **real imported sequence** rather than from a dictionary.

### 3. The report left every `Restart` step reading `Running` — `ef78c9b`

A `Restart` step logs `step.start` and then the machine goes down: there is no `step.complete` in the stream, ever. Reading status from the log alone left both reboot steps `Running` in a finished deployment's report. The state document now wins on status, with `Pending` the one value that means "the document knows nothing".

### 4. `-Timestamp` threw under `Set-StrictMode` — `ef78c9b`

The binder converts a bound `[System.Nullable[datetime]]` to a plain `[datetime]`, so `$Timestamp.Value` is a property that does not exist. The first live run died on it — no unit test had passed the parameter.

## Files created/modified

- `src/Hephaestus/Public/ConvertTo-HDTReport.ps1` — the report renderer (~600 lines with its help)
- `src/Hephaestus/Private/ConvertTo-HDTHtmlText.ps1` — escape once, ampersand first
- `tests/unit/TaskSequence.EndToEnd.Tests.ps1` — the headline test, 44 assertions
- `tests/unit/ConvertTo-HDTReport.Tests.ps1`, `tests/unit/ConvertTo-HDTHtmlText.Tests.ps1` — 34 + 10
- `tests/contract/LogEventVocabulary.Contract.Tests.ps1` — DESIGN 4.4.2's table pinned to the `ValidateSet`
- `tests/contract/SequenceSchema.Contract.Tests.ps1` — both samples now validated by the schema *and* the engine validator
- `samples/workspace/TaskSequences/DEMO-M2/sequence.yaml` — the runnable sample
- `samples/workspace/TaskSequences/STD-CLIENT/sequence.yaml` — DESIGN 4.1's build, valid ahead of its step types
- `samples/workspace/Scripts/Set-CorpBaseline.ps1` — a user script, deliberately unprefixed
- `src/Hephaestus/Payload/Start-HDTResume.ps1`, `src/Hephaestus/Public/New-HDTRunState.ps1` — the fixes above
- `docs/DESIGN.md`, `docs/ROADMAP.md`, `.planning/ROADMAP.md`, `README.md`, `samples/README.md`

## Documentation edits

**`docs/DESIGN.md`** — five edits, one more than the plan listed:

1. **4.1** — the State Restore condition is now `'"%_HDTPhase%" == "FullOS"'`: a single-quoted YAML scalar (the printed line was not valid YAML at all) comparing against a value `_HDTPhase` actually takes (`"OS"` never matched anything).
2. **4.1, additional** — the example's variables are `HDT`-prefixed (`HDTOSImage`, `HDTDiskLayout`), which `schemas/sequence.schema.json` enforces and 03-02 recorded as still outstanding. A three-line note now names all three corrections and points at the `STD-CLIENT` sample.
3. **4.2** — the discovery convention as implemented: `Invoke-HDT<Type>Step` required, `Test-HDT<Type>StepApplicable` and `Get-HDT<Type>StepDescription` optional, ambiguity across two modules refused, and the closed `Completed | Failed | RebootRequested` result contract.
4. **4.3** — the two limitations: `timeoutMinutes` is not pre-emptive, and `PauseOnError` returns with the state loaded rather than opening a prompt.
5. **4.4.2** — **all thirteen** event names as a table with when each is written, `reboot.teardown` and `message` included, plus what the report is and the no-BOM rule. 4.5.2's spike correction from 03-03 was confirmed already present.

**`docs/ROADMAP.md`** — M2's exit criterion marked met, naming both demonstrations and stating the two limitations and the one thing M2 does not ship; M6 gains **`SetAdminPassword`**, DESIGN 4.5.3's final Administrator password policy, with its own "Tests first" list.

**`README.md`** — a *Task sequences* section: what a `sequence.yaml` looks like, the five M2 step types with the `command:` double-wrap trap called out, the condition grammar and its single-quoting, how to run one against fakes, and how to read the report. **`samples/README.md`** — both sequences described, with the exact commands (run before they were written down). The machine-specific serial `1ABC234` carried forward from `02-VERIFICATION.md` is gone from both files, replaced by `FIXTURE-SERIAL-0001`.

## Deviations from plan

**1. [Rule 3 – Blocking] Legs 2 and 3 go through `Invoke-HDTBootReconciliation`, and the log directory moves with the phase**

- **Found during:** Task 2
- **Issue:** The plan's sketch hand-assembled each resumed leg and put legs 2–3 on `C:\HDT\Logs`. Hand-assembling would have skipped the code path a real boot takes — and it was precisely by driving the payload's path that defect 1 was found. Two log directories with nothing joining them would also have split the JSONL, leaving the `seq` assertion and the report covering only the last two legs.
- **Fix:** each resumed leg builds a boot log context, calls the reconcile, and then runs the loop with the state it returns; the test carries `HDT.jsonl`, `HDT.log`, `status.json` and `state.json` from `X:\HDT\Logs` to `C:\HDT\Logs` at the phase transition, which is the mirror DESIGN 4.4.1 describes. The engine does not do that carry-forward itself — the phase that formats a volume owns it (phase 04) — and the test says so in a comment.
- **Committed in:** `a8adca0`

**2. [Rule 1 – Bug] `Start-HDTResume.ps1`'s `seq` restart** — see *Defects* above. `11f7f44`.

**3. [Rule 1 – Bug] Three defects the live demonstration exposed** — see *Defects* above. `ef78c9b`.

**4. [Rule 2 – Missing critical functionality] `ConvertTo-HDTReport -ComputerName`**

- **Found during:** Task 3
- **Issue:** the live run's header read `(not resolved)`, because the demonstration's log carries no `var.resolve` record for `HDTComputerName` — the gather phase ran in phase 02, not here.
- **Fix:** an explicit optional parameter. It is deliberately **not** read from `-State.variable`: a variable map may carry a domain-join password or a share credential, and the rule that the report reads only `status`, `leg` and the step records from the state is what keeps those out of an emailed file.
- **Committed in:** `ef78c9b`

**5. [Rule 2 – Missing critical functionality] `tests/contract/LogEventVocabulary.Contract.Tests.ps1`**

- **Found during:** Task 3
- **Issue:** the DESIGN 4.4.2 text this plan wrote claims "the list and the parameter are asserted against each other by a test". No such test existed, and this whole carried debt exists *because* the two lists drifted silently.
- **Fix:** a contract test that parses the event table out of `docs/DESIGN.md` and pins it to `Write-HDTLog`'s `ValidateSet` in both directions. It was proven non-vacuous by temporarily deleting the `reboot.teardown` row from the document and watching it go red with that name in the failure message, then restoring the file.
- **Committed in:** `51e11cf`

**6. Both sample sequences were written in task 2, not split across tasks 2 and 3** — the plan explicitly allowed either; both contract rows therefore went green in task 2. `STD-CLIENT`'s prose documentation was still written in task 3.

**Total deviations:** 6 (4 bug/missing-functionality auto-fixes, 1 structural improvement to the test, 1 sequencing choice the plan offered). **Impact:** no scope creep; four of the six are defect fixes in code the plan was written to exercise.

## Issues encountered

- **Two of the headline test's first-run failures were test bugs, not engine bugs.** `$decision.State` is the *same object* the loop then mutates, so reading "where did the leg resume?" after the run reported where it ended. Both snapshots are now taken before `Invoke-HDTTaskSequence` is called, with a comment saying why.
- **One assertion passed standalone and failed in the full suite:** iterating *every* `WriteAllText` in the journal and reading `$document.step` hit the `status.json` heartbeats, which have no `step` array — harmless until the suite's stricter mode turned it into a `PropertyNotFoundException`. The filter is now explicit about which two paths are state documents.
- **`$computerName` and the new `-ComputerName` parameter are the same variable** in PowerShell's case-insensitive scope, so assigning `''` to the local tripped the parameter's `ValidateNotNullOrEmpty`. The local is now `$computerText`.
- **One new test passed on first run** — *'shows the group path of every step'*. It was written expecting red, and the red turned out to be one layer down in `New-HDTRunState` (defect 2); the renderer was already correct. It is kept as a regression guard and is honest about being one.

## What M2 does not cover

- **The final Administrator password policy** (DESIGN 4.5.3's last item) — now listed under **M6** with its own tests-first block. A machine HDT builds is left holding the per-deployment secret. That is safe (the state document that knew it has been deleted, and the LSA secret is gone) but it is not finished.
- **`timeoutMinutes` is not pre-emptive**, and it has still never bounded a real long-running process.
- **`PauseOnError` returns rather than prompting** — the prompt belongs to `Start-HDTDeployment` in phase 05.
- **`New-HDTPowerService` has never been executed**, and whether WinPE needs `wpeutil reboot` rather than `shutdown.exe` is a **phase 05** question. Every reboot in this phase was recorded by a fake.
- **`Start-HDTResume.ps1` has still never been executed.** The `seq` fix in it is asserted by AST inspection and by the headline test driving the same shape by hand; running the payload for real needs a machine to reboot, which is phase 04's integration layer.
- **`powershell-yaml` is a hard runtime dependency and nothing yet asserts it will be inside the WinPE boot image** — the third carried-forward item from `02-VERIFICATION.md`, and phase 03 has made it worse: the engine now reads `sequence.yaml` in WinPE too. **Phase 05** must stage the module into the boot image and prove it imports there.
- **Domain join is still unproven end to end** (PROJECT.md's isolated lab); `STD-CLIENT` ships with the step commented out and a workgroup default.

## Next phase readiness

Phase 04 (M3 — imaging) can start. The execution model it plugs into is proven end to end and has a regression test that will announce any change to what HDT does to a machine. Two things phase 04 owns that this plan touched: the **log carry-forward at the phase transition** (the test performs it today), and the **state mirror to the target volume** once one is formatted.

Nothing under `C:\HDTLab` is committed; `git status` is clean.

---
*Phase: 03-sequence-engine, plan 05*
*Completed: 2026-08-13*

## Self-Check: PASSED

Every file this summary names exists on disk, every commit hash it names exists
in `git log`, and both artifact minimums from the plan's `must_haves` are met:
`tests/unit/TaskSequence.EndToEnd.Tests.ps1` is 632 lines (min 220) and
`src/Hephaestus/Public/ConvertTo-HDTReport.ps1` is 623 (min 160). `git ls-files`
matches nothing under `C:\HDTLab` or `m2demo`. The demonstration's file sizes,
the report's summary counts and the step table above were read back out of the
artifacts on disk rather than out of the run object.
