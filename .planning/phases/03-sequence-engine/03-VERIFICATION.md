---
phase: 03-sequence-engine
verified: 2026-08-13T12:20:00Z
status: gaps_found
score: 9/10 must-haves verified
re_verification: null
human_verification: []
verifier_ran:
  pwsh: "7.5.8 - 2838 passed / 0 failed / 24 skipped"
  windows_powershell: "5.1.26100.8655 - 2752 passed / 0 failed / 110 skipped"
  lint: "0 diagnostics across 201 files"
  selfcheck: "4 of 4"
  independent_e2e: "three legs reproduced outside the suite; report rendered and read"
  mutation_probes: 4
gaps:
  - truth: "Reboot-resume works on a real machine"
    status: failed
    reason: >
      Start-HDTResume.ps1 - the RunOnce payload that IS the resume mechanism -
      builds the sequence path under a 'Sequences' directory. DESIGN 2.1,
      README.md, samples/README.md and the whole samples tree use
      'TaskSequences'. The one file in the repository that has never been
      executed is the one that gets the path wrong, and no test asserts it.
    artifacts:
      - path: "src/Hephaestus/Payload/Start-HDTResume.ps1"
        issue: "line 163 uses 'Sequences'; canonical layout is 'TaskSequences' (DESIGN 2.1 line 101)"
      - path: "src/Hephaestus/Payload/Start-HDTResume.ps1"
        issue: "line 50 of the comment-based help repeats the wrong directory"
      - path: "src/Hephaestus/Public/Import-HDTSequenceDocument.ps1"
        issue: "line 102 user-facing error says 'the workspace Sequences directory (DESIGN 2.1)'"
      - path: "tests/unit/StartHDTResumePayload.Tests.ps1"
        issue: "21 AST assertions, none covering the sequence path default"
    missing:
      - "Correct the directory to TaskSequences in all three places"
      - "A failing test first: assert the computed default sequence path against the DESIGN 2.1 layout"
      - "Consider deriving the literal from one place rather than three"
observations:
  - "Schema contract suites (Sequence 38, Rules 27, State 16) skip entirely under 5.1 because Test-Json is PS6+; pre-existing from M1. samples STD-CLIENT is schema-gated on the pwsh 7 leg only. The hand-written validators that run in WinPE do execute on both legs."
  - "Invoke-HDTBootReconciliation clears autologon and deletes state.json but has no SupportsShouldProcess, unlike Set-/Clear-HDTAutoLogon and Save-HDTRunState. -WhatIf does not reach through it. PROJECT constraint 5."
  - "New-HDTPowerService has never been executed (its contract row is permanently skipped) and no real reboot has happened. It is branch-free, so it qualifies for the untested-adapter exception. timeoutMinutes has never bounded a real process."
  - "The report Computer field reads (not resolved) when the name is in state.variable HDTComputerName but no var.resolve record exists for it - the normal case, since DESIGN 3.1 source 1 resolves it before the sequence starts. Cosmetic; -ComputerName is available."
  - "DESIGN 4.1's example is duplicated into tests/fixtures/sequences/valid-design-example.yaml rather than read from docs/DESIGN.md, so the two can drift. Today they agree - the DESIGN block imports cleanly through the engine."
  - "The exit demonstration DEMO-M2 uses four top-level groups, not nested ones. Three-level nesting is thoroughly proven in the import suite. Noted so the E2E is not later read as proof of nesting."
  - "powershell-yaml is now a WinPE runtime dependency because the engine reads sequence.yaml in WinPE, and nothing yet proves it imports there. Third carried-forward item from 02-VERIFICATION.md; phase 05 owns it."
  - ".planning/REQUIREMENTS.md does not exist, so requirement-coverage mapping is not applicable to this phase."
---

# Phase 03: Sequence Engine - Verification Report

**Phase Goal:** sequencing, conditions, retry, reboot-resume and the autologon
lifecycle - all correct against fakes before any step does destructive work.

**Exit (docs/ROADMAP.md, M2):** a multi-group sequence with reboots runs to
completion in a Pester run, with a readable report, having touched nothing real.

