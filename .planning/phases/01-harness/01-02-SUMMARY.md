---
phase: 01-harness
plan: 02
subsystem: testing
tags: [pester, ast, psscriptanalyzer, contract-tests, powershell-5.1, naming, mdt]

# Dependency graph
requires:
  - phase: 01-harness plan 01
    provides: HDTTestTools helper module, Get-HDTSourceFile, build.ps1 task runner, Pester 5 harness
provides:
  - "Get-HDTSourceFunction - AST function discovery that throws rather than returning empty on a parse error"
  - "Test-HDTFunctionName / Get-HDTFunctionNameViolation - DESIGN 15.1 name rule, with reasons"
  - "Get-HDTScriptCompatibilityViolation / Test-HDTScriptCompatibility - PS 5.1 syntax scanner, identical verdict on both engines"
  - "Get-HDTMdtDependency - non-comment token scan for MDT components"
  - "tests/contract/Naming.Contract.Tests.ps1 - naming enforced over the real repository"
  - "tests/contract/PowerShell51Compatibility.Contract.Tests.ps1 - one It per source file"
  - "tests/contract/NoMdtDependency.Contract.Tests.ps1 - CLAUDE.md rule 4 enforced, plus a NOTICE.md attribution guard"
  - "Deliberately non-conforming fixtures under tests/fixtures/{naming,compat,mdt}"
affects: [02-rules, 03-engine, 04-imaging, 05-boot-image, 06-drivers, 07-apps, 08-console]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Contract tests resolve their file list at discovery time and repeat the setup in BeforeAll (Pester 5 drops discovery-phase variables)"
    - "AST/token identity compared as strings (GetType().Name, Kind.ToString()) so the scanners parse under 5.1 and 7 alike"
    - "Forbidden-term list lives in a .psd1 that Get-HDTSourceFile excludes, so the scanner is not flagged by its own patterns"
    - "Anti-vacuity guards: every contract asserts it found something before asserting it found nothing wrong"

key-files:
  created:
    - tests/helpers/HDTTestTools/tools/Get-HDTSourceFunction.ps1
    - tests/helpers/HDTTestTools/tools/Test-HDTFunctionName.ps1
    - tests/helpers/HDTTestTools/tools/Get-HDTFunctionNameViolation.ps1
    - tests/helpers/HDTTestTools/tools/Get-HDTScriptCompatibilityViolation.ps1
    - tests/helpers/HDTTestTools/tools/Test-HDTScriptCompatibility.ps1
    - tests/helpers/HDTTestTools/tools/Get-HDTMdtDependency.ps1
    - tests/helpers/HDTTestTools/data/HDTMdtTerm.psd1
    - tests/contract/Naming.Contract.Tests.ps1
    - tests/contract/PowerShell51Compatibility.Contract.Tests.ps1
    - tests/contract/NoMdtDependency.Contract.Tests.ps1
  modified:
    - tests/helpers/HDTTestTools/HDTTestTools.psd1
    - docs/DESIGN.md

key-decisions:
  - "Enforced name pattern widened to ^([A-Z][a-zA-Z]*)-HDT[A-Z][A-Za-z0-9]*$ matched with -cmatch; Get-Verb membership is the real verb constraint"
  - "MDT scanning ignores comment tokens, so prose about what HDT replaces stays legal while code does not"
  - "The MDT term list lives in a .psd1 data file, outside the scanned file set"
  - "The compat scanner stops at the first parse error per file rather than inventing findings from a broken AST"

# Metrics
duration: 95min
completed: 2026-08-13
---

# Phase 01 Plan 02: Self-enforcing contracts Summary

**Three contract suites now make the project's hardest constraints unbreakable: a function not named `Verb-HDTNoun`, a PowerShell 7-only operator, or any MDT component in code turns the suite red under both engines, naming file, line and offending token.**

## Performance

