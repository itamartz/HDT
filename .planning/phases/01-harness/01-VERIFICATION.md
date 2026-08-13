---
phase: 01-harness
verified: 2026-08-13T00:00:00Z
status: human_needed
score: 6/7 must-haves verified
gaps:
  - truth: "./build.ps1 test runs green on a clean clone locally AND in CI"
    status: partial
    reason: >-
      The local half is fully proven on a real git clone --local under both
      engines. The CI half has never executed: git remote -v is empty, so the
      GitHub Actions workflow has never run. The workflow file exists and is
      asserted by 11 contract tests, but an unexecuted workflow is not a green CI.
    artifacts:
      - path: ".github/workflows/ci.yml"
        issue: "Well-formed and contract-tested, but never executed - no git remote exists"
    missing:
      - "Add a git remote and push main, then observe both matrix legs (pwsh, powershell) green"
      - "Confirm PSScriptAnalyzer 1.25.0 imports under Windows PowerShell 5.1 on windows-latest"
human_verification:
  - test: "git remote add origin <url>; git push -u origin main; watch the CI run"
    expected: "Both matrix legs (pwsh and powershell) exit 0 on ./build.ps1 -Task ci, including lint and selfcheck"
    why_human: "Requires a GitHub remote and credentials; cannot be executed from this machine"
---

# Phase 01: Harness Verification Report

**Phase Goal:** Make it impossible to add untested or misnamed code. Module
skeleton, Pester 5 harness, PSScriptAnalyzer, build script, CI workflow,
hand-written fakes, and the Verb-HDTNoun naming contract test.

**Verified:** 2026-08-13
**Status:** human_needed (one exit-criterion half is externally blocked)
**Re-verification:** No - initial verification
**Method:** Every result below was produced by running the code. No claim in any
SUMMARY.md was accepted on trust; the RED commits were checked out and re-run,
and the enforcement contracts were mutation-tested.

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Suite green on a clean clone under pwsh 7 | VERIFIED | git clone --local then ./build.ps1 -Task test = **323 passed, 0 failed, 9 skipped, exit 0** |
| 2 | Suite green on a clean clone under powershell.exe 5.1 | VERIFIED | Same clone: **318 passed, 0 failed, 14 skipped, exit 0** |
| 3 | TDD followed - tests precede implementation | VERIFIED | 6 RED commits checked out and re-run: every one genuinely red; each following GREEN commit genuinely green |
| 4 | Verb-HDTNoun naming contract exists and actually blocks | VERIFIED | Mutation test: a misnamed function turned the suite red with a file:line message |
| 5 | PSScriptAnalyzer clean and actually blocks | VERIFIED | lint: 0 diagnostics across 38 files; mutation produced 3 diagnostics and exit 1 |
| 6 | No engine code touches hardware / filesystem / registry directly | VERIFIED | src/ holds 2 pure functions plus a loader; zero direct CIM/DISM/registry/disk calls |
| 7 | Suite green **in CI** on a clean clone | **FAILED** | No git remote; the workflow has never executed |

**Score: 6/7**

---

## 1. Exit Criteria (docs/ROADMAP.md M0)

> **Exit:** `./build.ps1 test` runs green locally and in CI on a clean clone.

Verified on a fresh `git clone --local` of committed state (de382ce), working
tree clean, in a scratch directory:

| Run | Engine | Result | Exit |
|---|---|---|---|
| `./build.ps1 -Task test` | pwsh 7.5.8 | 323 passed, 0 failed, 9 skipped | **0** |
| `./build.ps1 -Task test` | powershell.exe 5.1.26100.8655 | 318 passed, 0 failed, 14 skipped | **0** |
| `./build.ps1 -Task ci` | pwsh 7.5.8 | clean/build/lint (0 diag, 38 files)/test/selfcheck 4-of-4 | **0** |
| `./build.ps1 -Task selfcheck` | powershell.exe 5.1 | 3 of 4 checks passed, analyzer skipped | **0** |
| `./build.ps1 -Task ci` | powershell.exe 5.1 | fails at **lint only** | 1 |

**The local half of the exit criterion is met.** The `test` task - which is what
the criterion names - exits 0 on a clean clone under both engines.

The `ci` failure under 5.1 is **not a code defect**. It was independently
reproduced outside the build script: this machine lists PSScriptAnalyzer 1.24.0
and 1.18.3 only inside another module's RequiredModules tree, and a bare
`Import-Module PSScriptAnalyzer` under 5.1 fails with "no valid module file was
found". build.ps1 correctly distinguishes listed from importable via
`Test-HDTModuleAvailable` and emits an actionable message rather than crashing.
`selfcheck` still exits 0 under 5.1, so the failure is confined to analyzer
availability exactly as documented.

**The CI half is NOT met and cannot be met from here.** `git remote -v` is empty.
This is recorded honestly in the 01-04 summary and in .planning/ROADMAP.md, and
is the phase's outstanding user_setup item.

---

## 2. TDD Verification (git history, empirically re-run)

Commit ordering alone can be staged. So each RED commit was **checked out in the
clone and its suite actually re-run**:

| RED commit | Measured at RED | GREEN commit | Measured at GREEN |
|---|---|---|---|
| e3cbc35 test(01-01) module skeleton | **0 passed / 29 failed** | e6e8802 | 29 / 0 |
| 1d070a5 test(01-01) HDTTestTools | **29 passed / 25 failed** | 7674a27 | 54 / 0 |
| 603d6d9 test(01-02) discovery + naming | **54 passed / 33 failed** | 72f623e | 86 / 0 |
| 0f4018c test(01-04) Test-HDTModuleAvailable | **278 passed / 7 failed** | d7419ad | 287 / 0 |
| 7286a61 test(01-04) harness self-proof | **292 passed / 14 failed** | c7ad906 | 310 / 0 |
| e678f00 test(01-04) CI workflow contract | **312 passed / 11 failed** | 878dc58 | 323 / 0 |

Every RED commit is genuinely red and every GREEN commit genuinely green. The
counts match the executor summaries exactly (7 failed, 14 failed, 11 failed).
772fe23 then 1d397e8 (class members leaking into function discovery) is also a
correct test-then-fix pair.

**Ordering audit across all 21 phase-01 commits:** in every test(...) / feat(...)
pair the test file lands first. No implementation file appears in a commit before
the test covering it.

**One deviation, since accepted:** 9634cf5 chore(01-01) added build.ps1,
PSScriptAnalyzerSettings.psd1 and README.md with no preceding failing test.
build.ps1 is a task runner, not a thin adapter, so it does not fall under the
stated exemption. It was retro-covered in plan 01-04 by
tests/unit/HarnessSelfCheck.Tests.ps1 (context "build.ps1 wires the self-check
in", 5 tests asserting the task list, the ci chain, the tests/selfcheck exclusion
via AST, and a real exit-0 invocation), and build.ps1 is inside Get-HDTSourceFile,
so it is bound by the naming, 5.1 and analyzer contracts. Net: covered now, but
not written test-first. Recorded, not waived.

**Spec integrity check:** 215af0b modified docs/DESIGN.md in the same commit as
the naming contract. Reviewed the diff - it corrects DESIGN 15.1's stated pattern
from `^[A-Z][a-z]+-HDT[A-Z]` to `^[A-Z][a-zA-Z]*-HDT[A-Z]` because the original
rejected `ConvertTo-HDTReport`, which the same section blesses three lines above.
The change **tightens** enforcement (adds "matched case-sensitively"). This is a
genuine contradiction fix, not spec-fitting to hide a failure.

---

## 3. Both Engines

Both engines run the identical 332-test discovery. The skip deltas were audited
from the NUnit XML and are all legitimate engine-conditional splits:

- pwsh 7, 9 skipped: 5.1-only classification tests (`??` and friends are parse
  errors under 5.1 but ordinary AST nodes under 7) plus one parse-error test.
- 5.1, 14 skipped: the mirrored PS7-only classification tests, **plus 3 analyzer
  tests** skipped because PSScriptAnalyzer is not importable by this edition on
  this machine.

No test is skipped on *both* engines, so nothing hides in the gap. The 3 analyzer
tests are the only assertions that never run locally under 5.1; CI installs PSSA
for both editions and would run them.

---

## 4. Naming Contract - Mutation Tested

tests/contract/Naming.Contract.Tests.ps1 covers **37 source files / 20 functions**
(src/, tests/ excluding fixtures, and build.ps1), with anti-vacuity guards
(more than 0 files, more than 9 functions) so it cannot silently pass on an
empty set.

**Mutation:** added src/Hephaestus/Public/Get-BadlyNamedThing.ps1 to the clone.
Result - **2 failed, exit 1**:

```
Naming contract (DESIGN 15.1).names every function Verb-HDTNoun with an approved verb
  Expected 0, because src/Hephaestus/Public/Get-BadlyNamedThing.ps1:1
  Get-BadlyNamedThing does not match ^Verb-HDTNoun (uppercase HDT required,
  approved verb, noun starting with a capital), but got 1.
```

**Precision probe** of Test-HDTFunctionName / Get-HDTFunctionNameViolation:

| Name | Verdict |
|---|---|
| Get-HDTThing, New-HDTBootIso, Remove-HDTItem | valid |
| Get-hdtThing, Get-HdtThing | rejected - uppercase HDT enforced |
| Frobnicate-HDTThing | rejected - "is not an approved verb (Get-Verb)" |
| get-HDTThing, Get-HDTthing, GetHDTThing, Get-Thing | rejected |
| Get-HDTThings | **accepted (plural)** - see issue I-3 |

The contract also enforces DESIGN 15.1's DefaultCommandPrefix prohibition and
DESIGN 15.2's no-aliases rule (AST-based, so naming Set-Alias in a string is not
a false hit). Engine exports exactly Get-HDTModuleVersion; Test-HDTSchemaVersion
does not leak; zero aliases, cmdlets and variables exported.

---

## 5. PSScriptAnalyzer

`lint: 0 diagnostics across 38 file(s)` on a clean clone under pwsh 7.
PSScriptAnalyzerSettings.psd1 has Severity = Error, Warning, **ExcludeRules = @()**
(nothing suppressed), and PSUseCompatibleSyntax targeting 5.1 and 7.0.

