---
phase: 08-windows-update
plan: 08-01-01
subsystem: test-harness
tags: [lab-safety, hyper-v, memory-budget, contract-test]
requires: []
provides:
  - Get-HDTLabMemoryBudget
  - Get-HDTLabVmStamp
  - Test-HDTLabVmStamped
  - Get-HDTLabMemoryUse
  - Assert-HDTLabMemoryBudget
affects:
  - tests/helpers/HDTTestTools/tools/New-HDTLabVirtualMachine.ps1
  - tests/helpers/HDTTestTools/tools/Remove-HDTLabVirtualMachine.ps1
  - tests/e2e/*.E2E.Tests.ps1
tech-stack:
  added: []
  patterns:
    - "One place of truth for a constant, enforced by a contract test scanning the whole repository"
    - "Membership decided by a marker the code writes at creation, never by a list of names"
key-files:
  created:
    - tests/helpers/HDTTestTools/tools/Get-HDTLabMemoryBudget.ps1
    - tests/helpers/HDTTestTools/tools/Get-HDTLabVmStamp.ps1
    - tests/helpers/HDTTestTools/tools/Test-HDTLabVmStamped.ps1
    - tests/helpers/HDTTestTools/tools/Get-HDTLabMemoryUse.ps1
    - tests/helpers/HDTTestTools/tools/Assert-HDTLabMemoryBudget.ps1
    - tests/unit/LabMemoryBudget.Tests.ps1
    - tests/unit/LabVmStamp.Tests.ps1
    - tests/contract/LabMemoryBudget.Contract.Tests.ps1
  modified:
    - tests/helpers/HDTTestTools/HDTTestTools.psd1
    - tests/helpers/HDTTestTools/tools/New-HDTLabVirtualMachine.ps1
    - tests/helpers/HDTTestTools/tools/Remove-HDTLabVirtualMachine.ps1
    - tests/unit/New-HDTLabVirtualMachine.Tests.ps1
    - tests/e2e/ApplicationRoundTrip.E2E.Tests.ps1
    - tests/e2e/CapturedImageDeployment.E2E.Tests.ps1
    - tests/e2e/Deployment.E2E.Tests.ps1
    - tests/e2e/ReferenceCapture.E2E.Tests.ps1
    - tests/e2e/UnattendedDeployment.E2E.Tests.ps1
    - tests/e2e/README.md
    - tests/helpers/README.md
    - .planning/PROJECT.md
    - CLAUDE.md
    - build.ps1
    - docs/ROADMAP.md
decisions:
  - "The contract scan is contextual, not a bare grep: both byte values are also ordinary disk sizes in eight unrelated files"
  - "The e2e contract asserts a property of the set - no file totals memory, none creates a VM behind the helper - rather than demanding a named call two suites do not need"
metrics:
  duration: "~35 min"
  completed: 2026-09-06
---

# Phase 08 Plan 01-01: Lab memory budget, in one place, counting only what the harness stamped — Summary

Raised the lab memory budget from 12 GB to 32 GB, moved the number from six
files into one, and made the budget count only VMs the harness created — decided
by a marker stamped into `Notes` at creation, never by a list of names.

## Why it had to happen first

`HDT-WDS-01` (4 GB) and `HDT-WSUS-01` (8 GB) hold 12884901888 bytes between them,
which was exactly the whole cap, so `New-HDTLabVirtualMachine` refused to create
any target VM and nothing in phase 08 could run.

## The live host, after

Recorded on 2026-09-06 against the real host, so the next plan can prove there is
room before it starts anything:

```
AssignedByte 0
Counted      []
Ignored      [HDT-WDS-01, HDT-WSUS-01]

Assert-HDTLabMemoryBudget -MemoryByte 4294967296 -Name 'HDT-08-Probe'  ->  accepted
```

Both machines are untouched by this plan: still `Running`, still 8 GB and 4 GB,
`Notes` still empty (length 0). No VM was created, started, stopped or removed.

## What was built

Five HDTTestTools commands, all written test-first:

| Command | What it is |
|---|---|
| `Get-HDTLabMemoryBudget` | The only file that may carry either byte value. Pure, no Hyper-V |
| `Get-HDTLabVmStamp` | The `Notes` marker — a sentence, so it also tells a human the VM is disposable |
| `Test-HDTLabVmStamped` | Substring, not equality: an operator adding a note has not disowned the machine |
| `Get-HDTLabMemoryUse` | Counts running **and** stamped; reports what it ignored and how many |
| `Assert-HDTLabMemoryBudget` | The check every caller shares |

`New-HDTLabVirtualMachine` lost both byte literals and its own running total, and
stamps every VM it creates. `Remove-HDTLabVirtualMachine` refuses a VM carrying no
stamp — after the lookup, before `Stop-VM`, because a server turned off and then
refused is a server that is off. Both proved by AST, since `Mock` cannot intercept
a module-qualified `Hyper-V\` call.

## Test counts, from real runs

| Run | Result |
|---|---|
| `LabMemoryBudget` + `LabVmStamp`, before implementation | **0 passed, 29 failed** — every one `CommandNotFound` |
| The same two, after | 29 passed, 0 failed |
| `New-HDTLabVirtualMachine.Tests.ps1`, new assertions before implementation | 37 passed, **6 failed** |
| The three unit files, after | 72 passed, 0 failed |
| `LabMemoryBudget.Contract.Tests.ps1` | 8 passed, 0 failed |
| `./build.ps1 ci`, Windows PowerShell 5.1.26100.8655 | lint 0 diagnostics; **14149 passed, 0 failed, 268 skipped**; `BUILD SUCCEEDED` |

## Deviations from Plan

### 1. [Rule 1 — Bug] The contract scan had to be contextual, not a bare grep

The plan specified "the byte value appears in exactly one file", checked by
scanning for the digits. Run as written it is red for reasons that are not
defects: `8589934592` is 8 GB and `34359738368` is 32 GB, and both are perfectly
ordinary **disk** sizes. They stand today in eight files as fixture disk rows, a
content VHDX size and a volume assertion — including
`tests/unit/Select-HDTTargetDisk.Tests.ps1`, where `SizeRemainingBytes` is 32 GB.

A bare-digit count would have been silenced by exclusions within a week. So a hit
counts when the digits stand within two lines of what makes them a *memory*
quantity, and the last assertion in the file plants a violation and proves the
scan finds it.

**Consequence for the plan's `<done>` criterion:** `grep -rn "34359738368"` returns
two live files, not one — `Get-HDTLabMemoryBudget.ps1` and the unrelated disk
fixture. `grep -rn "12884901888"` returns nothing, as specified.

### 2. [Rule 1 — Bug] The e2e contract assertion was wrong, and the files were right

The plan asked that every `tests/e2e/*.E2E.Tests.ps1` call
`Assert-HDTLabMemoryBudget`. There are **seven** such files, not five:
`WinPeSmoke` and `Wizard` never had an inline running total to replace. They are
not exempt — they create their VMs through `New-HDTLabVirtualMachine`, which asks
the shared check itself, so every VM any e2e suite starts is budget-checked either
way. Demanding the call by name would have forced two files to repeat a check they
already get.

Rewritten as the property that actually matters: no e2e file totals `MemoryAssigned`
itself, none calls `Hyper-V\New-VM` directly, and any file that still keeps a
pre-flight check asks the shared one.

### 3. [Rule 1 — Bug] The prose scan read one line at a time

PROJECT.md's rewritten rule 4 wraps "under 32 GB" onto one line and "combined"
onto the next, and a line-at-a-time scan read that as a document stating no budget
at all. The scan now flattens the file first — prose wraps, and the rule does not
care where.

### 4. [Rule 2 — Missing safeguard] Two things the contract caught in its own authors

- A comment in `tests/unit/LabMemoryBudget.Tests.ps1` quoted the byte value, which
  is a seventh copy in the file whose job is to have none.
- The detector was blind to `Get-HDTLabMemoryBudget.ps1` itself: the digits sat two
  lines from any memory word. Both the comment there and the keyword set were
  fixed, so the scan finds the value in the one file it is supposed to live in.

### 5. [Rule 3 — Blocking] PSScriptAnalyzer on the two test row builders

`New-HDTTestVmRow` / `New-HDTTestStampedVmRow` tripped
`PSUseShouldProcessForStateChangingFunctions` and failed `./build.ps1 lint`. Given
the repository's established `SuppressMessageAttribute` + justification pattern,
used by a dozen other unit files for exactly this.

### 6. [Deviation — process] No `.planning/STATE.md` in this repository

The executor workflow updates `STATE.md`; this project has none (`.planning/` holds
`PROJECT.md`, `ROADMAP.md`, `SPIKES.md`, `phases/`). Nothing was created and no
state command was run.

## Not done, and deliberately

`src/Hephaestus/Hephaestus.psd1` and `docs/command-reference.html` are modified in
the working tree and **not committed here**. Both were already dirty before this
plan began; the gate's own version task then bumped 0.20.0 → 0.21.0 and regenerated
the command reference. That is the build's normal behaviour and outside this
plan's scope.

## Self-Check: PASSED