- **Duration:** ~95 min
- **Tasks:** 4 of 4
- **Files created:** 30 (10 tools/contracts, 17 fixtures, 1 data file, 2 unit suites beyond those counted)
- **Commits:** 6 task commits, RED before GREEN throughout

## Accomplishments

- Six new `HDTTestTools` functions, each with comment-based help and a unit suite written first.
- Three contract suites running over the **real repository** (26 files, 16 functions discovered), not fixtures.
- All three demonstrated to fail on a deliberate violation, under **both** pwsh 7.5.8 and Windows PowerShell 5.1.26100.8655, then reverted.
- `docs/DESIGN.md` §15.1 no longer contradicts itself.

## Verified test results (executed, not assumed)

| Run | Result |
|---|---|
| `pwsh -NoProfile -File ./build.ps1 -Task ci` | **exit 0** — clean, build, lint 0 diagnostics across 27 files, test **200 passed / 0 failed / 9 skipped** |
| `powershell.exe -NoProfile -File ./build.ps1 -Task test` | **exit 0** — **198 passed / 0 failed / 11 skipped** |

Skips are the engine-specific Contexts (5.1-only parse-error classification is skipped under 7, and the 7-only AST classification is skipped under 5.1). Every one of them runs on the other engine, which is why the pair of runs is the proof and either run alone is not.

## Task Commits

1. **Task 1: function discovery and name validation** — `603d6d9` (test, RED: 33 failed / 0 passed) then `72f623e` (feat, GREEN: 86 passed on both engines)
2. **Task 2: PowerShell 5.1 compatibility scanner** — `862c2a8` (test, RED: 30 new tests failing) then `13374c9` (feat, GREEN: pwsh 116 passed, 5.1 113 passed)
3. **Task 3: no-MDT scanner and contract** — `62a24df` (test, RED: 45 failed) then `fbdfe86` (feat, GREEN: pwsh 163, 5.1 161)
4. **Task 4: naming and compatibility contracts over the real repository** — `215af0b` (test + DESIGN correction)

Also `3c33e1d`-adjacent: the pre-existing uncommitted `docs/DESIGN.md` §5.1 change found in the working tree at start was committed by a concurrent process (`3b5c0a6`) while this plan was executing; see Issues.

## The three enforced rules, as implemented

### 1. Naming — final enforced pattern

```
^([A-Z][a-zA-Z]*)-HDT[A-Z][A-Za-z0-9]*$      matched with -cmatch (case-sensitive)
+ $Matches[1] must appear in Get-Verb with exact case (-ccontains)
```

DESIGN §15.1's stated `^[A-Z][a-z]+-HDT[A-Z]` could not match `ConvertTo-HDTReport`, which the same section lists as a valid name three lines above — `[a-z]+` rejects the interior capital of every two-word approved verb (`ConvertTo`, `ConvertFrom`, `WaitFor`). The character class was widened and the verb check made the real constraint. DESIGN §15.1 now states this and says why.

Violations carry a `Reason`: either `'<verb>' is not an approved verb (Get-Verb)` or `does not match ^Verb-HDTNoun (uppercase HDT required, approved verb, noun starting with a capital)`.

### 2. PowerShell 5.1 compatibility — full `Feature` enumeration

`ParseError`, `NullCoalescing`, `NullConditional`, `Ternary`, `ForEachParallel`, `CleanBlock`, `ForbiddenCommand`, `ForbiddenParameter`, `ForbiddenVariable`.

**Two-tier assertion strategy.** The two engines disagree about what is even parseable, so each forbidden construct is asserted twice:

| Construct | Under Windows PowerShell 5.1 | Under PowerShell 7 |
|---|---|---|
| `??`, `??=` | `ParseError` | token `QuestionQuestion` / `QuestionQuestionEquals` → `NullCoalescing` |
| `${a}?.M`, `${a}?[0]` | `ParseError` | token `QuestionDot` / `QuestionLBracket` → `NullConditional` |
| `a ? b : c` | `ParseError` | `TernaryExpressionAst` → `Ternary` |
| `ForEach-Object -Parallel` | parses; `CommandParameterAst -match '^par'` → `ForEachParallel` | same |
| `clean { }` | parses as a **command** named `clean` with a script-block argument → `CleanBlock` | `ScriptBlockAst.CleanBlock` → `CleanBlock` |
| `Get-Error` | `ForbiddenCommand` | same |
| `$PSStyle` | `ForbiddenVariable` | same |
| `ConvertFrom-Json -AsHashtable` | `ForbiddenParameter` | same |

