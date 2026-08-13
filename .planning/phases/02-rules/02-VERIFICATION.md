---
phase: 02-rules
verified: 2026-08-13T00:00:00Z
status: passed
score: 12/12 must-haves verified
re_verification: null
human_verification: []
observations:
  - "New-HDTFileSystem is named in the comment-based help of three public functions, in README.md and in samples/README.md, but the module does not export it. The FileSystemService contract defers the real adapter to phase 04. The README quick-start is therefore not runnable as written."
  - "The development machine's real serial (PF3EKMR0) survives in README.md:118 and samples/README.md:66,71, although commit e7ee6a8 removed it from comment-based help and every CIM fixture is sanitised."
  - "Under Windows PowerShell 5.1 the whole rules.yaml schema contract Describe skips (loudly, with a printed reason). Three of its assertions - that the two schema files exist and declare draft-07 - do not need Test-Json and could run on both legs."
  - "ConvertFrom-HDTYaml lazily imports powershell-yaml. That is not a hardware, filesystem or registry call, so PROJECT constraint 4 holds, but it is an un-injected external dependency the WinPE boot image will have to carry (an M4 concern, unasserted today)."
  - "DESIGN 4.4 Gather/facts.json is not produced by this phase; only provenance.json is. facts.json is not in the M1 bullet list, so this is a deferral rather than a miss."
  - "The variable-namespace contract transcribes DESIGN 3.2 MDT names into the test rather than parsing DESIGN.md, so drift in the design document itself would not be caught - only drift in Get-HDTVariableMap."
  - "ConvertTo-HDTComparableString (new engine code) does not declare Set-StrictMode or ErrorActionPreference in-file; Hephaestus.psm1 sets both at module scope so behaviour is correct, but the file departs from its siblings convention."
  - ".planning/REQUIREMENTS.md does not exist, so requirement-coverage mapping is not applicable to this phase."
---

# Phase 02: Rules — Verification Report

**Phase Goal:** Replace `CustomSettings.ini` + `ZTIGather`. Fact gathering behind
`ICimProvider`, rules.yaml parsing, five-source variable precedence, `%Var%`
expansion, `setFrom` script rules, and provenance for every resolved variable.

**Exit (docs/ROADMAP.md, M1):** given a fixture machine's facts and a `rules.yaml`,
the engine produces the expected variable set *and* explains every value.

**Verified:** 2026-08-13
**Status:** passed
**Re-verification:** No — initial verification

