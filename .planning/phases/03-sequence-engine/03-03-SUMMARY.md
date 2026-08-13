---
phase: 03-sequence-engine
plan: 03
subsystem: engine
tags: [autologon, lsa, registry, teardown, reboot-resume, spike, security, pester, tdd, powershell-5.1]

# Dependency graph
requires:
  - phase: 02-rules
    provides: New-HDTFakeRegistryService and New-HDTRegistryService (read subset), the fake conventions
  - phase: 03-sequence-engine
    plan: 01
    provides: the shared journal, IClock, IFileSystem, New-HDTLogContext/Write-HDTLog, New-HDTRunState/Save-HDTRunState/Import-HDTRunState/Test-HDTRunStateAbandoned
  - phase: 03-sequence-engine
    plan: 02
    provides: the step contract and the Restart step that 03-04 arms around
provides:
  - "SPIKES.md S8: AutoLogonCount observed decrementing 3 -> 2 -> 1 -> 0, Windows disarming itself afterwards, and three autologons driven by an LSA secret alone"
  - "The IRegistryService write half: NewKey, SetValue, RemoveValue, RemoveKey, on both implementations"
  - "ILsaService: New-HDTLsaService and New-HDTFakeLsaService, plus its opt-in read-only contract"
  - "New-HDTDeploymentPassword: unique per run, complexity-safe by construction, rejection sampled"
  - "Set-HDTAutoLogon, Get-HDTAutoLogonState, Clear-HDTAutoLogon - DESIGN 4.5.1 arming and the 4.5.3 checklist"
  - "Invoke-HDTBootReconciliation - DESIGN 4.5.2's second backstop"
  - "Get-HDTAutoLogonArtifact - the one assertion that lists every survivor"
affects: [03-04-the-loop, 03-05-headline-test, 04-imaging, 05-boot-image, 07-applications]

# Tech tracking
tech-stack:
  added:
    - "advapi32 LSA private data interop (LsaOpenPolicy/StorePrivateData/RetrievePrivateData/FreeMemory/Close) via Add-Type"
  patterns:
    - "Seed* for a fake's seeding methods, so the interface method keeps the contract's name"
    - "A recorded operation redacts a secret value: SetSecret records @($Name, '<redacted>')"
    - "Best-effort checklist: every item wrapped independently, results returned as Cleared and Failed rather than thrown"
    - "A test helper that lists survivors instead of nine assertions that stop at the first"
    - "Rejection sampling over single bytes, because RandomNumberGenerator::GetInt32 does not exist under 5.1"
    - "An opt-in contract row gated on elevation AND an environment variable, printing a warning naming both"

key-files:
  created:
    - src/Hephaestus/Public/New-HDTLsaService.ps1
    - src/Hephaestus/Public/New-HDTDeploymentPassword.ps1
    - src/Hephaestus/Public/Set-HDTAutoLogon.ps1
    - src/Hephaestus/Public/Get-HDTAutoLogonState.ps1
    - src/Hephaestus/Public/Clear-HDTAutoLogon.ps1
    - src/Hephaestus/Public/Invoke-HDTBootReconciliation.ps1
    - tests/helpers/HDTTestTools/tools/Get-HDTAutoLogonArtifact.ps1
    - tests/contract/LsaService.Contract.Tests.ps1
    - tests/unit/New-HDTFakeLsaService.Tests.ps1
    - tests/unit/New-HDTDeploymentPassword.Tests.ps1
    - tests/unit/Get-HDTAutoLogonArtifact.Tests.ps1
    - tests/unit/Set-HDTAutoLogon.Tests.ps1
    - tests/unit/Get-HDTAutoLogonState.Tests.ps1
    - tests/unit/Clear-HDTAutoLogon.Tests.ps1
    - tests/unit/Invoke-HDTBootReconciliation.Tests.ps1
  modified:
    - .planning/SPIKES.md
    - docs/DESIGN.md
    - src/Hephaestus/Public/New-HDTRegistryService.ps1
    - src/Hephaestus/Hephaestus.psd1
    - tests/helpers/HDTFakes/HDTFakes.psm1
    - tests/helpers/HDTFakes/HDTFakes.psd1
    - tests/helpers/HDTTestTools/HDTTestTools.psd1
    - tests/helpers/README.md
    - tests/contract/RegistryService.Contract.Tests.ps1
    - tests/unit/New-HDTFakeRegistryService.Tests.ps1
    - tests/unit/FakeJournal.Tests.ps1