Every unit test for these tiers ran on both engines; the tier that does not apply is `-Skip`ped, never silently passed. Parameter prefixes are matched (`-Par`, `-Para`, `-ash`) because PowerShell accepts them.

A file with parse errors reports one violation per error and then stops: a broken AST cannot support further findings without inventing them.

### 3. No MDT dependency — term list and the comment exemption

Seven terms, matched case-insensitively against **non-comment tokens only**:

| Term name | Pattern | Catches |
|---|---|---|
| `MdtModule` | `MicrosoftDeploymentToolkit` | the MDT PowerShell module |
| `MdtDrive` | `MDTProvider` | the MDT PSDrive provider |
| `BddAssembly` | `Microsoft\.BDD` | MDT assemblies and namespaces |
| `ZtiScript` | `\bZTI[A-Za-z0-9]*\b` | `ZTIGather`, `ZTIApplications`, … |
| `LtiScript` | `\bLTI[A-Za-z0-9]*\b` | LiteTouch scripts |
| `MdtCmdlet` | `-MDT[A-Za-z]` | any `*-MDT*` cmdlet |
| `TaskSequenceXml` | `\bts\.xml\b` | MDT's task sequence file format |

**Comment exemption:** the token stream is filtered to `Kind.ToString() -ne 'Comment'` before matching. DESIGN and code comments legitimately say "replaces `ZTIGather.wsf`"; prose is free, code is not. The bait fixture yields exactly 6 violations; the control fixture — the same words in comments, plus `Import-WdsBootImage` and `oscdimg` — yields 0. ADK and WDS are permitted and deliberately absent from the list.

**Where the list lives, and why:** `tests/helpers/HDTTestTools/data/HDTMdtTerm.psd1`. `Get-HDTSourceFile` excludes `.psd1`, so the patterns are outside the scanned set. Written inline in `Get-HDTMdtDependency.ps1`, every pattern would flag the file that defines it. For the same reason the unit tests assemble two term names from fragments, with a comment saying so.

**Unparseable files** fall back to a line-by-line text scan that skips lines starting with `#`, and the message says a text scan was used. Without it, an MDT dependency could hide behind a parse error.

## The three deliberate-violation demonstrations

All executed, both engines, all reverted; `git status` clean afterwards.

**1. Naming.** `function Get-BadName { }` appended to `src/Hephaestus/Private/Test-HDTSchemaVersion.ps1`:

- pwsh: **exit 1** — `Expected 0, because src/Hephaestus/Private/Test-HDTSchemaVersion.ps1:46 Get-BadName does not match ^Verb-HDTNoun …, but got 1` (199 passed, 1 failed)
- 5.1: **exit 1**, identical message (197 passed, 1 failed)

**2. PS7-only syntax.** `$script:HDTDeliberateViolation = $null ?? 1` appended to `tests/helpers/HDTTestTools/tools/Test-HDTFunctionName.ps1`:

- pwsh: **exit 1** — `tests/helpers/…/Test-HDTFunctionName.ps1:42:40 [NullCoalescing] PowerShell 7-only operator '??' is not permitted …`
- 5.1: **exit 1**, but caught *earlier than the contract*: the helper module cannot be dot-sourced at all, so `build.ps1` fails in `Initialize-HDTBuildEnvironment` with `Unexpected token '??' … at char 40`. Honest reading: under 5.1 a PS7 operator in a **loaded** file is stopped by the engine before the contract ever runs.
- To prove the contract's own `ParseError` path under 5.1, the same line was placed in `src/Hephaestus/DeliberateViolation.ps1` — scanned by `Get-HDTSourceFile`, dot-sourced by nothing. 5.1: **exit 1** — `src/Hephaestus/DeliberateViolation.ps1:2:40 [ParseError] This file does not parse on the current engine (5.1.26100.8655): Unexpected token '??' …`. pwsh on the same file: **exit 1** — `[NullCoalescing]`. Both reverted.