**Method:** goal-backward. Nothing in the three SUMMARY files was taken on trust.
Every claim below was re-derived by running both suites here, scanning the AST of
the engine sources, replaying git history into a detached tree, and driving the
engine by hand outside its own tests.

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|---|---|---|
| 1 | Facts are gathered behind ICimProvider, not by touching hardware | VERIFIED | AST CommandAst scan of every file in `src/Hephaestus/`: the only `Get-CimInstance` is `New-HDTCimProvider.ps1:68`; the only `Get-ItemProperty` / `Test-Path` are `New-HDTRegistryService.ps1:100/92` and `New-HDTScriptInvoker.ps1:100`. Zero drive-qualified variable references (`$env:`) anywhere in the module. `Get-HDTMachineFact` contains none of them. |
| 2 | Both a fake and a real implementation satisfy each service contract | VERIFIED | The CimProvider, RegistryService, EnvironmentProvider and ScriptInvoker contract files each carry two rows (fake + real adapter); both rows ran unskipped on this Windows host, on both engines. |
| 3 | rules.yaml is parsed and validated with pointed errors | VERIFIED | Driven by hand: an unparseable fixture throws `HDTConfigurationError,ConvertFrom-HDTYaml` with `C:\ws\rules.yaml(4): the YAML in this file could not be parsed...`; an authoring error throws `HDTConfigurationError,Assert-HDTRuleDocument` with `rule 1 ('Lab subnet'): 'priority' is not a key a rule may declare.` No MethodInvocationException, no YamlDotNet type escaping. |
| 4 | Five-source precedence, first-match-wins per variable | VERIFIED | `Resolve-HDTVariable.Tests.ps1`, Context "precedence across all five sources" (five head-to-head Its plus one asserting the winning source for each of the five). Reproduced independently: CommandLine beat MachineOverride beat Rule beat GatheredFact beat SequenceDefault in a single run. |
| 5 | Wildcard and multi-key `when` matching | VERIFIED | `Test-HDTRuleMatch.Tests.ps1`: Contexts "wildcards" (five Its, including a literal `[` in a pattern), "multiple keys" (three), "list values" (four, any-element matching), "tokens in the pattern" (two). Absent and null scope values are asserted never to match. |
| 6 | Later rules act as fallbacks only | VERIFIED | Context "first match wins per variable" (six Its). Confirmed in the live run: `HDTJoinWorkgroup` came from the Fallback rule while `HDTComputerName` stayed at the override's `FIN-0007`. |
| 7 | `%Var%` expands, recursively, with cycle detection | VERIFIED | `Expand-HDTVariableToken.Tests.ps1`: Contexts "recursion" (three levels deep), "cycles" (direct, indirect, names every variable in the cycle, correct error id, terminates in a child process), "escaping and types". By hand, a two-key cycle threw `HDTConfigurationError,Expand-HDTVariableToken` naming `%HDTBeta% -> %HDTAlpha% -> %HDTBeta%`. |
| 8 | An unresolved token is left literal and reported, not emptied | VERIFIED | By hand: `HDTComputerName = PC-%HDTNoSuchThing%` with `Unresolved = [HDTNoSuchThing]`. |
| 9 | `setFrom:` runs through an injected invoker, against a copy of the scope | VERIFIED | Context "setFrom" (twelve Its), including "passes a copy, so a script cannot mutate engine state", the missing-invoker error, the script-throws error with the inner exception preserved, and refusal of an `_HDT*` return. `Resolve-HDTVariable`'s only outward call is `$ScriptInvoker.Invoke(...)`. |
| 10 | Every resolved variable carries provenance from a closed set | VERIFIED | Hand run over the sample workspace: 25 variables, 25 provenance records, 0 unexplained, `Order` contiguous 1..25, every `Source` inside {CommandLine, MachineOverride, Rule, RuleScript, GatheredFact, SequenceDefault}, rule-sourced rows naming the rule, its index and the file. |
| 11 | M1 exit: fixture facts + rules.yaml produce the expected variables AND explain each | VERIFIED | Reproduced outside the test suite (table below). `tests/unit/GatherAndResolve.EndToEnd.Tests.ps1` asserts the same across three Contexts, the third of which proves the run touched no real disk, no real CIM, and ran no script. |
| 12 | Engine-owned `_HDT*` variables cannot be assigned from configuration | VERIFIED | By hand: `_HDTDeployRoot: X` in a rule is rejected by `Assert-HDTRuleDocument`, naming the file and the rule. |

**Score: 12/12 truths verified.**

### The M1 exit criterion, reproduced independently

Driven by a scratch script (not a Pester test) against `tests/fixtures/cim*` and
`samples/workspace/rules.yaml`, through the fakes only:

```
Order Name                 Value                Source           Rule
    1 HDTTaskSequenceID    CMD-CLIENT           CommandLine
    2 HDTComputerName      FIN-0007             MachineOverride
    3 HDTJoinDomain        lab.contoso.com      Rule             Lab subnet
    4 HDTSkipWizard        True                 Rule             Lab subnet
    5 HDTAssetTag          ASSET-X              RuleScript       Scripted name for laptops
    6 HDTJoinWorkgroup     WORKGROUP            Rule             Fallback
 7-24 (the 18 gathered facts)                   GatheredFact
   25 HDTDiskLayout        uefi-standard        SequenceDefault

UNRESOLVED: []     VARS=25   PROV=25   UNEXPLAINED: []
```