decisions:
  - "The S8 spike ran first and confirmed LSA storage, so Set-HDTAutoLogon has no -PasswordStorage fallback"
  - "-Password stays [string]; SecureString would move the plaintext, not remove it, and both analyzer rules are suppressed with that reasoning in the file"
  - "STATUS_OBJECT_NAME_NOT_FOUND is written in decimal, because PowerShell parses 0xC0000034 as a negative Int32"
  - "Clear-HDTAutoLogon gained -Clock, which the plan's signature did not list, because Save-HDTRunState requires one"
  - "SetSecret records '<redacted>' rather than the value, a deliberate exception to 'the arguments, verbatim'"

metrics:
  duration: ~3h
  completed: 2026-08-13
---

# Phase 03 Plan 03: The autologon lifecycle Summary

The deployment password, arming bounded by `AutoLogonCount`, the DESIGN 4.5.3
teardown checklist and the boot-time reconcile — all behind `IRegistryService`
and `ILsaService`, and all preceded by a spike that turned DESIGN 4.5.2's last
open question into an observation.

## What was built

### Task 1 — SPIKE S8, and it answered cleanly

`ce7a123` · `.planning/SPIKES.md` S8, `docs/DESIGN.md` 4.5.2

A throwaway `HDT-AutoLogon-Spike` VM, Generation 2, Secure Boot on, 4 GB, on the
isolated `HDT Lab` switch, built on a **copy** of S7's disk. Autologon was armed
entirely in the VM's **offline** `SOFTWARE` hive (`reg load HKLM\HDTSPIKE`,
unloaded in a `finally`) with `AutoAdminLogon=1`, `AutoLogonCount=3` and a
`RunOnce` entry — and **deliberately no registry `DefaultPassword`**, so that an
autologon happening at all was itself the proof that LSA storage works.

The observer re-registered itself under `RunOnce` each leg, which is the
mechanism S7 could not use. A startup scheduled task registered on leg 1 and
delayed four minutes was the watchdog: on a boot where no autologon happens the
logon observer never runs, so the watchdog recorded that fact and powered the VM
off. That produced leg 4, the single most informative line:

```
leg=1 mode=Logon    AutoAdminLogon=1 AutoLogonCount=2 RegistryDefaultPassword=absent LsaDefaultPassword=present-length-18 user=HDT-TEST-01\Administrator
leg=2 mode=Logon    AutoAdminLogon=1 AutoLogonCount=1 RegistryDefaultPassword=absent LsaDefaultPassword=present-length-18 user=HDT-TEST-01\Administrator
leg=3 mode=Logon    AutoAdminLogon=1 AutoLogonCount=0 RegistryDefaultPassword=absent LsaDefaultPassword=present-length-18 user=HDT-TEST-01\Administrator
leg=4 mode=Watchdog AutoAdminLogon=0 AutoLogonCount=<absent> RegistryDefaultPassword=absent LsaDefaultPassword=present-length-0 RunOnce=present user=WORKGROUP\HDT-TEST-01$
```

**Four findings, all now in DESIGN 4.5.2:**

1. The count decrements once per autologon and **before** the session starts, so
   armed-at-3 sessions read 2, 1, 0. `-RemainingLeg` is literal: *n* buys exactly
   *n* autologons, with no off-by-one.
2. Windows disarms itself when the count is spent — `AutoAdminLogon=0`,
   `AutoLogonCount` deleted, and the `DefaultPassword` LSA secret **blanked to
   zero length**.
3. **Autologon works from the LSA secret with no registry `DefaultPassword`.**
   ROADMAP M2's registry-storage fallback is not needed and was not built.
4. `RunOnce` is consumed per leg exactly as DESIGN 4.5.1 assumes — every leg
   found its own entry already gone and had to re-register. Leg 4 still had one,
   because there was no logon to consume it.