**Verified:** 2026-08-13
**Status:** gaps_found
**Re-verification:** No - initial verification

**Method:** goal-backward. Nothing in the five SUMMARY files was taken on trust.
Both suites were run here, the engine was driven by hand outside its own tests,
git history was scanned commit by commit, the rendered report was read rather
than asserted, and the suite itself was mutation-tested to prove it is capable of
failing.

**Headline:** the exit criterion is met, and I reproduced it independently. One
real defect exists in shipped code that the phase's own tests cannot see, in the
single file the executors correctly declared unverified.

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|---|---|---|
| 1 | A multi-group sequence with reboots runs to completion in a Pester run | VERIFIED | `tests/unit/TaskSequence.EndToEnd.Tests.ps1` passes under both engines. I also drove DEMO-M2 independently in my own script: leg 1 `RebootPending` -> reconcile `Resume` -> leg 2 `RebootPending` -> reconcile `Resume` -> leg 3 `Succeeded`, final `state.leg = 3` |
| 2 | It produces a readable report | VERIFIED | Rendered `report.html` (19,321 bytes) myself and read its text. Six sections; the Steps table carries #, Group, Name, Type, Status, Attempts, Duration, Exit code, Message for all 13 steps; the Group column is populated (Preinstall / Install / State Restore / Server Only); both reboots and the teardown appear in the Legs table |
| 3 | It touched nothing real | VERIFIED | Fakes for registry, LSA, power, process and invoker. `Test-Path` on `C:\HDT\Logs`, `X:\HDT\Logs` and `C:\ws\TaskSequences` all false; real `HKLM\...\RunOnce` has no `HDTResume`; real Winlogon has no `AutoLogonCount`. The whole run takes ~1.1 s against 5 s of configured backoff and two restarts |
| 4 | TDD was followed | VERIFIED | 25 `test(03-xx)` -> `feat(03-xx)` pairs in strict order across `219ec65..HEAD`. Automated scan of all 15 `test` commits for production code: exactly one hit, `80088cb`, a comment-only edit |
| 5 | Suite green under pwsh 7 AND powershell.exe 5.1 | VERIFIED | I ran both. pwsh 7.5.8: **2838 / 0 / 24**. Windows PowerShell 5.1.26100.8655: **2752 / 0 / 110** |
| 6 | The Verb-HDTNoun naming contract test exists and passes | VERIFIED | `tests/contract/Naming.Contract.Tests.ps1`, green on both legs, carrying anti-vacuity guards. Independent check: 122 functions across 200 files, 0 failing `^[A-Z][a-z]+-HDT[A-Z]`, 0 unapproved verbs |
| 7 | PSScriptAnalyzer is clean | VERIFIED | `0 diagnostics across 201 file(s)`. `ExcludeRules = @()`, `Severity = Error, Warning`, `PSUseCompatibleSyntax` targeting 5.1 and 7.0 |
| 8 | No engine code touches hardware / filesystem / registry directly | VERIFIED | My own AST scan of all `src/Hephaestus` for 40 forbidden commands: 17 hits, every one inside a legitimate adapter or the module loader |
| 9 | The autologon lifecycle is correct, including all four teardown scenarios | VERIFIED | Success and failure in `Invoke-HDTTaskSequence.Teardown.Tests.ps1`; abandoned and missing-state in `Invoke-HDTBootReconciliation.Tests.ps1`. Password uniqueness, `AutoLogonCount` = remaining legs, and arming idempotence all asserted |
| 10 | Reboot-resume works on a real machine | **FAILED** | `Start-HDTResume.ps1` looks for the sequence under `Sequences\`; the canonical layout is `TaskSequences\`. No test covers it |

**Score: 9/10 truths verified.**

## The Defect

`src/Hephaestus/Payload/Start-HDTResume.ps1:163`

    $sequenceFile = [System.IO.Path]::Combine($WorkspaceRoot, 'Sequences', [string] $state.sequenceId, 'sequence.yaml')

`docs/DESIGN.md:101` - the section 2.1 workspace layout - says `TaskSequences\`.
So do `README.md:133`, `samples/README.md:115`, and the sample tree itself
(`samples/workspace/TaskSequences/DEMO-M2`, `.../STD-CLIENT`). A
repository-wide search finds `'Sequences'` used as a path segment in exactly one
place: this line.

Consequences:

- On the first real reboot resume, `Import-HDTSequenceDocument` throws "the
  sequence file does not exist" unless the caller passes `-SequencePath`
  explicitly. RunOnce does not - `Set-HDTAutoLogon` writes
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HDT\Start-HDTResume.ps1`
  with no arguments.
