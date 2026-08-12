---
phase: 01-harness
plan: 04
subsystem: testing
tags: [pester, selfcheck, psscriptanalyzer, github-actions, ci, exit-codes, clean-clone]

# Dependency graph
requires:
  - phase: 01-harness plan 01
    provides: build.ps1 task runner, Run.Path restricted to tests/unit + tests/contract, PSScriptAnalyzerSettings.psd1
  - phase: 01-harness plan 02
    provides: Get-HDTSourceFile and the naming / PS5.1 / no-MDT contracts, which now cover the new files automatically
  - phase: 01-harness plan 03
    provides: the fakes and service contracts that the ci chain runs
provides:
  - "build.ps1 -Task selfcheck - Invoke-HDTSelfCheck, four checks, the harness proving itself"
  - "tests/selfcheck/DeliberateFailure.Tests.ps1 - the permanently red fixture"
  - "tests/selfcheck/DeliberatePass.Tests.ps1 - the permanently green fixture"
  - "tests/fixtures/analyzer/AnalyzerBait.ps1 - four deliberate PSScriptAnalyzer violations"
  - "Test-HDTModuleAvailable - one definition of 'available means importable', used by lint, selfcheck and tests"
  - ".github/workflows/ci.yml - windows-latest, matrix over pwsh and powershell (5.1), no fail-fast"
  - "tests/unit/HarnessSelfCheck.Tests.ps1 - 17 assertions over the self-proof and its two load-bearing exclusions"
  - "tests/unit/CiWorkflow.Tests.ps1 - 11 assertions over the workflow file"
  - "tests/helpers/README.md section 9 - why the red fixtures are red and must stay excluded"
affects: [02-rules, 03-sequence-engine, 04-imaging, 05-bootimage, 06-drivers, 07-apps-fullos, 08-capture-media, 09-console]

# Tech tracking
tech-stack:
  added:
    - "GitHub Actions (windows-latest), matrix over shell: [pwsh, powershell]"
  patterns:
    - "Availability of an optional module means importable, not listed: Test-HDTModuleAvailable, never Get-Module -ListAvailable alone"
    - "Deliberately red fixtures live in tests/selfcheck, which is never in Run.Path; deliberately dirty ones live in tests/fixtures, which Get-HDTSourceFile excludes"
    - "Exit-code behaviour is asserted by spawning (Get-Process -Id $PID).Path so the child runs the same PowerShell edition as the test"
    - "build.ps1 structure is asserted through the AST (ValidateSet, $canonicalOrder, Invoke-HDTTest string literals), not by regex over the file"
    - "-Skip: conditions are computed at discovery time at script scope, because Pester evaluates -Skip while discovering"
    - "GitHub Actions YAML is asserted as an object for jobs/strategy/steps and as raw text for triggers - ConvertFrom-Yaml maps the 'on' key to the boolean $true"
    - "CI runs ./build.ps1 -Task ci and nothing else; CI never grows private build logic (DESIGN 12.2.5)"

key-files:
  created:
    - tests/selfcheck/DeliberateFailure.Tests.ps1
    - tests/selfcheck/DeliberatePass.Tests.ps1
    - tests/fixtures/analyzer/AnalyzerBait.ps1
    - tests/unit/HarnessSelfCheck.Tests.ps1
    - tests/unit/CiWorkflow.Tests.ps1
    - tests/unit/Test-HDTModuleAvailable.Tests.ps1
    - tests/helpers/HDTTestTools/tools/Test-HDTModuleAvailable.ps1
    - .github/workflows/ci.yml
  modified:
    - build.ps1
    - tests/helpers/HDTTestTools/HDTTestTools.psd1
    - tests/helpers/README.md
    - README.md
    - .planning/ROADMAP.md

key-decisions:
  - "Get-Module -ListAvailable is not an availability test: under 5.1 on this machine PSScriptAnalyzer is listed via another module's RequiredModules tree and still fails to import. Test-HDTModuleAvailable attempts the import and is now the single definition used by lint, selfcheck and every -Skip condition"
  - "Check 3 of the self-check spawns a child process because Pester's Run.Exit path calls exit; it cannot be observed from inside the run being tested"
  - "The child process is (Get-Process -Id $PID).Path, so the 5.1 leg proves 5.1 rather than silently proving pwsh twice"
  - "selfcheck is appended to the canonical order clean -> build -> lint -> test, so ci ends by proving the harness that produced the preceding green result"
  - "Invoke-HDTSelfCheck warns and continues when PSScriptAnalyzer is unimportable rather than failing, because 'test' passing under 5.1 is the M0 exit criterion and selfcheck must not become a second lint"
  - "The analyzer bait contains ?? and is therefore a parse error under 5.1: it is excluded from Get-HDTSourceFile and only ever read by Invoke-ScriptAnalyzer under pwsh 7. HarnessSelfCheck.Tests.ps1 asserts that exclusion so a future widening of the source set turns the suite red"
  - "Workflow triggers are asserted against raw text: ConvertFrom-Yaml applies YAML 1.1 and turns the GitHub Actions 'on' key into the boolean $true"
  - "CI pins Pester 5.7.1, PSScriptAnalyzer 1.25.0 and powershell-yaml 0.4.12 to the versions verified locally, so a gallery update cannot turn CI red without a deliberate change"

