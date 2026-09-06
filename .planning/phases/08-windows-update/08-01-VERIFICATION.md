---
phase: 08-windows-update
verified: 2026-09-06T00:00:00Z
status: gaps_found
score: 7/10 must-haves verified
verifier: gsd-verifier (independent re-verification of the executor-authored report)
re_verification:
  previous_status: gaps_found
  previous_score: "6 of 10 exit items met (executor's own count)"
  gaps_closed: []
  gaps_remaining:
    - "A VM deploys through HDT and is patched against HDT-WSUS-01"
    - "The machine comes back running 26100.9168"
    - "More than one pass, with a reboot between, on a real machine"
    - "SPIKES.md records what the real Windows Update Agent did"
  regressions: []
  note: >-
    The previous VERIFICATION.md was written by the executing agent. This
    document is an independent re-run: the gate was executed from scratch, the
    result XML parsed directly, the module imported and run, the Hyper-V lab
    enumerated before and after, and the DNS blocker reproduced. Every executor
    claim checked came back TRUE. Two findings below are new.
gaps:
  - truth: "A VM deploys through HDT, is patched against HDT-WSUS-01, and comes back running 26100.9168"
    status: failed
    reason: >-
      The E2E was never written. tests/e2e/WindowsUpdate.E2E.Tests.ps1 does not
      exist and appears in no commit of this phase. Plan 08-01-04 Task 3 stopped
      at its own pre-flight check 4 - HDT-WSUS-01 does not resolve by name from
      this host - which the plan makes an explicit stop. The block is REAL and
      was reproduced this session, but it is a plan-level rule rather than a
      physical wall - a WSUS client addresses its server by URL and an IP-based
      URL is a supported configuration. What is missing is the user's decision.
    artifacts:
      - path: "tests/e2e/WindowsUpdate.E2E.Tests.ps1"
        issue: "Does not exist. This is the phase's milestone exit."
    missing:
      - "A decision between a DNS record for HDT-WSUS-01, an address in the E2E sequence, or a formal deferral"
      - "tests/e2e/WindowsUpdate.E2E.Tests.ps1 - deploy, patch, assert build 26100.9168"
      - "A SPIKES.md entry written from that run"
  - truth: "Remove-HDTLabVirtualMachine refuses HDT-WSUS-01 and HDT-WDS-01 even though both match HDT-*"
    status: partial
    reason: >-
      The DESTRUCTIVE path is protected - the stamp guard sits after the lookup
      and before Stop-VM, and both lab servers are correctly unstamped. But the
      guard is placed AFTER the ShouldProcess early return, so -WhatIf never
      reaches it. Run live this session, Remove-HDTLabVirtualMachine -Name
      HDT-WSUS-01 -WhatIf printed "What if - Performing the operation Stop and
      remove the HDT lab VM on target HDT-WSUS-01" and returned. A dry run that
      says the harness would remove the WSUS server contradicts the guarantee
      the stamp exists to make. No test caught it because all three stamp-guard
      tests assert AST offsets and none invokes the command.
    artifacts:
      - path: "tests/helpers/HDTTestTools/tools/Remove-HDTLabVirtualMachine.ps1"
        issue: "Stamp refusal (line 82) sits after the ShouldProcess early return (line 63), so -WhatIf bypasses it"
      - path: "tests/unit/New-HDTLabVirtualMachine.Tests.ps1"
        issue: "The three stamp-guard tests are AST-only; nothing invokes the command, so the -WhatIf hole is invisible"
    missing:
      - "Move the lookup and the Test-HDTLabVmStamped refusal above the ShouldProcess call, or repeat the refusal there"
      - "A test that INVOKES Remove-HDTLabVirtualMachine -WhatIf against an unstamped VM and asserts it throws"
human_verification:
  - test: "Decide how the E2E should address HDT-WSUS-01"
    expected: "A DNS record, an accepted address, or a formal deferral"
    why_human: "Every option is either a change to the user's lab or a departure from the plan's own rule"
---

# Phase 08-01: Windows Update — Independent Verification Report

**Phase Goal:** Build the `WindowsUpdate` step designed in `docs/DESIGN.md` 10.1,
after first raising the lab memory budget that blocked any target VM from being
created at all.

**Verified:** 2026-09-06
**Status:** gaps_found
**Re-verification:** Yes — an independent re-run of the executor-authored
`08-01-VERIFICATION.md`. Nothing below is taken from a SUMMARY.

---

## What was actually run this session