- `Import-HDTSequenceDocument.ps1:102` puts the same wrong directory name into
  the user-facing error message, so the operator is directed to a path that does
  not exist either.

Why the suite cannot see it: `StartHDTResumePayload.Tests.ps1` has 21
assertions, all AST inspection. It proves the reconcile precedes the loop, that
no fake is named, that the boot log seeds its seq - but never the path. The
headline E2E never calls the payload; it calls `Invoke-HDTBootReconciliation`
directly with an explicit path, mirroring the payload's body but bypassing the
payload's own defaulting. The executors recorded "Start-HDTResume.ps1 has never
been executed" as unverified, which was accurate. This is what was behind it.

**Not a blocker for the M2 exit criterion**, which is explicitly scoped to a
Pester run against fakes and is met. **It is a blocker for phase 04**, which
takes the first real reboot.

## Verification Detail

### Independent reproduction of the exit criterion

I did not rely on the E2E test. I wrote my own driver, seeded the DEMO-M2 sample
into a fake filesystem, and ran three legs through `Invoke-HDTBootReconciliation`
the way `Start-HDTResume.ps1` does:

- Statuses `RebootPending` -> `RebootPending` -> `Succeeded`; final `leg = 3`.
- `HDT.jsonl`: 49 records with `seq` **1..49 contiguous, no duplicates**, across
  all three legs. This is the DESIGN 4.4.2 property that was actually false
  before `11f7f44`.
- `Get-HDTAutoLogonArtifact` at the end: **empty**.
- Final `state.json`: `deploymentPassword` is null.
- 13 numbered per-step logs written, `001-Announce.log` through
  `013-Configure-Roles-Placeholder.log`.
- `report.html`: **zero** occurrences of `http://`, `https://`, `<script` or
  `src=`.

### Report readability - read, not asserted

The Steps table places every step in its group, shows Flaky Preflight at
Attempts 2, and shows Optional Task as Failed with the run still Succeeded. Skip
reasons are full sentences: "step 9 'WinPE Only Task' declares runIn WinPE and
this leg is running in the FullOS phase" and "the group 'Server Only' is skipped:
its condition "%HDTDemoRole%" == "server" is false". The Legs table shows both
reboot.arm / reboot.resume pairs and the closing
"reboot.teardown - Autologon teardown cleared 7 artifact(s), 0 failed".

### Direct-access scan (constraint 6)

AST scan of every `.ps1` and `.psm1` under `src/Hephaestus` for 40 filesystem,
registry, CIM, process, network, clock and module commands. 17 hits across 8
files:

| File | Calls | Verdict |
|---|---|---|
| `Hephaestus.psm1` | `Get-ChildItem` x2 | Module loader dot-sourcing itself |
| `Public/New-HDTRegistryService.ps1` | `Test-Path`, `Get-ItemProperty`, `New-Item` x2, `New-ItemProperty`, `Remove-ItemProperty`, `Get-Item`, `Remove-Item` | This **is** the registry adapter |
| `Public/New-HDTCimProvider.ps1` | `Get-CimInstance` | This **is** the CIM adapter |
| `Public/New-HDTClock.ps1` | `Start-Sleep` | This **is** the clock adapter |
| `Public/New-HDTScriptInvoker.ps1` | `Test-Path` | This **is** the invoker adapter |
| `Public/Import-HDTStepModule.ps1` | `Get-ChildItem`, `Import-Module` | Step-module discovery; must enumerate a directory by nature |
| `Private/ConvertFrom-HDTYaml.ps1` | `Import-Module` | Loads powershell-yaml |
| `Payload/Start-HDTResume.ps1` | `Import-Module` | Bootstrap; runs before any DI exists |