**Mutation:** added a correctly-named, 5.1-legal but dirty function. lint reported
PSAvoidUsingWriteHost, PSAvoidUsingInvokeExpression and
PSUseDeclaredVarsMoreThanAssignments, then **exit 1**. The test task caught it too
(HarnessSelfCheck asserts the repository sources are analyzer-clean), so analyzer
cleanliness is enforced in two independent places.

**Mutation (5.1 syntax):** added `$Value ?? 'fallback'` to a private engine file.
The compatibility contract failed with
`src/Hephaestus/Private/Test-HDTMutant.ps1:5:22 [NullCoalescing] PowerShell
7-only operator '??' is not permitted (DESIGN 1 ...)` under pwsh, and under 5.1
the module could not even load - 20 failures. Exit 1 on both engines.

**Harness self-proof** (build.ps1 -Task selfcheck) passed 4/4 on pwsh: a
deliberately failing test is detected, a passing one passes, a **child process**
running the red fixture exits non-zero (the exit-code path CI depends on, which
cannot be observed in-process), and the analyzer bait produces 4 diagnostics
including PSUseCompatibleSyntax.

---

## 6. Injected Services / No Direct Hardware Access

src/ scanned for Get-CimInstance, Get-WmiObject, Invoke-CimMethod, Dism,
Get-/Set-ItemProperty, New-PSDrive, Get-Disk, Get-Partition, reagentc, bcdboot,
oscdimg - **zero matches**.

Engine surface is Get-HDTModuleVersion (reads its own module version) and
Test-HDTSchemaVersion (pure integer comparison). Hephaestus.psm1 uses
Get-ChildItem to dot-source its own Public/ and Private/ folders - that is the
module bootstrap, not step or engine logic, and cannot be injected. Both
Set-StrictMode -Version Latest and $ErrorActionPreference = 'Stop' are present.

The fakes are real, not stubs: HDTFakes.psm1 is 475 lines. New-HDTFakeFileSystem
exposes an 8-method IFileSystem plus SeedFile/SeedDirectory/GetOperationName;
verified live that it is OrdinalIgnoreCase (wrote C:\x\a.txt, read C:\X\A.TXT),
throws a real System.IO.FileNotFoundException, and records operations **including
calls that then threw** (WriteAllText, ReadAllText, ReadAllText).
New-HDTFakeCimProvider throws naming the class for an unseeded one. Both service
contract suites use a discovery-time implementation registry, so a real adapter in
phase 02 is a one-row addition.

---

## Issues

| # | Severity | Issue |
|---|---|---|
| **G-1** | **Blocker for the CI half of the exit criterion** | GitHub CI has never executed - git remote -v is empty. ci.yml is well-formed (windows-latest, matrix pwsh+powershell, fail-fast false, pinned Pester 5.7.1 / PSSA 1.25.0 / powershell-yaml 0.4.12, if-always artifact upload) and asserted by 11 contract tests, but a workflow that has never run is not a green CI. |
| I-2 | Info | -Task ci exits 1 under 5.1 **on this machine only**, at the lint step. Independently confirmed as an environment condition (PSSA listed but not importable), not a code defect. CI installs PSSA for both editions - unproven until G-1 is closed. |
| I-3 | Info | Plural nouns pass the naming contract (Get-HDTThings accepted). DESIGN 15.1's *mandatory* enforced pattern does not require singular; "singular nouns" appears only in DESIGN 15.2 style conventions and CLAUDE.md. The implementation matches DESIGN 15.1 exactly. Unenforced convention, not a contract breach. |
| I-4 | Info / forward risk | **No automated contract prevents future engine code from calling DISM/CIM/registry/filesystem directly.** The rule holds trivially today because src/ has no such code. The service *contracts* verify implementations conform, but nothing scans src/ for forbidden direct calls the way Get-HDTMdtDependency scans for MDT terms. Recommend adding a direct-call contract in phase 02 when Get-HDTCimFact and the real CIM adapter land, with an adapter allow-list. |
| I-5 | Cosmetic | M0 lists schemas/ and samples/ as repo structure; both are empty and therefore absent from a clean clone (git does not track empty directories). |
| I-6 | Info | build.ps1 was added without a preceding failing test (9634cf5); retro-covered in 01-04. See the TDD section. |

---

## Verdict

The phase goal - *make it impossible to add untested or misnamed code* - **is
achieved, and was proven by mutation rather than assumed**. Three independent
enforcement layers (naming contract, 5.1 syntax contract, PSScriptAnalyzer) were
each deliberately violated and each blocked with an actionable file:line message
and a non-zero exit code, on both engines. The harness has watched itself go red.
Anti-vacuity guards prevent the contracts degrading into silent passes.

The executor summaries were checked against reality and found **accurate**,
including the failure counts and the honest disclosure of the CI gap.

The single outstanding item is external: **add a git remote, push, and observe
both CI legs green.** Until then the "and in CI" half of M0's exit criterion is
unproven.

---

_Verified: 2026-08-13_
_Verifier: Claude (gsd-verifier)_