# Metrics
duration: 65min
completed: 2026-08-13
---

# Phase 01 Plan 04: Harness self-proof, CI, and the M0 exit criterion Summary

**The harness now proves itself on every `ci` run — it watches a deliberately failing test fail, a deliberately passing test pass, a red run propagate a non-zero process exit code, and PSScriptAnalyzer flag a deliberately dirty file including `PSUseCompatibleSyntax` — and that same entry point runs on `windows-latest` under both PowerShell editions; the M0 exit criterion was demonstrated on a genuine `git clone --local` with `pwsh test=0  win test=0  pwsh ci=0`.**

## The four clean-clone exit codes (the M0 exit criterion)

Run from a `git clone --local` of the committed state, so nothing untracked on
this machine could contribute:

| Command | Exit code | Verdict |
|---|---|---|
| `pwsh.exe -NoProfile -File ./build.ps1 -Task test` | **0** | required, met |
| `powershell.exe -NoProfile -File ./build.ps1 -Task test` | **0** | required, met |
| `pwsh.exe -NoProfile -File ./build.ps1 -Task ci` | **0** | required, met |
| `powershell.exe -NoProfile -File ./build.ps1 -Task ci` | **1** | expected on this machine only |

The `win ci=1` is the `lint` step and nothing else. Its message is the designed
one from plan 01-01:

```
PSScriptAnalyzer is not available to this PowerShell edition
(PowerShell 5.1.26100.8655, Desktop). Run: Install-Module PSScriptAnalyzer
-Scope CurrentUser. The 'test' task does not require it.
```

`test` and `selfcheck` both pass under 5.1 in that same clean clone (verified
separately: `win selfcheck exit=0`), so the failure is confined to analyzer
availability. CI installs PSScriptAnalyzer into both editions' `CurrentUser`
module paths, so the `powershell` leg runs `lint` there.

## The self-check, check by check, on both engines

`build.ps1 -Task selfcheck`, clean clone, actual output:

**pwsh 7.5.8 — exit 0**
```
selfcheck 1 PASS: the deliberately failing test was detected (1 failed)
selfcheck 2 PASS: the deliberately passing test passed (1 passed)
selfcheck 3 PASS: a red run exits non-zero (exit code 1)
selfcheck 4 PASS: analyzer reported 4 diagnostic(s) for the bait fixture, including PSUseCompatibleSyntax
selfcheck: 4 of 4 checks passed
```

**Windows PowerShell 5.1.26100.8655 — exit 0**
```
selfcheck 1 PASS: the deliberately failing test was detected (1 failed)
selfcheck 2 PASS: the deliberately passing test passed (1 passed)
selfcheck 3 PASS: a red run exits non-zero (exit code 1)
WARNING: selfcheck 4 SKIP: PSScriptAnalyzer cannot be imported by this edition
         (PowerShell 5.1.26100.8655, Desktop), so the analyzer leg was not
         proven here. CI installs it for both editions.
selfcheck: 3 of 4 checks passed, analyzer check skipped for this edition
```

Check 3 is the one that could not be faked from inside a Pester run: Pester's
`Run.Exit` path calls `exit`, so the only way to observe it is a child process.
The child is `(Get-Process -Id $PID).Path`, so under 5.1 the exit-code path
actually proven is 5.1's.

The bait fixture produces exactly what plan 01-04 predicted:

| Severity | Rule | Line |
|---|---|---|
| Error | `PSUseCompatibleSyntax` | 16 |
| Warning | `PSAvoidUsingWriteHost` | 17 |
| Warning | `PSAvoidUsingCmdletAliases` | 18 |
| Warning | `PSAvoidUsingCmdletAliases` | 18 |

The `PSUseCompatibleSyntax` Error is the important one: it proves
`TargetVersions = @('5.1', '7.0')` in `PSScriptAnalyzerSettings.psd1` is in
force, not merely declared.