Corroboration, read offline before anything was armed: S7's disk had been left at
`AutoLogonCount=2`, not the `3` S7 reported reading in-session. The decrement had
already happened at that first logon.

**The design change it forced: none.** Every outcome except one left the plan's
tests standing as written, and this was that case. `Set-HDTAutoLogon` therefore
has no `-PasswordStorage` parameter, and DESIGN 4.5.2's "no registry-storage
fallback is required" now cites S8 as well as S7.

**Lab safety.** Every Hyper-V call was name-filtered to `HDT-AutoLogon-Spike` and
module-qualified — `Hyper-V\Get-VM`, because **PowerCLI shadows `Get-VM` on this
host** and a bare call fails with "not connected to any servers". `CM01` and
`DC01` were never touched. S7's disk survived. The host's own Winlogon key was
read before and after and is unchanged — it carries no autologon values at all.
`HKLM\HDTSPIKE` is unloaded. Elapsed: 6.1 minutes against a 45 minute budget.

### Task 2 — the registry write half, ILsaService, the password

`3989c4c` (refactor) · `9bd82d1` (RED) → `5534447` (GREEN)

**The `Seed*` rename came first, as its own green commit.** The fake's seeding
`SetValue`/`AddKey` became `SeedValue`/`SeedKey`, freeing `SetValue` for the
recorded interface method that has to carry the contract's name.

**`IRegistryService` is now six methods**, on the fake and the real adapter:

| Method | Note |
|---|---|
| `TestPath(path)` | unchanged |
| `GetValue(path, name)` | unchanged, `$null` for absent |
| `NewKey(path)` | idempotent |
| `SetValue(path, name, value, type)` | creates the key implicitly |
| `RemoveValue(path, name)` | **idempotent** |
| `RemoveKey(path, recurse)` | **idempotent**; throws for children without recurse |

`$type` is a `New-ItemProperty -PropertyType` name. **Removing something absent is
not an error** — teardown runs on machines in unknown states, and a teardown that
throws on the first absent value does not finish. `SetValue` creates the key
first because `New-ItemProperty` fails on a key that does not exist. The real
`RemoveKey` goes through `Get-Item | Remove-Item` so an absent key is a pipeline
no-op while a key with children and no recurse still throws — the same two
behaviours as the fake, expressed as a pipeline rather than a branch.
`New-HDTRegistryService` also gained `-Journal` and `ServiceName`, which it had
been missing since 02-01.

The fake additionally carries `GetValueType(path, name)`, **not** part of the
interface: it exists so a test can prove `AutoLogonCount` was written as a
`DWord` rather than the string `'3'`, which Winlogon ignores. Like seeding, it
does not record.

**`ILsaService` is three methods** — `SetSecret(name, value)`, `GetSecret(name)`
returning `$null`, and an idempotent `RemoveSecret(name)`. The secret name is
**`DefaultPassword`, with no `L$`/`M$` prefix**: the name Winlogon reads and the
one `Autologon.exe` writes. HDT writes only that one. `New-HDTLsaService` is an
untested adapter by DESIGN 12.2.3 — `Add-Type` behind a type guard, then
`LsaOpenPolicy` / `LsaStorePrivateData` (a null data pointer deletes) /
`LsaRetrievePrivateData` / `LsaFreeMemory` / `LsaClose`, with
`LsaNtStatusToWinError` turning a failure into a `Win32Exception`.

**The real LSA contract row is opt-in and read-only.** It runs only when the
session is elevated **and** `$env:HDT_ALLOW_LSA_TEST -eq '1'`, prints a warning
naming both conditions when it does not, and even then reaches only the
`read only` Context — the `store and remove` Context is skipped for it by a
`FullRow` flag. **The suite never writes an LSA secret on anyone's machine.** For
the same reason the real `IRegistryService` row writes only under
`HKCU:\Software\HDT-Contract-Test-<guid>`, removed in `AfterAll`; nothing in the
suite writes under `HKLM`.

**`New-HDTDeploymentPassword`** — 16 to 127 characters, default 24, over a
72-character alphabet:

```
A-Z   a-z   0-9   ! # $ * + - = ? @ _
```

