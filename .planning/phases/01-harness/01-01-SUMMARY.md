---
phase: 01-harness
plan: 01
subsystem: testing
tags: [pester5, psscriptanalyzer, powershell-5.1, module-manifest, build-script, tdd]

# Dependency graph
requires: []
provides:
  - "src/Hephaestus module skeleton: manifest (GUID 9be61a01-0b74-4832-867d-f2b7cb51cf85), dot-source loader, one public + one private function"
  - "tests/helpers/HDTTestTools: Get-HDTSourceFile and New-HDTPesterConfiguration, imported by build.ps1 and by the contract tests"
  - "build.ps1 with clean/build/lint/test/ci tasks and explicit exit codes"
  - "PSScriptAnalyzerSettings.psd1 with PSUseCompatibleSyntax targeting 5.1 and 7.0"
  - "The pinned Pester import incantation that both engines require"
affects: [01-02, 01-03, 01-04, 02-rules, 03-sequence-engine]

# Tech tracking
tech-stack:
  added: [Pester 5.7.1 (pinned 5.0.0-5.99.99), PSScriptAnalyzer 1.25.0]
  patterns:
    - "RED-then-GREEN commit pairs: a test(...) commit precedes every feat(...) commit"
    - "Dot-source loader shape shared by the engine module and HDTTestTools"
    - "Shared BeforeAll state in test files uses $script: scope"

key-files:
  created:
    - src/Hephaestus/Hephaestus.psd1
    - src/Hephaestus/Hephaestus.psm1
    - src/Hephaestus/Public/Get-HDTModuleVersion.ps1
    - src/Hephaestus/Private/Test-HDTSchemaVersion.ps1
    - tests/helpers/HDTTestTools/HDTTestTools.psd1
    - tests/helpers/HDTTestTools/HDTTestTools.psm1
    - tests/helpers/HDTTestTools/tools/Get-HDTSourceFile.ps1
    - tests/helpers/HDTTestTools/tools/New-HDTPesterConfiguration.ps1
    - tests/unit/Module.Manifest.Tests.ps1
    - tests/unit/Module.Loader.Tests.ps1
    - tests/unit/Get-HDTModuleVersion.Tests.ps1
    - tests/unit/Test-HDTSchemaVersion.Tests.ps1
    - tests/unit/Get-HDTSourceFile.Tests.ps1
    - tests/unit/New-HDTPesterConfiguration.Tests.ps1
    - build.ps1
    - PSScriptAnalyzerSettings.psd1
    - README.md
  modified:
    - Readme.txt (deleted, replaced by README.md)

key-decisions:
  - "Engine module GUID is 9be61a01-0b74-4832-867d-f2b7cb51cf85; HDTTestTools is b5d9ae60-03f1-4c7a-9ee1-c2dc7be42dc4"
  - "Every Pester import is pinned: Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99"
  - "Shared BeforeAll state in test files uses $script: scope - Pester-idiomatic and it silences the PSUseDeclaredVarsMoreThanAssignments false positive, so ExcludeRules stays empty"
  - "Test-HDTSchemaVersion mandatory-parameter tests assert on command metadata, not on a missing-argument call, which would block on the mandatory-parameter prompt"
  - "Invoke-HDTLint treats an unimportable PSScriptAnalyzer the same as a missing one: both produce the actionable install message"

patterns-established:
  - "TDD: a test(01-01) commit that is red precedes every feat(01-01) commit"
  - "Get-HDTSourceFile is the single definition of 'HDT PowerShell source' shared by build.ps1 and the contract tests"
  - "build.ps1 owns the process exit code; Pester's Run.Exit stays disabled"

# Metrics
duration: 75min
completed: 2026-08-13
---

# Phase 01 Plan 01: Module skeleton and build harness Summary

**A Pester 5 harness that runs green under both pwsh 7.5.8 and Windows PowerShell 5.1.26100.8655 — 54 tests over a real module skeleton, a `build.ps1` with correct exit codes, and a PSScriptAnalyzer configuration that is clean at zero diagnostics.**

## Performance

- **Duration:** ~75 min
- **Tasks:** 3 of 3
- **Files created:** 17 (1 deleted)
- **Test count:** 54 passed, 0 failed — verified under both engines

## Accomplishments

- `src/Hephaestus` imports and exports exactly `Get-HDTModuleVersion`; `Test-HDTSchemaVersion` is reachable only through `InModuleScope`.
- `./build.ps1 -Task test` exits 0 under pwsh 7 and under `powershell.exe` 5.1, and exits 1 when any test fails (proved by temporarily adding a failing `It` and re-running under both engines).
- `./build.ps1 -Task ci` (clean → build → lint → test) exits 0 under pwsh 7 with **0 analyzer diagnostics across 14 files**.
- `./build.ps1 -Task lint` under 5.1 fails with the actionable message `PSScriptAnalyzer is not available to this PowerShell edition (PowerShell 5.1.26100.8655, Desktop). Run: Install-Module PSScriptAnalyzer -Scope CurrentUser. The 'test' task does not require it.` rather than a raw `Import-Module` stack.
- `HDTTestTools` gives plans 01-02 through 01-04 their two shared primitives, both already under test.