## The self-proof was itself watched failing

Asserting that a self-check works is worth nothing if nobody has broken it. The
deliberately failing fixture was temporarily edited to pass
(`Should -BeFalse` -> `Should -BeTrue`):

| Observation | Result |
|---|---|
| `pwsh ./build.ps1 -Task selfcheck` | **exit 1**, `selfcheck 1 FAIL: a deliberately failing test was not detected` |
| `powershell ./build.ps1 -Task selfcheck` | **exit 1** |
| `tests/unit/HarnessSelfCheck.Tests.ps1` | 13 passed, **4 failed** |

Reverted with `git checkout --`; `git status` clean afterwards.

## TDD record — every run executed, RED before GREEN

Eight commits, RED-before-GREEN visible in `git log`:

| Commit | Kind | Evidence |
|---|---|---|
| `0f4018c` | RED | `Test-HDTModuleAvailable` tests: **0 passed / 7 failed** |
| `d7419ad` | GREEN | **7 passed / 0 failed** under pwsh 7 *and* 5.1 |
| `7d390b7` | REFACTOR | `Invoke-HDTLint` now asks `Test-HDTModuleAvailable`; pwsh lint exit 0, 5.1 lint exit 1 with the same message as before |
| `7286a61` | RED | harness self-proof tests: **3 passed / 14 failed** |
| `c7ad906` | GREEN | **17 passed / 0 failed**; `selfcheck` exit 0 on both engines |
| `e678f00` | RED | CI workflow contract: **0 passed / 11 failed** |
| `878dc58` | GREEN | **11 passed / 0 failed** on both engines |
| `a53d0ea` | docs | README, `tests/helpers/README.md` section 9, `.planning/ROADMAP.md` |

The three tests green in the `7286a61` RED commit are deliberate guards, not
missing coverage: "the repository sources are analyzer-clean", "the bait is
outside the source set" and "tests/selfcheck is outside `Run.Path`" describe
invariants that must be true both before and after this plan. They are stated
honestly here rather than dressed up as red.

## Suite totals (actual output, not estimates)

| Run | Result |
|---|---|
| `pwsh ./build.ps1 -Task ci` | lint 0 diagnostics across 38 files; test **323 passed, 0 failed, 9 skipped**; selfcheck 4/4; **exit 0** |
| `powershell ./build.ps1 -Task test` | **318 passed, 0 failed, 14 skipped**; **exit 0** |

The 9 skips under pwsh are pre-existing; the 14 under 5.1 are those plus the
three analyzer assertions in `HarnessSelfCheck.Tests.ps1`, correctly skipped
because the analyzer cannot be imported there, and the two edition-specific
compatibility skips from plan 01-02.

Contract suite breakdown (pwsh, 120 passed / 0 failed):

| File | Tests |
|---|---|
| `Naming.Contract.Tests.ps1` | 6 |
| `PowerShell51Compatibility.Contract.Tests.ps1` | 40 (one per source file plus guards) |
| `NoMdtDependency.Contract.Tests.ps1` | 40 |
| `FileSystemService.Contract.Tests.ps1` | 24 |
| `CimProvider.Contract.Tests.ps1` | 10 |

Repository facts at completion: **38 source files**, **20 functions**, **0
naming violations**, `Hephaestus` exports exactly `Get-HDTModuleVersion`,
`HDTFakes` exports exactly `New-HDTFakeCimProvider` and `New-HDTFakeFileSystem`.

## What was built

### `Invoke-HDTSelfCheck` (build.ps1)

Four checks, each printing one PASS/FAIL/SKIP line so a CI log is readable
without expanding anything, and each throwing a named failure that says what the
consequence is — check 3's is *"the harness does not propagate failure to the
process exit code, so CI would report green on a red suite."*

`selfcheck` is in the `-Task` `ValidateSet` and appended to `$canonicalOrder`, so
`ci` is now `clean -> build -> lint -> test -> selfcheck`. Putting it last is
deliberate: it validates the harness that produced the green result immediately
above it.

### Two exclusions that keep the red fixtures harmless

Both are asserted by `tests/unit/HarnessSelfCheck.Tests.ps1`, so widening either
one turns the suite red instead of quietly poisoning it:

1. **`tests/selfcheck` is never in `Run.Path`.** Asserted through the AST of
   `Invoke-HDTTest`: the literals `tests/unit` and `tests/contract` are present
   and no literal in that function matches `*selfcheck*`.