Zero violations in the execution loop, the steps, the state document, the log or
the autologon code. Separately scanned for `[System.IO.File]::`,
`[Microsoft.Win32.Registry]::`, `[datetime]::UtcNow`, `[datetime]::Now` and
`Get-Random` outside the adapters - one hit,
`Export-HDTVariableProvenance.ps1:71`, `[datetime]::UtcNow` as an **overridable
default parameter value**. Phase 02 code, cosmetic.

`StepContract.Tests.ps1` enforces this mechanically for step files, greping each
for 14 forbidden cmdlets, driven by `-ForEach (Get-HDTStepType)` at discovery so
future step types are caught without editing the file. Its scope is
`Public/Steps` only - the loop and the autologon code are not mechanically
covered, only verified by hand here and by the injected-service architecture.

### Is the suite load-bearing? Four mutation probes

I broke the engine on purpose and confirmed the suite noticed. The working tree
was restored and confirmed clean after every probe.

| Mutation | Result |
|---|---|
| Autologon teardown never runs (the `finally` always takes the skip branch) | **17 failures** - the exact ordered operation list, the artifact checklist, the nulled password, the RunOnce removal, the state-write counts |
| `AutoLogonCount` off by one (`$RemainingLeg + 1`) | **8 failures** across `Set-HDTAutoLogon`, the reboot suite and the E2E |
| Skip-completed guard disabled on resume | 1 failure - "a leg that died after the checkpoint ... names the leg they completed on" |
| Execution loop always restarts at step 1 | **0 failures** |

The last two need reading together rather than alarm. The engine has two
independent resume mechanisms - the loop starts at `state.stepIndex`, *and* every
step is checked against its recorded status - and either alone produces the
correct observable outcome. Probe 4 is therefore an equivalent mutant, not a
coverage hole, and probe 3 shows exactly one test distinguishes the two. Defence
in depth, but only one test's worth of margin.

### TDD

Every phase 03 commit in order across `219ec65..HEAD`: 25 `test` -> `feat` pairs,
plus `docs`, `fix` and `refactor` commits. The `refactor(03-03)` fake rename
landed as its own green commit before the tests that depended on it, and
`docs(03-03)` - the S8 spike - preceded the first `feat(03-03)`, which is the
right order for a spike that decides a design question.

Automated scan of all 15 `test(...)` commits for files under
`src/Hephaestus/{Public,Private,Payload}`: **one hit**, `80088cb`, changing a
comment in `Invoke-HDTPowerShellStep.ps1` because the new contract test greps
step files for forbidden cmdlet names and the prose named `Start-Process`. That
is the contract working, not TDD breaking.

57 production functions were added in this phase. 49 are referenced by name in a
test. The other 8 - five `Get-HDT*StepDescription`,
`Test-HDTPowerShellStepApplicable`, `ConvertTo-HDTLogRecord` and
`Invoke-HDTStepAttempt` - are reached through dispatchers that the contract and
retry suites drive dynamically. Verified by reading `StepContract.Tests.ps1`,
which calls `Get-HDTStepDescription` and `Test-HDTStepApplicable` for every
enumerated type. That is coverage, not absence.

### ROADMAP M2 "Tests first" checklist