Every excluded character is excluded for a reason: `& < > " '` break
`unattend.xml`; `%` breaks `%Var%` expansion; `^ | \ /` and space break a command
line. A password that cannot survive being handled is worse than a shorter one,
and the cost is small — 72 over 24 positions is about 148 bits. One character is
drawn from each of the four classes **by construction** and the result is
Fisher-Yates shuffled, so Windows complexity is guaranteed rather than likely and
there is no retry loop to bias the distribution. Bytes are drawn one at a time
from the injected RNG with **rejection sampling**; the source is asserted to
contain no `Get-Random`, no `GetInt32` (it does not exist under 5.1) and none of
`Write-HDTLog`/`Write-Host`/`Write-Verbose`/`Write-Debug`/`Write-Output`.

Two new fakes: `New-HDTFakeLsaService` and `New-HDTFakeRandomNumberGenerator`,
both journalled and both added to `FakeJournal.Tests.ps1`'s enumeration.

### Task 3 — arming, reading, tearing down

`c2cdb19` (RED, 96 failing) → `acb946d` (GREEN)

**`Set-HDTAutoLogon`** writes, in order:

| Where | Value | Type |
|---|---|---|
| `…\Windows NT\CurrentVersion\Winlogon` | `AutoAdminLogon` = `1` | String |
| " | `DefaultUserName` | String |
| " | `DefaultDomainName` (or `''`) | String |
| " | `AutoLogonCount` = `-RemainingLeg` | DWord |
| " | `DefaultPassword` | **removed, unconditionally** |
| LSA | `DefaultPassword` | — |
| `…\Windows\CurrentVersion\RunOnce` | `HDTResume` = `-ResumeCommand` | String |

`$Password` appears in **exactly two lines of the file**: the parameter
declaration and `$Lsa.SetSecret($secretName, $Password)`. The registry
`DefaultPassword` is removed rather than left alone because an image or another
tool may have put one there and the guarantee is about the machine, not about
what this function wrote. `-RemainingLeg` is at least 1 and is literal, per S8.
Arming is idempotent — every write is a set, so re-arming before each `Restart`
step converges. It updates `-State`'s `autoLogon` block but **does not save it**;
the caller owns the write order. `SupportsShouldProcess`: `-WhatIf` writes
nothing, registry or LSA or state or log.

**`Get-HDTAutoLogonState`** returns `Armed`, `UserName`, `DomainName`, `Count`,
`HasRegistryPassword`, `HasLsaSecret`, `RunOnceCommand`. Both secrets are
booleans and neither value is returned. `Armed` is false for `AutoAdminLogon=0`,
which is precisely what S8 saw Windows leave behind.

**`Clear-HDTAutoLogon`** runs the nine DESIGN 4.5.3 items, each **independently
wrapped**, and returns `@{ Cleared = [string[]]; Failed = [object[]] }` rather
than throwing:

1. `AutoAdminLogon` 2. `DefaultUserName` 3. `DefaultDomainName`
4. `DefaultPassword` (registry) 5. `DefaultPassword` (LSA secret)
6. `AutoLogonCount` 7. `RunOnce\HDTResume` 8. the staged unattend files
9. `deploymentPassword` in the state, then the save

`Cleared` lists only what was actually present, so an already-clear machine
returns two empty lists and does not throw. The LSA secret — the artifact worth
most — is attempted before the `RunOnce` entry and the files, and a test proves it
is still removed when an earlier registry item throws.

**`Get-HDTAutoLogonArtifact`** (in `HDTTestTools`, because it inspects services
rather than being one) lists survivors under stable names: the five registry
value names, `LsaSecret:DefaultPassword`, `RunOnce:HDTResume`, `Unattend:<path>`
and `DeploymentPassword`. A zero-length LSA secret is **not** reported — S8 showed
Windows blanking rather than deleting it, and that is a disarmed machine.

### Task 4 — the boot-time reconcile

`2b2b66f` (RED, 37 failing) → `bfb3fbd` (GREEN)

`Invoke-HDTBootReconciliation`, four outcomes:

| Condition | Action | Reason |
|---|---|---|
| the state file does not exist | Teardown | `no state document` |
| it cannot be read or parsed | Teardown | `unreadable state document` |
| `Succeeded` or `Failed` | Teardown | `run finished` |
| `Running` but stale past `-MaxAgeHour` (12) | Teardown | `run abandoned` |
| otherwise | Resume | `resuming at step <n>` |

Teardown disarms through `Clear-HDTAutoLogon` and **only then** removes the state
file, so a crash between the two leaves a disarmed machine rather than an armed
one with nothing left to reconcile against. It does not try to remove a file that
was not there. Resume increments `leg`, logs `reboot.resume`, and **runs no
step** — the caller does that, which is 03-04's `Start-HDTResume.ps1`.

The unreadable branch is the one place `Import-HDTRunState`'s throw is caught, and
it is the only swallowed exception in the function, so the parse message is logged
at `Warning`. Every time reading goes through the injected clock, asserted by
grepping the file.

## Test results

Actual output, both engines, after the final commit:

| Leg | Result |
|---|---|
| `pwsh -NoProfile -File ./build.ps1 -Task ci` | **2369 passed, 0 failed, 24 skipped** — lint 0 diagnostics across 173 files, selfcheck 4 of 4 |
| `powershell.exe -NoProfile -File ./build.ps1 -Task test` | **2293 passed, 0 failed, 100 skipped** |

The autologon block alone: **399 passed, 0 failed** across
`New-HDTDeploymentPassword`, `Set-HDTAutoLogon`, `Get-HDTAutoLogonState`,
`Clear-HDTAutoLogon`, `Get-HDTAutoLogonArtifact` and
`Invoke-HDTBootReconciliation`.

The opt-in real LSA row, run by hand with `HDT_ALLOW_LSA_TEST=1` in an elevated
session on **both** engines: 17 passed, 7 skipped (the seven skipped are the write
Context, which the real row must never reach). It wrote nothing.

## ROADMAP M2 coverage — and what is NOT covered

**Proven here:** two of the four teardown scenarios.

- after an **abandoned** run (state present but stale)
- after a run whose state document is **missing entirely**
- (and, beyond the plan, after a **corrupt** state document)

Each ends in `Get-HDTAutoLogonArtifact … | Should -BeNullOrEmpty`.

**NOT proven here — they belong to 03-04:** teardown after a **successful** run
and after a **failed** run. Those run from the `finally` around the sequence loop,
which 03-04 builds. This plan built the reconcile and the checklist; it did not
build the thing that calls the checklist at sequence end.

Also covered: a different password every run (200 generated, 200 distinct),
`AutoLogonCount` matching the remaining legs, and idempotent arming.

## Deviations from plan

**1. [Rule 1 - Bug] `0xC0000034` is a negative Int32 in PowerShell**

- **Found during:** Task 2, verifying the real adapter by hand after GREEN.
- **Issue:** `NotFound = 0xC0000034` in the adapter's property bag parsed as
  Int32 `-1073741772`, because PowerShell narrows a hex literal that fits in 32
  bits. Compared against the `[uint32]` an LSA call returns it was silently
  false, so **every "the secret does not exist" turned into a `Win32Exception`**
  instead of `$null`. The unit suite could not catch it — the fake has no
  NTSTATUS — and the contract row that would have is skipped by default.
- **Fix:** written in decimal as `[uint32] 3221225524`, with the reason in a
  comment so nobody "tidies" it back to hex. Verified on both engines.
- **Commit:** `5534447`

**2. [Rule 1 - Bug] the unary comma is wrong in a function**

- **Found during:** Task 3, first GREEN run (3 failures).
- **Issue:** `Get-HDTAutoLogonArtifact` returned `, [string[]] $x`. README F3
  makes that comma mandatory in an array-returning **ScriptMethod**; in a
  function it emits one object that happens to be an array, so `@(...)` around
  the call yields a single nested element and every count assertion read 1.
- **Fix:** comma removed, with the distinction written into the file.
- **Commit:** `acb946d`

**3. [Rule 3 - Blocking] `Clear-HDTAutoLogon` needed `-Clock`**