All five DESIGN 3.1 sources appear, each in its correct precedence position. The
list-valued `HDTDefaultGateway` fact matched a scalar `when`. The wildcard rule
`Latitude*` correctly did NOT fire on model `82RF`, leaving `HDTDriverGroup`
unset rather than empty. Every value is explained.

The real adapters were also exercised against this machine, outside the suite:
`HDTMake = LENOVO`, `HDTIsLaptop = True`, `HDTIsUEFI = True`,
`HDTSecureBootEnabled = True`, `HDTTPMVersion = 2.0`, `HDTIsVM = False`,
18 facts total.

### Required Artifacts

| Artifact | Expected | Status | Details |
|---|---|---|---|
| `src/Hephaestus/Public/Get-HDTMachineFact.ps1` | the ZTIGather replacement, injected services only | VERIFIED | 18 facts; no direct CIM, registry or environment call |
| `src/Hephaestus/Public/New-HDTCimProvider.ps1` | real ICimProvider | VERIFIED | branch-free adapter; contract row runs unskipped |
| `src/Hephaestus/Public/New-HDTRegistryService.ps1` | real IRegistryService | VERIFIED | contract row runs unskipped |
| `src/Hephaestus/Public/New-HDTEnvironmentProvider.ps1` | real environment provider | VERIFIED | contract row runs unskipped |
| `src/Hephaestus/Public/New-HDTScriptInvoker.ps1` | real IScriptInvoker | VERIFIED | contract row runs unskipped |
| `src/Hephaestus/Public/Import-HDTRuleDocument.ps1` | rules.yaml reader through IFileSystem | VERIFIED | no `Get-Content` in the file |
| `src/Hephaestus/Private/Assert-HDTRuleDocument.ps1` | WinPE-safe authoring validator | VERIFIED | ten unit Its including loops over every `invalid-*` fixture; runs on 5.1 |
| `src/Hephaestus/Private/ConvertFrom-HDTYaml.ps1` | pointed parse errors with file and line | VERIFIED | reproduced by hand |
| `src/Hephaestus/Private/Expand-HDTVariableToken.ps1` | recursion plus cycle detection | VERIFIED | reproduced by hand |
| `src/Hephaestus/Private/Test-HDTRuleMatch.ps1` | wildcard, multi-key and list matching | VERIFIED | 17 Its |
| `src/Hephaestus/Private/Add-HDTResolvedVariable.ps1` | the single writer, first-writer-wins | VERIFIED | 16 Its; precedence IS write order |
| `src/Hephaestus/Public/Resolve-HDTVariable.ps1` | the five-source engine | VERIFIED | 47 Its; only outward call is the injected invoker |
| `Get-HDTVariableProvenance.ps1` / `Export-HDTVariableProvenance.ps1` | queryable plus provenance.json | VERIFIED | SupportsShouldProcess present; writes through the injected IFileSystem; no `Date(...)` serialisation artefact |
| `src/Hephaestus/Public/Get-HDTVariableMap.ps1` | DESIGN 3.2 table as data | VERIFIED | 13 contract Its tie it to the documented list AND to every fact the gatherer emits |
| `schemas/rules.schema.json`, `schemas/machine.schema.json` | draft-07 | VERIFIED | validated on the pwsh 7 leg, including the sample workspace |
| `tests/fixtures/cim*` | sanitised captured CIM | VERIFIED | 6 + 1 + 2 files; Win32_NetworkAdapterConfiguration holds all 28 instances; no real serial, host name, user name or adapter GUID present |
| `samples/workspace/` | runnable example | VERIFIED | rules.yaml, machine override and script; both YAML files schema-validated by the contract |
| `NOTICE.md` | PSD MIT attribution | VERIFIED | present, enforced by the no-MDT contract |

## The six specific asks

### 1. Exit criteria demonstrably met — YES

See the reproduced table above. Both halves of the criterion — "produces the
expected variable set" and "explains every value" — were reproduced outside the
test suite, and `GatherAndResolve.EndToEnd.Tests.ps1` pins them in the suite.

### 2. TDD followed — YES, proven rather than assumed

Two independent checks:

**Tree state at each test commit.** For every phase-02 `test(...)` commit, the
implementation it covers was confirmed ABSENT from the tree at that commit:
`Get-HDTMachineFact` at `153c0e4`; `Get-HDTVariableMap` at `f33d717`;
`ConvertFrom-HDTYaml` at `c3415b1`; `Import-HDTRuleDocument` and both schemas at
`52e15d7`; `Test-HDTRuleMatch` and `Expand-HDTVariableToken` at `a694fa2`;
`Resolve-HDTVariable` at `91a0aca`; both provenance commands at `756ebff`; the
four adapters at `4f99075`; the enclosure fixture at `0c7db21`.

**RED replayed.** `git archive 91a0aca` was expanded into a scratch tree and
Pester was run against it: `Resolve-HDTVariable.Tests.ps1` gave **0 passed, 47
failed** (`The term 'Resolve-HDTVariable' is not recognized`), and
`Add-HDTResolvedVariable.Tests.ps1` gave **0 passed, 16 failed**. The RED the
SUMMARY claims is real and reproducible.

Commit order across all 25 phase-02 commits is `test(...)` before `feat(...)`
without exception. Four `feat` commits also touch test files; each of those diffs
was read, and every one HARDENS an assertion — moving a timestamp assertion onto
the file text so `ConvertFrom-Json` cannot launder it; making a fake's throw
message carry its arguments; removing an array cast that would have made
`Where-Object` member-enumerate and silently pass. None weakens a test to fit an
implementation.

### 3. Green under both engines — YES, run here

| Engine | Result | Exit code |
|---|---|---|
| pwsh 7.5.8 | 863 passed, **0 failed**, 9 skipped (43 files, 872 discovered) | 0 |
| Windows PowerShell 5.1.26100.8655 | 831 passed, **0 failed**, 41 skipped | 0 |