| Check | Command | Result |
|---|---|---|
| The gate | `powershell.exe -NoProfile "./build.ps1 ci"`, launched from Bash | **BUILD SUCCEEDED** on 5.1.26100.8655 — `test: 14389 passed, 0 failed, 298 skipped`; `lint: 0 diagnostics across 1175 file(s)`; `selfcheck: 4 of 4` |
| pwsh 7 pass | `pwsh -NoProfile "./build.ps1 test"`, run **sequentially**, never alongside 5.1 | `14592 passed, 8 failed, 87 skipped` — **8 pre-existing platform failures, none in phase 08** |
| Result XML | parsed `out/testResults/pester-Desktop-*.xml` directly | per-suite table below |
| The module, not the fakes | imported `src/Hephaestus/Hephaestus.psd1` and ran the real commands | `Get-HDTStepType` reports `WindowsUpdate` with `CanAdd = True`; template and description both answer |
| The lab helpers, live | imported `HDTTestTools` and ran the budget commands against the real host | `CombinedByte 34359738368` (32 GB), `AssignedByte 0`, `Counted {}`, `Ignored {HDT-WSUS-01, HDT-WDS-01}`, a 4 GB VM **accepted** |
| The E2E blocker | `Resolve-DnsName -Name 'HDT-WSUS-01' -Type A` | **"DNS name does not exist"** — reproduced; the block is real |
| Hyper-V lab | `Get-VM` enumerated before AND after every run | identical; see below |

**The 5.1 numbers match the executor's report exactly**, as do `lint 0` and
`selfcheck 4 of 4`.

### Targeted suite results, read out of the XML rather than out of a summary

| Suite | Total | Passed | Failed | Skipped |
|---|---|---|---|---|
| Naming contract (`Verb-HDTNoun`) | 6 | 6 | 0 | 0 |
| No-MDT-dependency contract | 1325 | 1325 | 0 | 0 |
| Lab memory budget contract | 8 | 8 | 0 | 0 |
| `WindowsUpdate` (all describes) | 175 | 175 | 0 | 0 |
| Full-OS-only refusal | 13 | 13 | 0 | 0 |
| `IUpdateSessionService` contract | 62 | 34 | 0 | 28 |

The 28 skips in the service contract were checked row by row and are **correct by
design**, not a hidden hole:

- `UpdateSessionService.the shape.*` — all three **PASSED** against the real adapter.
- `UpdateSessionService.the machine, through the real agent.answers GetRebootRequired` — **PASSED**. The real COM adapter reached this laptop's Windows Update Agent during the gate itself, not only in a manual probe.
- The 28 `Ignored` are the fake-only behavioural rows, skipped for the real implementation because it must not search or install, plus the fake's real-agent row.

### The pwsh 7 failures are pre-existing, and none is this phase's

| # | Test | Cause |
|---|---|---|
| 1-3 | `state.json schema contract.the fixtures.validates valid-*.json` | `Test-Json` on pwsh 7.5 rejects `/deploymentPassword` against the `false` sub-schema; 5.1's Newtonsoft-based `Test-Json` does not |
| 4-6 | the same three fixtures, "agrees with `Assert-HDTRunStateDocument`" | consequence of 1-3 |
| 7 | console: a description typed into the details pane of an imported update | WPF `RaiseEvent` behaviour on pwsh |
| 8 | `Export-HDTDeviceInventory` timestamp formatting | `ConvertTo-Json` `[datetime]` handling differs between engines |

None of the eight test files, and none of the source they cover, was touched by
phase 08 (`git diff --name-only 4ffd5cc..HEAD`). **5.1 is the gate and it is
green.** The pwsh number is recorded because the verification brief asked for it;
per `CLAUDE.md` and MEMORY that pass is deliberately off and its number is not the
gate. The two suites were never run at the same time.

---

## Goal achievement

### Observable truths

