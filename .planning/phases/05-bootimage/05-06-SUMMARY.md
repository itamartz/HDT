---
phase: 05-bootimage
plan: 06
subsystem: power, build harness, adapter discipline
tags: [winpe, wpeutil, IPowerService, adapter, pester, powershell-5.1]
requires:
  - "05-04 Update-HDTBootImage, for an image to mount and read"
  - "05-05 the WinPE smoke E2E, for a machine to power off"
provides:
  - "Get-HDTPowerCommand - the pure WinPE/FullOS power decision"
  - "New-HDTPowerService -Environment (mandatory)"
  - "Assert-HDTPesterResult - a build that cannot report success over a suite that never ran"
  - "tests/integration/WinPeContent.Integration.Tests.ps1 - what WinPE ships and what it does not"
affects:
  - "build.ps1, all three suites"
  - "New-HDTDiskService, New-HDTImageService, New-HDTBootImageService"
  - "both engine payloads and the M3 lab launcher"
tech-stack:
  added: []
  patterns:
    - "the decision is pure and unit-tested; the adapter stays branch-free"
    - "a mandatory parameter rather than a better default, where a default is what spread the wrong answer"
    - "an absent marker file as the discriminator, where the observable outcome would happen either way"
key-files:
  created:
    - "src/Hephaestus/Private/Get-HDTPowerCommand.ps1"
    - "tests/unit/Get-HDTPowerCommand.Tests.ps1"
    - "tests/unit/New-HDTPowerService.Tests.ps1"
    - "tests/unit/NativeCommandStderr.Tests.ps1"
    - "tests/unit/DiskServiceErrorAction.Tests.ps1"
    - "tests/integration/WinPeContent.Integration.Tests.ps1"
  modified:
    - "src/Hephaestus/Public/New-HDTPowerService.ps1"
    - "src/Hephaestus/Public/New-HDTDiskService.ps1"
    - "src/Hephaestus/Public/New-HDTImageService.ps1"
    - "src/Hephaestus/Public/New-HDTBootImageService.ps1"
    - "src/Hephaestus/Payload/Start-HDTDeployment.ps1"
    - "src/Hephaestus/Payload/Start-HDTResume.ps1"
    - "build.ps1"
    - "tests/e2e/payload/Start-HDTLabProbe.ps1"
    - "tests/e2e/WinPeSmoke.E2E.Tests.ps1"
decisions:
  - "-Environment is mandatory on New-HDTPowerService. A default is what let the wrong answer spread silently in the first place."
  - "-Command was removed. It existed so the answer could be supplied later; the answer is in, and an override is a way to put shutdown.exe back into WinPE from a sequence file."
  - "The WinPE delay is honoured by sleeping, not dropped. wpeutil takes no delay, and a sequence's delaySecond: must not become a lie in one phase."
  - "S13.6's root cause is recorded as UNESTABLISHED rather than guessed at; the fix removes the dependency instead of explaining it."
metrics:
  tasks: 4
  commits: 12
  duration: "one session"
  completed: 2026-08-14
---

# Phase 05 Plan 06: the WinPE power question, answered by execution — Summary

**ROADMAP M2's deferred question is answered, and the answer was a defect:
`shutdown.exe` is not in WinPE at all, so a `Restart` step there called a command
that does not exist.** Answering it turned up three more defects — one in the
build script that had been calling a suite that never ran a success, one that
made the ISO build impossible under the engine HDT ships on, and one where a
destructive disk adapter failed silently.

## What this plan was

Phase 05 owned a question it had not answered. `docs/ROADMAP.md` M2:

> **`New-HDTPowerService` has never been executed** and whether WinPE needs
> `wpeutil reboot` rather than `shutdown.exe` is a phase 05 question.

Five plans went by. `05-VERIFICATION.md` recorded it `not_answered`;
`New-HDTPowerService.ps1` and the `IPowerService` contract both carried
*"UNVERIFIED, RECORDED FOR PHASE 05"*. The answer was one mount away.

## Task 1 — `Get-HDTPowerCommand`, the pure decision

A read-only mount of the boot image 05-04 built:

```
Windows\System32\shutdown.exe   ABSENT
Windows\System32\wpeutil.exe    PRESENT, 32768 bytes
```

So this was never a style question. `New-HDTPowerService` defaulted to
`shutdown.exe`; the engine's `Restart` step calls `IPowerService.Restart()`; in
WinPE that could only ever raise *"The term 'shutdown.exe' is not recognized"*.

**Why nothing caught it** is the more useful half. `DEMO-M3` and `DEMO-M4` both
deliberately have no `Restart` step, so the one path that would have executed it
never ran; the contract's real row is skipped permanently and correctly, because
a contract test may not reboot the machine running it; and the fake records the
call and returns — SPIKES S9.3's shape exactly, where a fake that accepts a call
the world refuses keeps a suite green over code that cannot work.