Every skip was enumerated from the NUnit XML and accounted for; all are
edition-gated by construction and none is a disguised failure. On pwsh 7 the nine
skips are the "how does 5.1 parse this" rows of the compatibility scanner. On 5.1
the 41 are the mirror-image PS7 parsing rows, the three PSScriptAnalyzer
self-proof rows (PSSA is not importable by this machine's Desktop edition), and
the 27-case rules.yaml schema contract, which prints a `Write-Warning` naming the
reason (`Test-Json` does not exist on 5.1) instead of skipping silently. The
engine's own validator, `Assert-HDTRuleDocument`, DOES run on 5.1 against every
`invalid-*` fixture, so the 5.1 leg is not blind to rule authoring errors.

### 4. Naming contract — EXISTS AND PASSES

`tests/contract/Naming.Contract.Tests.ps1` runs on both engines. It discovers 78
source files and 45 function definitions across `src/`, `tests/helpers/` and
`build.ps1`; carries an anti-vacuity guard (more than nine functions must be
found); checks approved verbs; asserts every exported function matches; forbids
`DefaultCommandPrefix`; and forbids aliases through the AST. Independently
re-enumerated here: all 45 discovered names, including all 20 defined in `src/`,
match `Verb-HDTNoun` with uppercase HDT.

### 5. PSScriptAnalyzer — CLEAN

`./build.ps1 -Task lint` under pwsh 7: **0 diagnostics across 79 files**, exit 0.
The settings are strict — default rules on, `Severity = Error, Warning`,
`ExcludeRules = @()`, and `PSUseCompatibleSyntax` targeting both 5.1 and 7.0.
`selfcheck` is 4 of 4, including "the analyzer really does report on a bait
fixture", so the clean result is not a silently disabled analyzer.

Under 5.1, `lint` fails with "PSScriptAnalyzer is not available to this
PowerShell edition". This is the environment exception documented at the end of
phase 01, not a phase-02 regression: the module is not installed for the Desktop
edition on this machine, `test` deliberately does not depend on `lint`, and CI
installs it for both editions.

### 6. No direct hardware, filesystem or registry access in engine code — CONFIRMED

An AST CommandAst scan of every `.ps1` and `.psm1` under `src/Hephaestus/` for 26
banned commands returned exactly seven hits, all legitimate:

```
New-HDTCimProvider.ps1:68       Get-CimInstance    <- the adapter
New-HDTRegistryService.ps1:92   Test-Path          <- the adapter
New-HDTRegistryService.ps1:100  Get-ItemProperty   <- the adapter
New-HDTScriptInvoker.ps1:100    Test-Path          <- the adapter
ConvertFrom-HDTYaml.ps1:76      Import-Module      <- lazy powershell-yaml load
Hephaestus.psm1:6,7             Get-ChildItem      <- the module's own loader
```

A separate scan for drive-qualified variable references (`$env:`, `$HKLM:`)
across the module returned nothing. The four adapters are branch-free in the
sense the constraint requires: their only conditionals dispatch on a namespace
string or re-throw with a better message, and none inspects returned data.

`Export-HDTVariableProvenance` is the only state-changing public command, and it
declares `SupportsShouldProcess` and gates its write on `ShouldProcess`.

## Anti-Patterns Found

| File | Pattern | Severity | Impact |
|---|---|---|---|
| `README.md:109`, `samples/README.md:101`, and the `.EXAMPLE` blocks of `Import-HDTRuleDocument`, `Get-HDTMachineOverride`, `Export-HDTVariableProvenance` | `New-HDTFileSystem` — a command that does not exist | Warning | The documented quick-start throws CommandNotFoundException. The real IFileSystem adapter is deliberately deferred (`FileSystemService.Contract.Tests.ps1` carries the row commented out, marked "Phase 04 appends"), but the shipped docs and help promise it today. |
| `README.md:118`, `samples/README.md:66,71` | the development machine's real serial `PF3EKMR0` | Warning | Inconsistent with commit `e7ee6a8`, which removed the same serial from comment-based help, and with the sanitisation applied to every CIM fixture. |
| `src/Hephaestus/Private/ConvertTo-HDTComparableString.ps1` | no in-file `Set-StrictMode` / `$ErrorActionPreference` | Info | Behaviour is correct because `Hephaestus.psm1` sets both at module scope, but the file departs from the convention its siblings follow. |

No `TODO`, `FIXME`, `XXX`, `HACK`, placeholder return, or console-log-only
implementation was found in any phase-02 source file. Every public command has a
synopsis, a description, documented parameters and at least one example (the only
undocumented parameters reported by `Get-Help` are the `WhatIf`/`Confirm` pair
that `SupportsShouldProcess` injects).

## Human Verification Required

None for the phase goal. Everything M1 claims is verifiable without hardware, and
the parts that touch real hardware — the four adapters — were additionally driven
against this machine here.

Carried forward from `PROJECT.md` as a standing gap that no phase has closed: the
`HDT Lab` switch is isolated, so neither this phase nor any later one proves
domain join against a live DC.

## Gaps Summary

**No gaps block the phase goal.** The M1 exit criterion is met and was reproduced
independently of the test suite. The suite is genuinely green on both engines with
every skip enumerated and accounted for. TDD is evidenced both by tree state at
each test commit and by a replayed RED run. The naming contract, the 5.1 syntax
contract and the no-MDT contract all pass over the real repository.
PSScriptAnalyzer is clean under the edition that can run it. No engine file
reaches hardware, the registry, the environment or the filesystem except through
an injected service.

Three items should be picked up early in phase 03 rather than left to rot:

1. Either ship `New-HDTFileSystem` or stop naming it in shipped help and READMEs.
   Phase 03 needs a real IFileSystem to read `sequence.yaml` anyway, so the
   natural fix is to add the adapter and uncomment the contract row.
2. Replace `PF3EKMR0` in `README.md` and `samples/README.md` with the fixture
   serial the rest of the repository uses.
3. Note for phases 04/05: `powershell-yaml` is a hard runtime dependency of the
   engine, and nothing yet asserts it will be present inside the WinPE boot image.

---

_Verified: 2026-08-13_
_Verifier: Claude (gsd-verifier)_