**3. MDT dependency.** `Import-Module MicrosoftDeploymentToolkit` added to `src/Hephaestus/Public/Get-HDTModuleVersion.ps1`:

- pwsh: **exit 1** — `src/Hephaestus/Public/Get-HDTModuleVersion.ps1:39:19 MDT dependency 'MdtModule' (the MDT PowerShell module) is forbidden (CLAUDE.md rule 4: zero MDT components; ADK and WDS are permitted)`
- 5.1: **exit 1**, identical message

## Files Created/Modified

- `tests/helpers/HDTTestTools/tools/Get-HDTSourceFunction.ps1` — AST function discovery; throws on parse error
- `tests/helpers/HDTTestTools/tools/Get-HDTFunctionNameViolation.ps1` — the DESIGN 15.1 rule, with reasons
- `tests/helpers/HDTTestTools/tools/Test-HDTFunctionName.ps1` — boolean face of the same rule
- `tests/helpers/HDTTestTools/tools/Get-HDTScriptCompatibilityViolation.ps1` — 5.1 syntax scanner
- `tests/helpers/HDTTestTools/tools/Test-HDTScriptCompatibility.ps1` — boolean wrapper
- `tests/helpers/HDTTestTools/tools/Get-HDTMdtDependency.ps1` — MDT term scanner with text-scan fallback
- `tests/helpers/HDTTestTools/data/HDTMdtTerm.psd1` — the term list, outside the scanned set
- `tests/contract/Naming.Contract.Tests.ps1`, `PowerShell51Compatibility.Contract.Tests.ps1`, `NoMdtDependency.Contract.Tests.ps1`
- `tests/unit/Get-HDTSourceFunction.Tests.ps1`, `Test-HDTFunctionName.Tests.ps1`, `Get-HDTScriptCompatibilityViolation.Tests.ps1`, `Get-HDTMdtDependency.Tests.ps1`
- `tests/fixtures/naming/` (4 files), `tests/fixtures/compat/` (11), `tests/fixtures/mdt/` (2)
- `tests/helpers/HDTTestTools/HDTTestTools.psd1` — `FunctionsToExport` now lists 9 functions
- `docs/DESIGN.md` — §15.1 pattern correction

## Deviations from Plan

### 1. [Rule 1 - Bug] `Ps7-CleanBlock.ps1` fixture body changed

- **Found during:** Task 2, while probing the AST facts before writing the fixtures.
- **Issue:** The plan specified `function Get-HDTCleanBlockSample { begin { } process { } clean { … } }`. Probed under 5.1, that text produces **2 parse errors** (`Missing closing '}'`), because a statement after named blocks is illegal. The fixture would then classify as `ParseError` under 5.1, and the plan's own It — *"still classifies clean as CleanBlock or ForbiddenCommand"* — could never pass.
- **Fix:** Fixture body is `function Get-HDTCleanBlockSample { clean { Write-Output 'x' } }`, which the plan's `<verified_ast_facts>` already confirms parses on both engines: 5.1 sees a command named `clean`, 7 produces `ScriptBlockAst.CleanBlock`. Both routes are asserted.
- **Verification:** Probed on both engines before writing the test; both engine-specific Contexts pass.
- **Committed in:** `862c2a8` / `13374c9`

### 2. [Rule 2 - Missing critical functionality] Two `throws when a path does not exist` tests passed while RED