2. **`tests/fixtures/**` is outside `Get-HDTSourceFile`.** This one is
   load-bearing beyond tidiness: `AnalyzerBait.ps1` contains `??`, which is a
   **parse error** under Windows PowerShell 5.1. Nothing may dot-source or
   `ParseFile` it; only `Invoke-ScriptAnalyzer` under pwsh 7 ever reads it. The
   5.1 compatibility contract would otherwise fail on it — correctly, and
   uselessly.

Conversely, `tests/selfcheck/*.ps1` **is** inside `Get-HDTSourceFile`, so the two
fixtures are still lint-clean, name-checked and 5.1-parsed. A test asserts that
membership too.

### `.github/workflows/ci.yml`

`windows-latest`, `strategy.matrix.shell: [pwsh, powershell]`, `fail-fast: false`.
On a GitHub Windows runner `shell: powershell` **is** Windows PowerShell 5.1 —
that is what turns the WinPE constraint from aspiration into enforcement. The
run step is `./build.ps1 -Task ci` and nothing else, so CI cannot drift from what
developers run (DESIGN §12.2.5). Results are uploaded with `if: always()`, since
the artifacts matter most when the build failed.

Pinned module versions, matching the machine they were verified on:

| Module | Version |
|---|---|
| Pester | 5.7.1 |
| PSScriptAnalyzer | 1.25.0 |
| powershell-yaml | 0.4.12 |

The Pester pin is not cosmetic: a bare `Install-Module Pester` pulls Pester 6,
whose configuration API differs, and that hazard has already been hit on this
machine. `tests/unit/CiWorkflow.Tests.ps1` asserts the pin with
`Install-Module\s+Pester\s+-RequiredVersion\s+5\.`. The TLS 1.2 and NuGet
provider lines are required for the 5.1 leg to reach PSGallery at all.

## Deviations from plan

### 1. [Rule 3 — blocking] The plan's analyzer skip condition does not work on this machine