| # | Truth | Status | Evidence |
|---|---|---|---|
| 1 | A 4 GB target VM can be created while both lab servers run | VERIFIED | `Assert-HDTLabMemoryBudget -MemoryByte 4294967296` **ACCEPTED** against the live host |
| 2 | The budget byte value exists in exactly one file | VERIFIED | `34359738368` appears only in `Get-HDTLabMemoryBudget.ps1`; the other hit is an unrelated disk-size fixture. `12884901888` survives only under `.claude/worktrees/refresh/`, a separate stale checkout the contract test explicitly excludes |
| 3 | A VM the harness did not create is not counted, with no name list | VERIFIED | Live: `Ignored {HDT-WSUS-01, HDT-WDS-01}`, `Counted {}`. The rule is `Test-HDTLabVmStamped` on `Notes`; both servers have empty `Notes` |
| 4 | `Remove-HDTLabVirtualMachine` refuses both lab servers | PARTIAL | Destructive path guarded and correct. **`-WhatIf` bypasses the guard entirely** — see gaps |
| 5 | Every prose surface says 32 GB | VERIFIED | `CLAUDE.md:233`, `.planning/PROJECT.md:306`, `build.ps1:1277`, `tests/e2e/README.md:110`, `docs/ROADMAP.md:866`, `tests/helpers/README.md:874`. No surviving "12 GB" except the deliberate history line at `PROJECT.md:321` |
| 6 | A step can be handed a fake update session and never touch COM | VERIFIED | `Invoke-HDTWindowsUpdateStep.ps1` contains **zero** direct `New-Object -ComObject`, registry, CIM, filesystem or `Start-Process` calls. It reaches the machine only through `$Context.Service.Clock` and `$Context.Service.GetRequired('UpdateSession', 'WindowsUpdate')` at line 225 |
| 7 | The same contract assertions run over the fake and the real adapter | VERIFIED | Row-level XML check above; the real leg's shape rows and its live `GetRebootRequired` all passed on the gate |
| 8 | The step loops until nothing is applicable or `maxPasses` is hit, bounded ACROSS reboot legs | VERIFIED against fakes | `while ($pass -lt $maxPasses)`; counter persisted in `$Context.Variable[$passVariable]` and re-read on resume (lines 274-296); `New-HDTStepResult -Status RebootRequested -Reenter` at line 631; `maxPasses -lt 1` refused before anything is searched |
| 9 | The step is refused in a WinPE group at authoring time, by walking a set | VERIFIED | `Import-HDTSequenceDocument.ps1:317` calls `Test-HDTStepPhaseForbidden`, and the importer contains **0** occurrences of the literal `WindowsUpdate` |
| 10 | A VM deploys, is patched against `HDT-WSUS-01`, and returns on 26100.9168 | FAILED | **The E2E does not exist** |

**Score: 8 verified, 1 partial, 1 failed.** Against the milestone exit as the
executor framed it, **7 of 10 items met**.

### Required artifacts

| Artifact | Lines | Status |
|---|---|---|
| `tests/helpers/HDTTestTools/tools/Get-HDTLabMemoryBudget.ps1` | 63 | VERIFIED, carries `34359738368` |
| `tests/helpers/HDTTestTools/tools/Assert-HDTLabMemoryBudget.ps1` | 89 | VERIFIED, called by `New-HDTLabVirtualMachine:166` and all five E2E suites |
| `tests/helpers/HDTTestTools/tools/Get-HDTLabVmStamp.ps1` | 46 | VERIFIED, stamped at `New-HDTLabVirtualMachine:188` |
| `tests/helpers/HDTTestTools/tools/Test-HDTLabVmStamped.ps1` | 54 | VERIFIED |
| `tests/helpers/HDTTestTools/tools/Get-HDTLabMemoryUse.ps1` | 107 | VERIFIED |
| `tests/contract/LabMemoryBudget.Contract.Tests.ps1` | 256 | VERIFIED, and a genuinely good contract: it excludes the stale worktree, asserts "scans at least one file" so it cannot pass on an empty set, and mutation-tests itself with "bites on a deliberate violation" |
| `src/Hephaestus/Public/New-HDTUpdateSessionService.ps1` | 321 | VERIFIED |
| `tests/contract/UpdateSessionService.Contract.Tests.ps1` | 409 | VERIFIED |
| `src/Hephaestus/Public/Steps/Invoke-HDTWindowsUpdateStep.ps1` | 663 | VERIFIED |
| `src/Hephaestus/Private/Get-HDTFullOsOnlyStepType.ps1` | 76 | VERIFIED |
| `src/Hephaestus/Private/Select-HDTApplicableUpdate.ps1` | 182 | VERIFIED |
| `src/Hephaestus/Private/Test-HDTStepPhaseForbidden.ps1` | 99 | VERIFIED |
| `Get-HDTUpdateKbNumber` / `Test-HDTUpdateExcluded` / `Get-HDTUpdateResultName` | 91 / 118 / 71 | VERIFIED |
| `Get-HDTWindowsUpdateStepTemplate` / `...Description` | 106 / 90 | VERIFIED, both exercised live against the imported module |
| `tests/unit/WindowsUpdateStepSurface.Tests.ps1` | 599 | VERIFIED |
| `tests/fixtures/sequences/valid-windows-update.yaml` | 54 | VERIFIED |
| **`tests/e2e/WindowsUpdate.E2E.Tests.ps1`** | — | **MISSING** |