- **Found during:** Task 2, on running the RED suite — 1 test passed before any implementation existed.
- **Issue:** A bare `Should -Throw` is satisfied by the `CommandNotFoundException` raised by the function *not existing*. Such a test can never fail for the right reason.
- **Fix:** Both tightened to `Should -Throw -ExpectedMessage '*no-such-file.ps1*'`, so only a message naming the missing file passes. The same form was used for `Get-HDTMdtDependency`.
- **Verification:** Re-ran RED — the previously passing test now failed; after GREEN it passes.
- **Committed in:** `862c2a8`

### 3. [Rule 3 - Blocking] Contract setup duplicated into `BeforeAll`

- **Found during:** Task 3, on the first run of `NoMdtDependency.Contract.Tests.ps1`.
- **Issue:** The plan says to resolve the file list at discovery time (correct — Pester 5 expands `-ForEach` during discovery). But discovery-phase `$script:` variables do **not** survive into the run phase, so the anti-vacuity guard read `$script:HDTSourceFile.Count` as 0 and failed.
- **Fix:** Discovery-time resolution kept for `-ForEach`; the same four lines repeated in `BeforeAll` for run-phase use, with a comment explaining the phase separation. Applied to all three contracts.
- **Committed in:** `62a24df`, `215af0b`

### 4. [Rule 1 - Bug] Three `It` titles in the no-MDT unit suite were themselves MDT hits

- **Found during:** Task 3 GREEN — the new contract failed on `tests/unit/Get-HDTMdtDependency.Tests.ps1` with 4 violations.
- **Issue:** An `It` title is a string token, and the contract scans non-comment tokens of every source file. `It 'flags a Microsoft.BDD type reference'`, `'flags a ZTI script invocation'` and `'knows about the LTI script family'` (plus a `LtiBait.ps1` temp filename) matched the very patterns they described.
- **Fix:** Retitled to `'flags an MDT assembly type reference'`, `'flags a zero-touch script invocation'`, `'knows about the LiteTouch script family as well'`; temp file renamed `LegacyScriptBait.ps1`. Terms that must appear literally are assembled from fragments with an explanatory comment.
- **Verification:** Suite green on both engines; the contract still catches the bait fixture's 6 violations.
- **Committed in:** `fbdfe86`

### 5. [Planned-scope addition] Two extra naming fixtures

`tests/fixtures/naming/SampleModule.psm1` and `NoFunction.ps1` were added so the `.psm1` and the no-functions cases assert against real files like the rest. Task 1's parse-error test writes its sample into `TestDrive` instead of depending on `tests/fixtures/compat/Ps7-Ternary.ps1`, which Task 2 had not created yet — each task's suite is green at its own commit.

---

**Total deviations:** 5 (2 bugs, 1 missing test rigour, 1 blocking, 1 minor scope addition). All necessary for correctness. No scope creep.

## Issues Encountered

- **A concurrent process is committing to this repo.** Mid-execution, commits `3b5c0a6` (DESIGN.md, 300 insertions) and `33bc908` (SPIKES.md) appeared from outside this session, and `docs/DESIGN.md` changed under me. The uncommitted §5.1 change present in the working tree at start was picked up by that process, not by me; my §15.1 edit applied cleanly on top and was committed alone in `215af0b`. Full CI was re-run after those commits landed: still green. Worth flagging because two agents writing the same file will eventually collide.
- **No blockers.**

## Next Phase Readiness

Ready for plan 01-03. From this commit forward a badly named function, a PS7-only operator, or an MDT reference in code cannot be committed without turning the suite red under both engines — which is exactly the condition ROADMAP M0 asks for before phase 02 starts mining PSD.

The `NOTICE.md` attribution guard is deliberately a no-op today (no derived code exists). It fires the moment a source file cites PSD attribution, so phase 02's first mined function cannot land unattributed.

---
*Phase: 01-harness, plan 02*
*Completed: 2026-08-13*

## Self-Check: PASSED

All 20 named files verified present on disk, `tests/fixtures/compat/` holds 11 fixtures,
all 7 commit hashes verified in `git log`, no leftover demonstration file in `src/`,
working tree clean apart from this summary.