- **Found during:** Task 1, writing `HarnessSelfCheck.Tests.ps1`.
- **Issue:** the plan specifies
  `-Skip:(-not (Get-Module -ListAvailable PSScriptAnalyzer))`. Verified on this
  machine: under Windows PowerShell 5.1 `Get-Module -ListAvailable
  PSScriptAnalyzer` returns **`True`** (the analyzer is visible inside another
  module's `RequiredModules` tree) while `Import-Module PSScriptAnalyzer` fails
  with *"no valid module file was found in any module directory"*. The plan's own
  `verified_facts` states the analyzer is not importable under 5.1, so the two
  statements contradict each other. Using the plan's condition literally would
  have run the analyzer assertions under 5.1 and made the suite permanently red
  there — breaking the M0 exit criterion this plan exists to demonstrate.
- **Fix:** added `Test-HDTModuleAvailable` to `HDTTestTools`, test-first
  (0 passed / 7 failed, then 7 / 0 on both engines). It short-circuits on an
  already-imported module, returns `$false` for an unlisted one, and otherwise
  attempts the import and swallows the failure. Two-branch coverage is real, not
  notional: one test builds a module in `TestDrive` whose `.psm1` throws on load,
  puts it on `PSModulePath`, asserts `Get-Module -ListAvailable` finds it, and
  asserts the helper still returns `$false`.
- **Also:** `Invoke-HDTLint` was refactored onto the same helper (commit
  `7d390b7`), so `lint`, `selfcheck` and every `-Skip` share one definition of
  "available" rather than three copies of the same subtle rule.
- **Files:** `tests/helpers/HDTTestTools/tools/Test-HDTModuleAvailable.ps1`,
  `tests/helpers/HDTTestTools/HDTTestTools.psd1`,
  `tests/unit/Test-HDTModuleAvailable.Tests.ps1`, `build.ps1`.
- **Commits:** `0f4018c`, `d7419ad`, `7d390b7`.

### 2. [Rule 3 — blocking] `-Skip` is evaluated during discovery

- **Found during:** Task 1. The first version of `HarnessSelfCheck.Tests.ps1`
  computed the analyzer probe in `BeforeAll`. Pester reported
  *"Discovery ... failed with: The term 'Test-HDTModuleAvailable' is not
  recognized"* and found **0 tests** — the same discovery-phase trap plan 01-03
  hit with contract factories.
- **Fix:** the helper import and the probe moved to script scope above the
  `Describe`, with the run-phase setup repeated in `BeforeAll` because Pester 5
  discards discovery-phase variables. Same pattern the contract tests already
  use.

### 3. Two assertions strengthened beyond the plan's sketch

- `It 'throws when Name is empty'` passed in the RED commit for the wrong reason:
  a `CommandNotFoundException` satisfies a bare `Should -Throw`. Tightened to
  `Should -Throw -ErrorId 'ParameterArgumentValidationError,Test-HDTModuleAvailable'`,
  which correctly failed before the function existed.
- The plan's *"produces no analyzer diagnostics for the repository sources"*
  would also have passed in RED. A companion assertion was added tying it to this
  plan's deliverable — that `Get-HDTSourceFile` actually **contains** the two new
  `tests/selfcheck` files — so the coverage claim cannot go vacuous.

### 4. `tests/helpers/README.md` gained a section (not in `files_modified`)

The fixture headers say *"see tests/helpers/README.md"*, which was a dangling
reference. Section 9 now documents the three red/dirty fixtures, why they must
not be "fixed", and why both exclusions are load-bearing. The old section 9
became section 10.

## Verification block — all eleven checks

| # | Check | Result |
|---|---|---|
| 1 | `build.ps1 test` green on a clean clone | **PASS** — `git clone --local`, exit 0 |
| 2 | under pwsh 7 and PS 5.1 | **PASS** — `pwsh test=0`, `win test=0` |
| 3 | a deliberately failing test fails CI | **PASS** — check 1 (`FailedCount` 1) and check 3 (child exit 1); `selfcheck` is in the `ci` chain |
| 4 | a passing one passes | **PASS** — check 2 |
| 5 | analyzer violations block | **PASS** — check 4 finds 4 diagnostics incl. `PSUseCompatibleSyntax`; `Invoke-HDTLint` throws on any diagnostic |
| 6 | naming contract, > 9 functions, 0 violations | **PASS** — 20 functions, 0 violations |
| 7 | PS 5.1 compatibility contract, one It per file | **PASS** — 40 tests, green under both engines |
| 8 | no-MDT contract, one It per file | **PASS** — 40 tests, 0 hits |
| 9 | unit + contract + PSSA in CI on a Windows runner | **PASS** as a file, asserted by 11 tests — **NOT observed running on GitHub**, see below |
| 10 | fakes exported and covered by contracts | **PASS** — `New-HDTFakeCimProvider`, `New-HDTFakeFileSystem`; 34 contract tests |
| 11 | every function is `Verb-HDTNoun`, enforced | **PASS** — 0 violations over 38 files |

## Outstanding: GitHub-side CI has NOT been observed green

Stated plainly, because check 9 is the one item this plan could not finish:

- `git remote -v` on this repository is **still empty**. There is no origin, so
  `.github/workflows/ci.yml` has never executed on GitHub.
- What *is* proven: the file exists, is valid YAML, targets `windows-latest`,
  matrices over `pwsh` and `powershell`, disables `fail-fast`, pins Pester to
  5.7.1, installs PSScriptAnalyzer, invokes `./build.ps1 -Task ci`, and uploads
  results with `if: always()` — 11 assertions, green under both engines. And the
  command it runs, `./build.ps1 -Task ci`, exits 0 under pwsh from a clean clone.
- What is **not** proven: that a GitHub Windows runner can install the pinned
  modules and go green, particularly the `powershell` (5.1) leg where
  PSScriptAnalyzer must land in the Desktop-edition module path for `lint` to
  succeed. That is exactly the leg that fails locally, so it is the leg most
  worth watching.

This remains the `user_setup` item from the plan:

1. `gh repo create HDT --private --source . --push` (or add an origin manually
   and push `main`).
2. GitHub -> Actions -> CI: confirm **both** matrix legs are green.

If the `powershell` leg fails on `lint`, the fix belongs in the workflow's
install step, not in `build.ps1` — `build.ps1` behaves correctly by refusing to
lint without an analyzer.

## Notes for the next phase

- **`build.ps1 -Task ci` is the gate.** Phase 02 code is not done until it exits
  0 under pwsh and `-Task test` exits 0 under 5.1.
- **Anything added under `src/` or `tests/` is automatically covered** by naming,
  5.1 compatibility, no-MDT and lint. There is no opt-in step. The only way out
  is `tests/fixtures/`, which is for deliberately invalid material and nothing
  else.
- **`Test-HDTModuleAvailable` is the way to gate an optional dependency.**
  `powershell-yaml` is the immediate case: phase 02 parses `rules.yaml`, and it
  is available to both engines here but must not be assumed.
- **Never "fix" `tests/selfcheck/DeliberateFailure.Tests.ps1`.** It is red on
  purpose and `selfcheck` fails if it stops being red.

## Self-Check: PASSED

All created and modified files verified present on disk (13 paths), all eight
commit hashes verified in `git log`, `git status` clean, no temporary clone left
behind.