### Key links

| From | To | Via | Status |
|---|---|---|---|
| `Invoke-HDTWindowsUpdateStep` | `Context.Service.UpdateSession` | `GetRequired('UpdateSession', 'WindowsUpdate')` | WIRED, line 225 |
| `Invoke-HDTWindowsUpdateStep` | the existing reboot machinery | `New-HDTStepResult -Status RebootRequested -Reenter` | WIRED, line 631 |
| `Import-HDTSequenceDocument` | `Test-HDTStepPhaseForbidden` | the flattener, where inherited `runIn` is known | WIRED, line 317, and no type literal |
| `Start-HDTResume` | `New-HDTUpdateSessionService` | `-UpdateSession` on the full-OS catalog | WIRED, lines 765 and 770 |
| `Get-HDTConsoleStepCatalog` | `'WindowsUpdate'` | the `$known` table, General shelf, Order 10 | WIRED, line 128 |
| `Hephaestus.psd1` | all four new public commands | `FunctionsToExport` | WIRED, lines 112, 132, 203, 220 |
| `New-HDTLabVirtualMachine` | `Assert-HDTLabMemoryBudget` and `Get-HDTLabVmStamp` | the guard and `-Notes` | WIRED, lines 166 and 188; no byte literal survives in the file |
| five `tests/e2e/*.E2E.Tests.ps1` | `Assert-HDTLabMemoryBudget` | replacing the inline running totals | WIRED, all five |
| `Remove-HDTLabVirtualMachine` | `Test-HDTLabVmStamped` | after lookup, before `Stop-VM` | PARTIAL — correct for the destructive path, bypassed under `-WhatIf` |
| the E2E | `HDT-WSUS-01` via `HDTWSUSServer` | the sequence variable | NOT WIRED — there is no E2E file |

### Rule 8 — the surfaces, including the two that correctly needed no change

Checked directly rather than read out of a summary:

- Template, description, console shelf row, four properties rows, both manifest
  exports, `docs/command-categories.psd1`, the regenerated
  `docs/command-reference.html`, the step contract's hand-written list and the
  schema fixture — **all present**.
- **`schemas/sequence.schema.json` needed no change, and correctly has none.**
  Its `step` definition carries no `additionalProperties: false`, so
  step-specific keys validate as authored. The fixture
  `valid-windows-update.yaml` is picked up by `SequenceSchema.Contract.Tests.ps1`
  by wildcard, so this is *asserted* rather than merely reasoned about — which is
  the right resolution of the brief's concern.
- **`Assert-HDTSequenceDocument` likewise needed no change.** Its closed key sets
  are `$allowedRootKey`, `$allowedGroupKey` and `$allowedRetryKey` only; **step
  keys are deliberately open**. So `server`, `categories`, `exclude` and
  `maxPasses` were never "invisible until listed" — the brief's premise does not
  apply at the step level in this codebase.
- The samples: `STD-CLIENT` (lines 111 and 124) and `STD-SERVER` (96 and 110)
  each run the step twice bracketing `InstallApplications`, under MDT's own
  names. `src/Hephaestus/Templates/client.yaml` (360, 372) carries both with
  `disabled: true`. `C:\HDTLab\Share\TaskSequences\PNP-TEST\sequence.yaml`
  (275, 308) is spliced to match — **the share was read on disk, not taken on
  trust.**
- The deferral sweep walks five documents, is written against the set, and its
  regex permits the struck-through history while failing any line that stops at
  the deferral.

### Rule 5 and rule 1

- **Rule 5 holds.** The step makes no direct call to COM, registry, CIM,
  filesystem or process. All COM is confined to `New-HDTUpdateSessionService`,
  which is the adapter.
- **Rule 1's adapter exception.** `New-HDTUpdateSessionService` is not strictly
  branch-free: it carries `if ($null -ne $this.Journal)` and two `foreach`
  marshalling loops. This is **not a deviation** — all 13 real services under
  `src/Hephaestus/Public/New-HDT*Service.ps1` carry the identical journal `if`,
  and the `foreach` builds a COM `UpdateColl` from a parameter rather than making
  a decision.

### TDD

Read from `git show --stat`, not from summaries:

| Commit | Shape |
|---|---|
| `4b11e12` | **test-only** — `LabMemoryBudget.Tests.ps1` 278 lines, `LabVmStamp.Tests.ps1` 85. Implementation followed in `d9571c3`. Tests strictly first. |
| `d8de2c0` | **test-only** — the hand-written fake, 475 lines. The real adapter followed in `ceb46ea`. Tests strictly first. |
| `7a15faa` | test and implementation together, 272 test lines against 196 of source |
| `d31be4a` | test and implementation together, 328 against 209 |
| `9acc273` | test and implementation together, 716 against 734 |
| `79dc68e` | test and implementation together, 387 against about 240 |
| `1b8f87e` | test and implementation together, 212 against about 150 |

**No commit adds implementation whose covering test lands in a LATER commit.**
Two of the four plans committed tests strictly ahead; the rest are same-commit,
which the brief accepts as "before or alongside". The recorded RED runs cannot be
re-derived from git, but the commit ordering is consistent with them and the
test-to-source line ratios are healthy throughout.

### Logging

`Invoke-HDTWindowsUpdateStep` makes 20 distinct `Write-HDTLog` calls, including a
`step.progress` frame per update and an `update.apply` record per update carrying
the KB, the title, the classification, the result code AND its meaning, the
HResult and the elapsed time. `Select-HDTApplicableUpdate` returns a reason for
every filtered row. This meets `CLAUDE.md`'s logging rule.

---

## Hyper-V lab — untouched

Enumerated with `Get-VM` (not a name list) **before** any run and again **after**
both gates:

| Name | State | Assigned | Gen | Switch | Notes |
|---|---|---|---|---|---|
| `HDT-WDS-01` | Running | 4096 MB | 2 | `HDT External` | empty |
| `HDT-WSUS-01` | Running | 8192 MB | 2 | `HDT External` | empty |

`Get-VM` returned **2 rows**, so the enumeration is not vacuous — this host
genuinely carries only these two VMs, and the set of VMs **not** named `HDT-*` is
empty as a fact about the host rather than as an empty-equals-empty pass. The two
snapshots are identical, and the uptimes (3 d 20 h and 1 d 4 h) both predate this
session, so neither VM was restarted. **No VM was created, started, stopped or
removed, and no stray `HDT-*` target VM was left powered on.** Both servers remain
unstamped, which is what keeps them out of the budget and out of teardown.

---

## Anti-patterns

| File | Pattern | Severity | Impact |
|---|---|---|---|
| `tests/helpers/HDTTestTools/tools/Remove-HDTLabVirtualMachine.ps1` | the safety guard is placed after the `ShouldProcess` early return | Warning | `-WhatIf` reports it would remove a protected server |
| `tests/unit/New-HDTLabVirtualMachine.Tests.ps1` | all three stamp-guard tests are AST-only; none invokes the command | Warning | the defect above is structurally invisible to the suite |
| `08-01-03-PLAN.md`, `08-01-04-PLAN.md` | uncommitted working-tree modifications, 206 and 87 added lines | Info | plan amendments made during execution were never committed; `git status` is dirty |

No `TODO`, `FIXME`, `PLACEHOLDER`, stub return or empty handler was found in any
file this phase added.

---

## Gaps summary

**The `WindowsUpdate` step is genuinely built, genuinely wired, genuinely
authorable from the console and genuinely green on the gate. Every claim in the
executor's report that I re-ran came back true. It has never patched a machine.**

1. **The milestone exit is not met.** `tests/e2e/WindowsUpdate.E2E.Tests.ps1`
   does not exist. Nothing has been deployed, nothing has been patched, and no
   machine has come back on 26100.9168. Four of the ten exit items are the same
   missing E2E. The blocker — `HDT-WSUS-01` not resolving by name — is real and
   was reproduced this session, but it is worth saying plainly that it is a
   *plan rule*, not a wall: a WSUS client addresses its server by URL, and an
   IP-based URL is a supported configuration. The user's decision is the thing
   actually missing.

2. **`Remove-HDTLabVirtualMachine -WhatIf` says it would remove `HDT-WSUS-01`.**
   Verified live this session. The destructive path is safe, so this is not a
   blocker, but a safety command whose dry run contradicts its own guarantee is
   exactly the kind of thing that gets believed. The fix is to move the lookup
   and the stamp refusal above `ShouldProcess`, and to add the one test that
   invokes the command instead of parsing it.

3. **`.planning/SPIKES.md` has no entry, correctly** — SPIKES takes only
   verified-by-execution findings, and there is no run to record.

---

_Verified: 2026-09-06_
_Verifier: Claude (gsd-verifier) — an independent re-run, not a review of the SUMMARYs_