## Task Commits

1. **Task 1: Module skeleton** — `e3cbc35` (test, RED: 29 tests, 0 passed) → `e6e8802` (feat, GREEN: 29/29)
2. **Task 2: HDTTestTools** — `1d070a5` (test, RED: 54 tests, 29 passed / 25 failed) → `7674a27` (feat, GREEN: 54/54)
3. **Task 3: build.ps1, analyzer settings, README** — `5aafcd0` (refactor, analyzer cleanliness) → `9634cf5` (chore)

RED-before-GREEN ordering is visible in `git log --oneline`.

## Things plans 01-02 through 01-04 depend on

**Module GUIDs**

| Module | GUID |
|---|---|
| `Hephaestus` | `9be61a01-0b74-4832-867d-f2b7cb51cf85` |
| `HDTTestTools` | `b5d9ae60-03f1-4c7a-9ee1-c2dc7be42dc4` |

**The Pester import incantation** — mandatory everywhere, because `powershell.exe` 5.1 on this box resolves a bare `Import-Module Pester` to 6.0.0:

```powershell
Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Force
```

**`Get-HDTSourceFile -RepositoryRoot <path>`** — the single definition of "HDT PowerShell source". Returns absolute, sorted, duplicate-free paths.

| | Rule |
|---|---|
| Included | `*.ps1` and `*.psm1` anywhere under `src/`; the same under `tests/`; `build.ps1` in the repository root |
| Excluded | `tests/fixtures/**`, `out/**`, any `.git` / `bin` / `obj` directory, all `*.psd1`, and anything outside `src/`, `tests/` and the root `build.ps1` |

Currently returns **13 files**; `Invoke-HDTLint` analyses those plus `src/Hephaestus/Hephaestus.psd1` (14).

**`New-HDTPesterConfiguration [-Path] <string[]> [-ResultPath <string>] [-ExcludeTag <string[]>] [-Verbosity <string>]`** — `Run.PassThru = $true`, `Run.Exit = $false` (build.ps1 owns the exit code), `Should.ErrorAction = 'Stop'`, `Verbosity` defaults to `Detailed`, NUnitXml results only when `-ResultPath` is given.

**`build.ps1` task list** — `clean`, `build`, `lint`, `test`, `ci`. `ci` expands to `clean, build, lint, test`; tasks always run in that canonical order whatever order they are requested in. Plan 01-04 appends `selfcheck` to the `ci` expansion. Build functions: `Initialize-HDTBuildEnvironment`, `Clear-HDTBuildOutput`, `Invoke-HDTBuild`, `Invoke-HDTLint`, `Invoke-HDTTest`. Test results land at `out/testResults/pester-<edition>-<psversion>.xml`, already covered by the `/out/` entry in `.gitignore`.

## Decisions Made

- **`$script:` scope for shared test state.** PSScriptAnalyzer's `PSUseDeclaredVarsMoreThanAssignments` fires on every variable assigned in a Pester `BeforeAll` and read in an `It`, because it analyses each scriptblock separately. Verified by probe that a `$script:` qualifier suppresses it. This keeps `ExcludeRules = @()` as the plan specified instead of blanket-excluding a genuinely useful rule, and it is also the Pester-documented way to share state. **Convention for all future test files.**
- **Mandatory-parameter tests assert on metadata.** The plan's `It 'throws when SchemaVersion is not supplied'` was implemented as `It 'declares SchemaVersion as a mandatory parameter'` (plus the same for `Supported`), checking `ParameterAttribute.Mandatory`. Calling a function with a missing mandatory parameter prompts on the console; under `Invoke-Pester` that would hang the suite rather than fail it. The plan's own gloss for this bullet was "parameter is mandatory", which is what is now asserted.
- **`New-HDTPesterConfiguration` carries a targeted analyzer suppression** for `PSUseShouldProcessForStateChangingFunctions`, justified inline: it builds an in-memory object and changes no state. `Clear-HDTBuildOutput` does the opposite — it genuinely deletes `out/`, so it declares `SupportsShouldProcess` and guards the removal with `ShouldProcess`, per the project's destructive-operation rule.
- **`Write-Information` with `$InformationPreference = 'Continue'`** rather than `Write-Host`, so `build.ps1` stays clean under `PSAvoidUsingWriteHost`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] A manifest test passed before the implementation existed**

- **Found during:** Task 1 (RED run)
- **Issue:** `It 'lists exactly one exported function per file in Public'` compared two empty lists and passed with no module on disk — a test that is green before its implementation is a broken test.
- **Fix:** Added `@($onDisk).Count | Should -BeGreaterThan 0` before the comparison. Re-ran: 29 tests, 0 passed, 29 failed.
- **Files modified:** `tests/unit/Module.Manifest.Tests.ps1`
- **Committed in:** `e3cbc35` (RED commit)

**2. [Rule 2 - Missing Critical] `Invoke-HDTLint` crashed instead of advising under 5.1**