The plan's signature omits it, but item 9 saves the state and
`Save-HDTRunState` requires a clock. Added as an optional parameter, used only
when `-StatePath` is also given. `Invoke-HDTBootReconciliation` does not pass it,
because the reconcile deletes the state file rather than saving it.

**4. [Rule 2 - Security] a recorded operation redacts a secret**

`SetSecret` records `@($Name, '<redacted>')` on both implementations, which is a
deliberate exception to README section 4's "the arguments, in declaration order".
`$Operations` is printed verbatim in a Pester failure message, and the one secret
HDT holds does not belong in a test report any more than it belongs in the
registry. Written into README section 4 and asserted by a contract test.

**5. [Rule 4-adjacent, decided and documented] `-Password` stays `[string]`**

PSScriptAnalyzer raised `PSAvoidUsingUsernameAndPasswordParams` (Error) and
`PSAvoidUsingPlainTextForPassword`. Both are suppressed, with the reasoning in a
comment above the param block rather than only in this summary:
`LsaStorePrivateData` takes an `LSA_UNICODE_STRING`, so a `SecureString` would be
unwrapped to plaintext inside the process on every call, and DESIGN 4.5.2 already
requires the value to sit in cleartext in `state.json`. A `PSCredential` would
move the plaintext, not remove it, while making the path harder to test and
adding a marshalling step that differs between the two engines. What protects
this value is the design — random per deployment, never in the registry, the log,
a report or a recorded operation, and deleted by teardown — and those are the
properties the tests assert.

**6. [test defect] a test that passed before the code existed**

`It 'rejects a remaining leg count below 1'` was green on its first run, against
`CommandNotFoundException` — exactly README section 12's trap. It now asserts
`$record.FullyQualifiedErrorId -like 'ParameterArgumentValidationError*'`.

**7. Additions beyond the plan's test list**

The corrupt-state teardown scenario, `New-HDTFakeRandomNumberGenerator` as a
journalled fake rather than an inline double, `GetValueType` returning `$null`
for an absent value, and "does not report an LSA secret that Windows blanked" —
the last one directly from S8.

## Carried debt and gaps

- **DESIGN 4.5.3's second half is a phase 07 item.** "It then applies the final
  Administrator password policy: rotate, hand off to LAPS, or disable the
  account." That needs a step type M2 does not ship. `Clear-HDTAutoLogon` says so
  in its own help. **03-05's docs task must add it to `docs/ROADMAP.md` M6.**
- **Carried from 03-01, still open:** DESIGN 4.4.2 documents eleven event names,
  the engine validates thirteen. 03-05's docs task writes both in.
- **Two of four M2 teardown scenarios are 03-04's**, as set out above.
- `New-HDTLsaService.SetSecret` and `RemoveSecret` have **never been executed** —
  by design, since no test may write an LSA secret. Only `GetSecret` has run
  against real LSA. The write path's first real exercise will be a VM in phase
  04 or 05.
- The real `IRegistryService.RemoveKey` throwing for children without recurse is
  **not** in the contract: probed by hand under 5.1, `Remove-Item` raises a
  `NullReferenceException` there rather than a useful one, and a contract test
  that could prompt is worse than a documented gap. The fake's behaviour is
  asserted in its own unit test.

## Next

03-04 builds the sequence loop: the `finally` teardown that closes the other two
M2 scenarios, `-RemainingLeg` computed as the number of `Restart` steps left plus
one, `Start-HDTResume.ps1` around `Invoke-HDTBootReconciliation`, and the state
save that must immediately follow every `Set-HDTAutoLogon`.

`.planning/STATE.md` does not exist in this repository, so the state-update step
was skipped, as in 03-02.

## Self-Check: PASSED

All 16 claimed files exist on disk. All 8 claimed commits exist in
`git log --all`. Both artifact `min_lines` thresholds are met:
`Set-HDTAutoLogon.ps1` 197 lines (>= 110), `Clear-HDTAutoLogon.ps1` 227 (>= 110).
Both build legs were run and their output read: pwsh `ci` exit 0 with
2369 passed / 0 failed, `powershell.exe test` exit 0 with 2293 passed / 0 failed.