`Get-HDTPowerCommand -Environment WinPE|FullOS -Operation Restart|Stop
-DelaySecond n` returns the command, the exact argument array, a `SleepSecond`
and a reason. **26 tests, RED first**, asserting exact argument arrays rather
than patterns — a `/t 30` that came out `/t30` would satisfy a `-Match` and fail
on a machine.

`wpeutil reboot` and `wpeutil shutdown` take **no delay argument**, so a
sequence's `delaySecond:` is honoured by sleeping first. The plan carries that as
`SleepSecond` and says so, rather than the adapter deciding or the delay being
dropped in one phase and not the other.

## Task 2 — the adapter, and the three callers that already knew

**`-Environment` is mandatory and `-Command` is gone.** A better default was not
the fix: a default is exactly what let every caller inherit the wrong answer in
silence. The three callers — `Start-HDTDeployment.ps1` (WinPE),
`Start-HDTResume.ps1` (FullOS) and the M3 lab launcher (WinPE) — all already
hardcode their phase; nothing detects anything.

The adapter stays branch-free, which is what earns a thin adapter its exemption
from TDD, and `tests/unit/New-HDTPowerService.Tests.ps1` is what keeps it that
way: no `If`/`Switch` in `Restart` or `Stop` (scoped to those two, because
`Record`'s journal guard decides nothing about the world), neither executable
named in the file, and `Start-Sleep` unconditional because `-Seconds 0` is a
no-op and a guard would be a branch.

One assertion there is not pedantry: **a `ScriptMethod` resolves commands in the
session state its scriptblock was created in**, which is the only reason a
*private* decision is reachable from a caller outside the module. Get that wrong
and the failure is a `CommandNotFoundException` on the one machine nobody can
attach a debugger to, at the moment it was supposed to reboot.

And an anti-drift test: the payload's own two `$ending` verbs — it calls
`wpeutil` directly, after the catch, because it must end the machine even on a
run where the module never imported — are compared with what
`Get-HDTPowerCommand` yields for WinPE.

## Task 3 — the evidence, and the first real execution

**`tests/integration/WinPeContent.Integration.Tests.ps1`** mounts the real ADK
`winpe.wim` and HDT's own built image read-only and asserts `wpeutil.exe`
**present** and `shutdown.exe` **absent**. The presence assertion is the
anti-vacuity guard: a failed mount or a wrong `System32` path fails it first, so
the absence can never be an artefact of looking in the wrong place.

**`tests/e2e/WinPeSmoke.E2E.Tests.ps1` now powers its VM off with the real
adapter.** `New-HDTPowerService` had never executed anywhere in this repository
across three phases.

The discriminator matters more than the run: the smoke VM was always going to
power off, so "the VM ended" proves nothing. The probe writes `PROBE.json` first
(carrying `shutdownExe`, `wpeutilExe`, `powerEnvironment`, `powerCommand`,
`powerArgument`, `powerError`), calls `$power.Stop(0)`, waits **120 s**, and only
then writes **`FALLBACK.txt`** and calls `wpeutil` itself. **The assertion is that
`FALLBACK.txt` is absent** — a fast readable failure instead of a fifteen-minute
timeout, and a claim a coincidence cannot satisfy.

## Deviations from plan — four defects, all found by running the thing

### 1. [Rule 1 — Bug] `./build.ps1` reported BUILD SUCCEEDED over a file that never ran

**Found by walking into SPIKES S9.15 myself, for the fourth time in this
repository, and the first time its symptom was a *missing* result rather than a
wrong one.**

The first draft of the new integration file read a `BeforeAll` variable from a
`Context`'s `-Skip:`. Discovery and run do not share a scope, so under the
StrictMode `build.ps1` sets, **discovery died** — Pester dropped three of the
four contexts and reported `4 passed, 0 failed`. The result object said
`Result Failed`, `FailedContainersCount 1`, **`FailedCount 0`**, and all three
suites in `build.ps1` judged themselves by `FailedCount` alone.

So the entry point this phase kept insisting on had a hole in it: running a suite
through `build.ps1` was not, by itself, evidence that the suite ran.

`Assert-HDTPesterResult` now judges every suite, checks the container count
first, and names the file and the error. **Proven by planting a discovery
failure**, which is the only proof S9.15b accepts:

```
test: 4893 passed, 0 failed, 42 skipped
BUILD FAILED: 1 test file(s) could not be run at all - a discovery or setup
  failure means their assertions never executed ...
  ZZPlantedDiscoveryFailure.Tests.ps1: The variable '$script:plantedFlag'
  cannot be retrieved because it has not been set.
```

4893 tests passed. Under the old condition that was a green build.

### 2. [Rule 1 — Bug] the boot image could not be built under Windows PowerShell 5.1

Caught by the guard above, on its first real use. The first
`./build.ps1 -Task integration` **ever run under `powershell.exe`** died in
`BootImage.Integration.Tests.ps1`'s setup:

```
Exception calling "NewIso" with "3" argument(s): "The running command stopped
because the preference variable "ErrorActionPreference" ... : 0% complete"
```

**`0% complete` is oscdimg's progress meter.** Under 5.1, `@(& $tool @arg 2>&1)`
wraps each stderr line in an `ErrorRecord` and `$ErrorActionPreference = 'Stop'`
— which engine code must set — makes the first one terminating, before
`$LASTEXITCODE` is ever consulted. Five adapters were affected: `oscdimg`,
`dism /Set-ScratchSpace`, `bcdboot`, `reagentc` and `bcdedit` — the ISO build and
most of `ConfigureBoot`.

**pwsh 7 does not do this, and every integration run before this one was under
pwsh.** `-Task test` had always been run under both engines as CLAUDE.md
requires — but `test` is not the suite that shells out.

Fixed with one line per method, local to the method scope, no branch.
`tests/unit/NativeCommandStderr.Tests.ps1` keeps it there and deliberately
excludes `*>&1`, which is `New-HDTScriptInvoker` merging an administrator's own
script, where an error *should* stop the step.

### 3. [Rule 1 — Bug] the disk adapter failed silently when the preference was not Stop

The next full run printed `Clear-Disk`'s own *"The disk has not been
initialized."* and then reported that `ClearDisk` had thrown nothing. The disk
was `RAW`, asserted one line earlier. In a deployment rather than a test, the
step would have gone on to partition a disk it believed it had cleared.

**Why the preference was not `Stop` in that scope was not established, and this
summary will not invent one.** It reproduces only in the full seven-file run, on
both engines, and passes in every subset tried — the file alone (24/24), with
`DiskPartition` (43/43), with `BootImage` (63/63, module preference read back
`Stop` afterwards), with all three (82/82), and with the four files that follow
it (53/53). A `$ErrorActionPreference` assigned inside a `ScriptMethod` was
tested directly and does **not** leak to module scope, so defect 2's fix is not
the cause.

**The fix is that the question should never have been askable.** All seven
destructive Storage calls now pass `-ErrorAction Stop` explicitly. The read-only
`Get-Disk`/`Get-Partition`/`Get-Volume` deliberately do not, and the guard
asserts that too: an empty result is a legitimate answer, and DESIGN 9.1's
refusal to guess a target is built on it.

### 4. [Rule 3 — Blocking] the M3 lab launcher and the helpers README

`tests/e2e/payload/Start-HDTLabDeployment.ps1` was a third caller of
`New-HDTPowerService` and would have *prompted* for the now-mandatory parameter
inside WinPE. Found by grep, fixed, and given an assertion of its own.

## The runs, all through `./build.ps1`

| Run | Engine | Result |
|---|---|---|
| `-Task test` | pwsh 7.5.8 | **4907 passed, 0 failed, 42 skipped** |
| `-Task test` | Windows PowerShell 5.1.26100.8655 | **4762 passed, 0 failed, 187 skipped** |
| `-Task lint` | pwsh 7.5.8 | 0 diagnostics across 344 files |
| `-Task integration` | **Windows PowerShell 5.1** | **138 passed, 0 failed, 0 skipped**, 607 s |
| `-Task e2e` | **Windows PowerShell 5.1** | **98 passed, 0 failed, 0 skipped**, 1566 s |

The integration and e2e suites had **never been run under Windows PowerShell
5.1** before this plan. Both are green there now, and defect 2 is what that cost.

`PROBE.json`, written by the smoke VM from inside WinPE:

```json
"psVersion": "5.1.26100.1",  "shutdownExe": false,  "wpeutilExe": true,
"powerEnvironment": "WinPE", "powerCommand": "wpeutil.exe",
"powerArgument": "shutdown", "powerError": ""
```

`FALLBACK.txt` was absent, so the adapter is what ended that machine.

## Lab safety

`CM01` and `DC01` read back name-filtered and module-qualified before and after
every run — both `Off` and untouched. Zero `HDT-*` VMs and an empty
`C:\HDTLab\vms` afterwards; `Get-WindowsImage -Mounted` empty; this host's disk 0
`GPT|True|True` before and after. Every image this plan mounted was mounted
`-ReadOnly` and dismounted `-Discard` in a `finally`. The planted
discovery-failure file was removed in the same step that proved the guard.

## What this plan did NOT prove

- **No `Restart` step has executed in WinPE.** `Stop` has, through the real
  adapter. `Restart` differs only in the verb it takes from the same asserted
  table — and "differs only in" is an argument, not a measurement.
- **`Start-HDTResume.ps1`'s `FullOS` leg is still unexecuted.** Nothing here has
  ever run `shutdown.exe /r` through the service, because it would restart the
  developer's machine.
- **The delay is unmeasured.** Every run uses 0.
- Nothing about WDS, SMB deployment or PXE booting changed. Those gaps stand
  exactly as `05-VERIFICATION.md` states them.

## Self-Check: PASSED

All eight files this summary names exist on disk; all twelve commit hashes it
depends on are in `git log`. The counts quoted are from the `./build.ps1` runs
whose logs are quoted verbatim, not from a bare `Invoke-Pester`.