| Required | Where | Status |
|---|---|---|
| Full sequence against fakes, exact ordered operation list | `TaskSequence.EndToEnd.Tests.ps1` - 31 operations, one comment per line | met |
| Conditions skipping groups | E2E (Server Only), `Invoke-HDTTaskSequence.Ordering.Tests.ps1` | met |
| `continueOnError` semantics | E2E (Optional Task Failed, run Succeeded), Ordering suite | met |
| Retry and backoff | E2E (Flaky Preflight, attempt 2), `...Retry.Tests.ps1` | met |
| Simulated reboot resuming at the right index | E2E (leg 2 at step 5, leg 3 at step 8), `...Resume.Tests.ps1` | met |
| Interrupted non-resumable step fails rather than re-running | `...Resume.Tests.ps1`, "an interrupted step", 8 assertions | met |
| Teardown checklist empty after a successful run | `...Teardown.Tests.ps1`, E2E | met |
| Teardown checklist empty after a failed run | `...Teardown.Tests.ps1`, incl. thrown exception and unusable sequence | met |
| Teardown checklist empty after an abandoned run | `Invoke-HDTBootReconciliation.Tests.ps1`, "an abandoned run" | met |
| Teardown checklist empty with no state document | `Invoke-HDTBootReconciliation.Tests.ps1`, "no state document" | met |
| Password different on every run | `New-HDTDeploymentPassword.Tests.ps1:101` | met |
| `AutoLogonCount` matches remaining legs | `Set-HDTAutoLogon.Tests.ps1`, mutation-confirmed | met |
| Arming idempotent across repeated restarts | `Set-HDTAutoLogon.Tests.ps1:222` | met |
| Spike: LSA secret + AutoLogonCount on a supported build | `ce7a123` (S8, throwaway Gen2 VM, count observed 2 -> 1 -> 0) | met |
| Step types NoOp, SetVariable, PowerShell, CommandLine, Restart | All five, contract-enumerated | met |
| Groups, nesting, conditions | Nesting proven at unit level: `valid-nested-groups.yaml`, three levels, GroupPath ordering, runIn inheritance, sibling condition isolation. The E2E itself uses four top-level groups | met, see observations |

### Cross-engine and encoding spot-checks

- Real `New-HDTFileSystem` writes UTF-8 **with no BOM** on both engines - first
  bytes `123,34,97` after `WriteAllText`, unchanged after `AppendAllText`.
- Real `New-HDTLsaService` returns `$null` for an absent secret on both engines,
  so the 0xC0000034-as-negative-Int32 fix holds. Running the LSA contract with
  `HDT_ALLOW_LSA_TEST=1` on this elevated session took it from 12 skipped to 17
  passed / 7 skipped, with no failures.
- DESIGN section 4.1's YAML example, extracted from `docs/DESIGN.md` and imported
  through the engine: **10 steps in execution order with GroupPath populated**
  (Preinstall x2, Install x4, State Restore x4). The claimed corrections are real.
- DESIGN section 4.4.2 now tables all **thirteen** event names, and
  `LogEventVocabulary.Contract.Tests.ps1` pins the document to `Write-HDTLog`'s
  ValidateSet in both directions. The 03-01 carried debt is closed.
- All **58** exported functions have a synopsis and at least one example. The
  manifest lists all 58 explicitly; no wildcard; no `DefaultCommandPrefix`.
- `./build.ps1 -Task selfcheck`: 4 of 4 - a deliberately failing test is
  detected, a red run exits non-zero, the analyzer fires on the bait fixture.
- 23 analyzer suppressions in `src/`, all narrow and justified; 18 are
  `PSUseShouldProcessForStateChangingFunctions` on `New-*` factory functions that
  change no state, and the two on `Set-HDTAutoLogon` explain why a PSCredential
  protects nothing when `LsaStorePrivateData` takes an `LSA_UNICODE_STRING`.
- Working tree clean on `main` at `c2b0418` before and after verification.

## What This Phase Honestly Does Not Prove

Stated plainly, per PROJECT's instruction not to imply more than was tested:

- **No machine has rebooted.** The reboot is a fake recording
  `PowerService.Restart`. `New-HDTPowerService` has never executed.
- **`Start-HDTResume.ps1` has never run**, and carries the defect above.
- **`timeoutMinutes` has never bounded a real process**, and is not pre-emptive
  by design - documented in DESIGN 4.3 rather than hidden.
- **`PauseOnError` does not prompt**; it returns with the state loaded.
- **`JoinDomain` is out of scope for M2 entirely.** The isolated HDT Lab switch
  means real domain-join end-to-end remains unproven and out of scope.
- **`powershell-yaml` is now a WinPE runtime dependency** because the engine
  reads `sequence.yaml` in WinPE, and nothing yet proves it imports there.

---

_Verified: 2026-08-13_
_Verifier: Claude (gsd-verifier)_
_Both engines were run by the verifier. No figure in this report was taken from a SUMMARY._