- **Found during:** Task 3 verification
- **Issue:** The plan's guard was `Get-Module -ListAvailable PSScriptAnalyzer`. On this machine 5.1 *does* list the analyzer (it sits inside another module's `RequiredModules` tree) but cannot import it, so `lint` died with a raw `Import-Module` failure. The plan requires an actionable message, not a crash.
- **Fix:** The import is attempted inside a `try`/`catch`; a failed import is treated identically to a missing module and produces the install message, naming the running version and edition.
- **Files modified:** `build.ps1`
- **Verification:** `powershell.exe -NoProfile -File ./build.ps1 -Task lint` exits 1 with the actionable message; `pwsh` still exits 0 with 0 diagnostics.
- **Committed in:** `9634cf5`

**3. [Rule 3 - Blocking] PSScriptAnalyzer suppression used a non-existent rule name**

- **Found during:** Task 3 (first `lint` run)
- **Issue:** The suppression was written for `PSUseShouldProcessForStateChangingVerbs`; the real rule is `PSUseShouldProcessForStateChangingFunctions`, so the diagnostic still fired and `lint` could never be clean.
- **Fix:** Corrected the rule name.
- **Files modified:** `tests/helpers/HDTTestTools/tools/New-HDTPesterConfiguration.ps1`
- **Committed in:** `5aafcd0`

### Documentation deviations

- **`.gitignore` was not modified.** The plan asked to verify that `out/testResults/*.xml` is ignored and to add it if not. `git check-ignore -v` shows it is already covered by the existing `/out/` entry, so no change was made.
- **`build.ps1` itself has no unit tests.** Task 3 in the plan lists no test files, and the harness is verified behaviourally by its exit codes — including a deliberately failing `It` proving exit 1 under both engines, then reverted. This is the one piece of code in the plan not covered by a preceding failing test; it is the test runner itself.

---

**Total deviations:** 3 auto-fixed (1 bug, 1 missing critical, 1 blocking) plus 2 documentation notes.
**Impact on plan:** No scope change. Two of the three fixes were required for the plan's own stated success criteria (a real RED, an actionable lint failure under 5.1).

## Issues Encountered

- **Pester 6.0.0 shadowing (S5) confirmed live.** Under `powershell.exe`, `Get-Module -ListAvailable Pester` returns `6.0.0, 5.7.1, 5.7.1, 3.4.0`. Every import in `build.ps1` and in the test files is pinned. Resolved.
- **`PSUseDeclaredVarsMoreThanAssignments` vs. Pester `BeforeAll`.** Resolved with `$script:` scoping (see Decisions).

## Verification Results

All six checks in the plan's `<verification>` block, executed:

| # | Check | Result |
|---|---|---|
| 1 | `pwsh -NoProfile -File ./build.ps1 -Task ci` | **exit 0** — clean, build, lint (0 diagnostics/14 files), test (54 passed, 0 failed) |
| 2 | `powershell.exe -NoProfile -File ./build.ps1 -Task test` | **exit 0** — 54 passed, 0 failed |
| 3 | `Get-Command -Module Hephaestus` after import | `Get-HDTModuleVersion` — exactly one command |
| 4 | `Get-Command Test-HDTSchemaVersion` | nothing returned; the private function does not leak |
| 5 | `git log --oneline` | `e3cbc35 test` → `e6e8802 feat`; `1d070a5 test` → `7674a27 feat` |
| 6 | Scan for `??`, `?.`, `ForEach-Object -Parallel`, `$PSStyle` | none across 13 source files |

Plus the failure path: a temporary `It 'fails on purpose' { $true | Should -BeFalse }` produced `BUILD FAILED: 1 test(s) failed.` and **exit 1** under both engines. Reverted; working tree clean.

## User Setup Required

None.

## Next Phase Readiness

Ready for **01-02** (the three enforcement contract tests). It has what it needs:

- `Get-HDTSourceFile` already defines the file set the AST scanners must walk, and already excludes `tests/fixtures/**` — which is where 01-02's deliberately-bad fixtures belong.
- `Invoke-HDTTest` already tolerates a missing `tests/contract` directory and will pick it up the moment it exists; no `build.ps1` change is needed to start adding contract tests.
- Nine functions exist for the naming contract test to enumerate — `Get-HDTModuleVersion`, `Test-HDTSchemaVersion`, `Get-HDTSourceFile`, `New-HDTPesterConfiguration`, `Initialize-HDTBuildEnvironment`, `Clear-HDTBuildOutput`, `Invoke-HDTBuild`, `Invoke-HDTLint`, `Invoke-HDTTest` — all already `Verb-HDTNoun` with approved verbs.

One concern to carry forward: `PSUseCompatibleSyntax` is configured and the suite is clean, but nothing in this plan proves it actually *rejects* PS7-only syntax on this machine. Plan 01-02's syntax contract test should assert that positively against a fixture, not merely observe zero diagnostics.

## Self-Check: PASSED

All 17 created files verified present on disk, `Readme.txt` verified deleted, and
all six commit hashes (`e3cbc35`, `e6e8802`, `1d070a5`, `7674a27`, `5aafcd0`,
`9634cf5`) verified present in `git log`.

---
*Phase: 01-harness*
*Completed: 2026-08-13*
