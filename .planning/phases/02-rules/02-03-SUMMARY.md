---
phase: 02-rules
plan: 03
subsystem: rules
tags: [resolution-engine, precedence, provenance, var-expansion, setfrom, sample-workspace, m1-exit]

# Dependency graph
requires:
  - phase: 01-harness plan 03
    provides: New-HDTFakeFileSystem, and the fake-not-mock convention every test here follows
  - phase: 02-rules plan 01
    provides: Get-HDTMachineFact, the CIM/registry/environment fakes and the script-invoker fake
  - phase: 02-rules plan 02
    provides: Import-HDTRuleDocument, ConvertFrom-HDTYaml, New-HDTErrorRecord, Test-HDTSchemaVersion, the two schemas
provides:
  - "Resolve-HDTVariable - the five-source resolution engine with provenance (ROADMAP M1 exit criterion)"
  - "Get-HDTMachineOverride - DESIGN 3.1 source 2, Control\\machines\\<UUID>.yaml through IFileSystem"
  - "Get-HDTVariableProvenance - provenance queryable by name and wildcard after the call"
  - "Export-HDTVariableProvenance - DESIGN 4.4's Gather\\provenance.json"
  - "Expand-HDTVariableToken - recursive %Var% expansion with chain-based cycle detection"
  - "Test-HDTRuleMatch - wildcard, multi-key, list-aware, boolean-aware when matching"
  - "ConvertTo-HDTComparableString - one invariant-culture rendering for comparison and substitution"
  - "Add-HDTResolvedVariable - the single writer that enforces first-wins and records provenance"
  - "samples/workspace/ - rules.yaml, a machine override and a setFrom script, schema-validated"
  - "tests/unit/GatherAndResolve.EndToEnd.Tests.ps1 - the M1 exit criterion asserted end to end"
affects: [03-sequence-engine, 04-imaging, 06-drivers, 07-apps, 09-console]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Precedence is WRITE ORDER, not comparison: sources are applied in DESIGN 3.1 order and Add-HDTResolvedVariable refuses to overwrite"
    - "The scope holds RAW values; the result holds EXPANDED values - that asymmetry is what makes cycles detectable"
    - "A DateTime is formatted to a string with 'o' + InvariantCulture BEFORE ConvertTo-Json, always: 5.1 writes \\/Date(...)\\/ otherwise"
    - "A test double built as [pscustomobject] + Add-Member ScriptMethod must USE its parameters or PSReviewUnusedParameter fails the lint task"
    - "A Start-Job scriptblock takes $using:, not param/-ArgumentList: PSUseUsingScopeModifierInNewRunspaces does not recognise the latter"
    - "A private function defined inside one InModuleScope block is NOT visible in the next one; share state through $script: instead"

key-files:
  created:
    - src/Hephaestus/Private/ConvertTo-HDTComparableString.ps1
    - src/Hephaestus/Private/Expand-HDTVariableToken.ps1
    - src/Hephaestus/Private/Test-HDTRuleMatch.ps1
    - src/Hephaestus/Private/Add-HDTResolvedVariable.ps1
    - src/Hephaestus/Public/Get-HDTMachineOverride.ps1
    - src/Hephaestus/Public/Resolve-HDTVariable.ps1
    - src/Hephaestus/Public/Get-HDTVariableProvenance.ps1
    - src/Hephaestus/Public/Export-HDTVariableProvenance.ps1
    - tests/unit/ConvertTo-HDTComparableString.Tests.ps1
    - tests/unit/Expand-HDTVariableToken.Tests.ps1
    - tests/unit/Test-HDTRuleMatch.Tests.ps1
    - tests/unit/Add-HDTResolvedVariable.Tests.ps1
    - tests/unit/Get-HDTMachineOverride.Tests.ps1
    - tests/unit/Resolve-HDTVariable.Tests.ps1
    - tests/unit/Get-HDTVariableProvenance.Tests.ps1
    - tests/unit/Export-HDTVariableProvenance.Tests.ps1
    - tests/unit/GatherAndResolve.EndToEnd.Tests.ps1
    - samples/workspace/rules.yaml
    - samples/workspace/Control/machines/4C4C4544-0031-3610-8052-B7C04F515A31.yaml
    - samples/workspace/Scripts/Get-ComputerName.ps1
    - samples/README.md
  modified:
    - src/Hephaestus/Hephaestus.psd1
    - tests/contract/RulesSchema.Contract.Tests.ps1
    - README.md

key-decisions:
  - "Resolve-HDTVariable gained an optional -MachineOverridePath: the plan's signature carried the override VARIABLES but no way to name the FILE, and the provenance record requires it"
  - "The cycle check is the chain of names being expanded, not a depth counter: a counter cannot tell a cycle from a long chain and can name neither"
  - "An unresolved %Var% is left LITERALLY in the value and reported in Unresolved, never emptied - MDT leaves it alone and an empty machine name hides the mistake"
  - "The operator is chosen per pattern - -like when it holds * or ?, -eq otherwise - so a '[' in a model name is a literal rather than a character class"
  - "Add-HDTResolvedVariable checks 'already resolved' BEFORE expanding, so a value that was never going to be used cannot report an unresolved token"
  - "The setFrom invoker receives a COPY of the scope, so a user script cannot mutate engine state; proven by a double that tries"
  - "The provenance timestamp is serialised as a formatted [string]: ConvertTo-Json renders a raw [datetime] as \\/Date(...)\\/ under 5.1, which is the engine in WinPE"
  - "The two timestamp assertions were moved onto the file TEXT after the first green run - ConvertFrom-Json turns an ISO 8601 string back into a [datetime] and would have hidden the difference"
  - "The cycle 'does not hang' test runs in a CHILD PROCESS: unbounded recursion overflows the stack, and a StackOverflowException cannot be caught"

# Metrics
duration: 165min
completed: 2026-08-13
---

# Phase 02 Plan 03: The Resolution Engine Summary

**Given a machine's facts and a `rules.yaml`, HDT now produces the expected
variable set *and* explains where every single value came from — five-source
precedence, first-match-wins per variable, wildcard and list-aware `when`
matching, recursive `%Var%` expansion that reports a cycle instead of hanging,
and `setFrom:` script rules through an injected invoker. That is ROADMAP M1's
exit criterion, demonstrated twice: as an automated test over fixtures and fakes,
and as a live command against this machine.**

## Test evidence — every count from a real run

| Step | pwsh 7.5.8 | Windows PowerShell 5.1.26100.8655 |
|---|---|---|
| Baseline, before this plan | 653 passed / 0 failed / 11 skipped | — |
| Task 1 RED — three private functions absent | **52 failed** / 0 passed | — |
| Task 1 GREEN (`-Task ci`) | 717 passed / 0 failed / 11 skipped, lint 0 across 68 files | 687 passed / 0 failed / 41 skipped |
| Task 2 RED — the engine absent | **80 failed** / 0 passed | — |
| Task 2 GREEN (`-Task ci`) | 809 passed / 0 failed / 11 skipped, lint 0 across 74 files | 779 passed / 0 failed / 41 skipped |
| Task 3a RED — the two `-Skip`s removed, samples absent | **2 failed** / 0 passed | — |
| Task 3a GREEN — sample workspace added | 27 passed / 0 failed (schema contract) | skipped, no `Test-Json` |
| Task 3b/c RED — the two provenance functions absent | **20 failed** / 22 passed | — |
| **Final, `-Task ci`** | **863 passed / 0 failed / 9 skipped**, lint **0 diagnostics across 79 files**, selfcheck 4/4 | **831 passed / 0 failed / 41 skipped** |

Every RED count was observed, and its failure reason read, before the code that
turns it green. `git log --oneline` shows `test(02-03)` before every
`feat(02-03)`.

**Two honest caveats about the RED runs.**

1. **Task 3's RED was partial: 20 failed, 22 passed.** The 20 are
   `CommandNotFoundException` for `Get-HDTVariableProvenance` and
   `Export-HDTVariableProvenance`. The 22 that passed are the end-to-end
   assertions over the engine that tasks 1 and 2 had already built test-first.
   `GatherAndResolve.EndToEnd.Tests.ps1` is an *integration* assertion over units
   that already exist; claiming it started fully red would be false.

2. **Two assertions were caught passing before their implementation existed** and
   were hardened on the spot, which is exactly what the method is for:
   - `Should -Throw` with no expected message passed against
     `CommandNotFoundException`. It now asserts the message names the offending
     source.
   - `Get-Help -Name <missing command>` returns a stub whose `Synopsis` is
     non-empty. The help tests now call `Get-Command -Module Hephaestus` first.

The 5.1 skip count is 41 for the reason plan 02-02 recorded: `Test-Json` does not
exist there, so the whole `RulesSchema` contract skips with a printed warning. The
pwsh skip count fell from 11 to 9 because this plan un-skipped the two
sample-workspace tests.

The five new test files were also run on their own under 5.1: **111 passed, 0
failed, 0 skipped** — including the end-to-end test and the child-process cycle
test.

## The M1 exit criterion, demonstrated live

Against this machine's real facts, through the real CIM/registry/environment
adapters, with the sample `rules.yaml`:

```
Order Name                 Value                                Source       Rule
----- ----                 -----                                ------       ----
    1 HDTComputerName      PC-1ABC234                          Rule         Fallback
    2 HDTJoinWorkgroup     WORKGROUP                            Rule         Fallback
    3 HDTMake              LENOVO                               GatheredFact
    4 HDTModel             82RF                                 GatheredFact
    6 HDTSerialNumber      1ABC234                             GatheredFact
   15 HDTIsLaptop          True                                 GatheredFact
   ...
```

`HDTComputerName` is `PC-<this machine's serial>` **because** the `Fallback` rule
set it — the value *and* the reason. Every one of the 20 rows carries a `Source`
from the closed set (`rows with a source outside the closed set = 0`), and
`Unresolved` is empty. `Lab subnet` and `Latitude naming` are absent from the
table because neither matched this machine, which is the correct answer rather
than a gap.

The automated half is `tests/unit/GatherAndResolve.EndToEnd.Tests.ps1`: the same
pipeline over the captured CIM fixtures and the sample workspace, with a third
`Context` that proves the run touched nothing real — CIM only through the fake,
the workspace only through the fake filesystem, exactly one invoker call and no
PowerShell process, and `provenance.json` written to the fake while `Test-Path`
on the real disk stays false.

---

# What phase 03 needs to know

## `Resolve-HDTVariable` — the final signature

```
Resolve-HDTVariable [-CommandLine <IDictionary>]
                    [-MachineOverride <IDictionary>] [-MachineOverridePath <string>]
                    [-RuleDocument <object>] [-Fact <IDictionary>]
                    [-SequenceDefault <IDictionary>] [-ScriptInvoker <object>]
```

**Every parameter is optional.** Resolving nothing is a valid, empty answer, not
an error — the engine calls this before it necessarily knows which sources exist.

`-MachineOverridePath` is a **deviation from the plan**, and the reason is
recorded here rather than buried: the plan's signature passed the override
*variables* (`$override.Variable`) but nothing carried the *file*, while the
provenance record and the plan's own end-to-end assertion both require the
override file to be named. `Get-HDTMachineOverride` returns `Path` alongside
`Variable` for exactly this.

### The result shape

```
[pscustomobject] @{
    Variable   = <OrderedDictionary, OrdinalIgnoreCase>   name -> EXPANDED value
    Provenance = <OrderedDictionary, OrdinalIgnoreCase>   name -> provenance record
    Unresolved = [string[]]                               distinct token names, sorted ordinally
}
```

A provenance record is a `[pscustomobject]` with `Name`, `Value`, `Source`,
`Rule`, `RuleIndex`, `File`, `RawValue`, `Expanded`, `Order`.

### The closed set of `Source` values

`CommandLine`, `MachineOverride`, `Rule`, `RuleScript`, `GatheredFact`,
`SequenceDefault`.

Closed because provenance is machine-readable: the console and
`ConvertTo-HDTReport` switch on it. It is enforced by a `ValidateSet` on
`Add-HDTResolvedVariable -Source`, and asserted by tests in three files. **Adding
a sixth source means changing that set deliberately, not by accident.**

## The scope, and why cycles are detectable

There is one dictionary, `$scope`, holding **raw, unexpanded** values. It is
seeded with the sequence defaults, then the facts, then updated by every
assignment. Lookup precedence falls out of write order.

Every assignment writes the **raw** value into `$scope` and the **expanded** value
into `Variable`. That asymmetry is the whole trick: two variables that reference
each other only look cyclic *before* expansion, so eager expansion would hide the
cycle rather than report it. Cycle detection is the chain of names currently being
expanded — never a depth counter, which could not tell a cycle from a long chain
and could name neither.

A cycle raises `HDTConfigurationError` naming the whole cycle:

```
the value of HDTA cannot be expanded: %HDTA% -> %HDTB% -> %HDTA% is cyclic.
```

## An unresolved `%Var%` is left literal and reported

A token naming nothing in scope, or naming a `$null`, stays **literally** in the
value and its name goes into `Unresolved`. It is not an error. MDT leaves such a
token alone, and silently emptying it turns an authoring mistake into a machine
called `PC-`. Phase 03 should surface `Unresolved` in the log rather than treat it
as fatal.

One consequence worth knowing: a `when:` pattern whose token is unresolved does
**not** match, and the token is reported.

## The `setFrom` script contract

A user script named by `setFrom:` must:

- take **one parameter**, the current variable scope, as an `IDictionary`;
- emit **exactly one object**; every property of it becomes a variable
  (`[pscustomobject]` by `PSObject.Properties`, `IDictionary` by its keys);
- never emit a `_HDT*` property — that is a configuration error naming the rule
  and the script;
- emitting nothing (`$null`) is allowed and sets nothing.

`samples/workspace/Scripts/Get-ComputerName.ps1` is the canonical example. The
script receives a **copy** of the scope, so it cannot mutate engine state, and it
is reached only through `-ScriptInvoker`. **Phase 03 swaps `New-HDTScriptInvoker`
in for the fake with no change to the engine.**

A matching `setFrom` rule with no invoker supplied is a configuration error naming
the rule — not a silent skip.

## What phase 03 still owes DESIGN 4.4's `Gather\`

| File | Status |
|---|---|
| `provenance.json` | **Done.** `Export-HDTVariableProvenance`, schemaVersion 1, entries in resolution order |
| `facts.json` | **Phase 03.** `Get-HDTMachineFact` produces the dictionary; nothing writes it yet |
| `var.resolve` JSONL events | **Phase 03.** DESIGN 4.4.2 requires variable-provenance events on the JSONL stream; the records exist and are queryable, but no `Write-HDTLog` exists yet to emit them |

**When phase 03 writes the JSONL `ts` field, format the `[datetime]` to a string
first** — `.ToUniversalTime().ToString('o', InvariantCulture)`. `ConvertTo-Json`
renders a raw `[datetime]` as `\/Date(1786579862481)\/` under Windows PowerShell
5.1, which is the engine that runs in WinPE. This is a general rule for every
DateTime HDT ever writes to JSON, and it has a test in
`Export-HDTVariableProvenance.Tests.ps1` that fails on either engine if it is
broken.

## Deviations from the plan

1. **`-MachineOverridePath` added to `Resolve-HDTVariable`** (see above). Without
   it the plan's own assertion — "explains HDTComputerName as MachineOverride,
   naming the override file" — could not be satisfied.
2. **`Export-HDTVariableProvenance` declares `SupportsShouldProcess`.** The plan
   did not ask for it; it writes a file, and PROJECT constraint 5 asks for it on
   anything that changes state.
3. **`Get-HDTMachineOverride` also rejects an unknown top-level key.** Not in the
   plan's test list, but `machine.schema.json` declares
   `additionalProperties: false`, and the two validators must agree.
4. **The two `Export-HDTVariableProvenance` timestamp assertions were changed
   after their first run** — from `(ConvertFrom-Json).generated` to a regex over
   the file text — because `ConvertFrom-Json` converts an ISO 8601 string back
   into a `[datetime]` and would have hidden the exact difference the test exists
   to catch. The intent is unchanged and now more strictly enforced.
5. **`Get-HDTMachineOverride.Tests.ps1` has a comment-based-help test** the plan
   did not list, for consistency with every other public cmdlet.

## Verification against the plan's checklist

| Check | Result |
|---|---|
| `pwsh -File ./build.ps1 -Task ci` | exit 0 — 863 passed, lint 0 across 79 files, selfcheck 4/4 |
| `powershell -File ./build.ps1 -Task test` | exit 0 — 831 passed, 0 failed |
| End-to-end test passes under both engines, asserting both halves | yes — 22 assertions across three Contexts |
| Every ROADMAP M1 "Tests first" bullet has named tests | yes (below) |
| `git log` shows `test(02-03)` before every `feat(02-03)` | yes |
| `samples/workspace/rules.yaml` validates, no `-Skip` left | yes — 27 passed in the schema contract |
| No engine file added here calls `Get-Content`, `Set-Content`, `Get-CimInstance`, `Test-Path`, or invokes a script path | yes — grepped; the only outward call is `$ScriptInvoker.Invoke(...)` |

ROADMAP M1 "Tests first", mapped:

| Bullet | Where |
|---|---|
| precedence across all five sources | `Resolve-HDTVariable.Tests.ps1`, Context 'precedence across all five sources' |
| wildcard and multi-key `when` matching | `Test-HDTRuleMatch.Tests.ps1`, Contexts 'wildcards' and 'multiple keys' |
| fallback rules only filling unset variables | `Resolve-HDTVariable.Tests.ps1`, Context 'first match wins per variable' |
| recursive and cyclic `%Var%` expansion | `Expand-HDTVariableToken.Tests.ps1`, Contexts 'recursion' and 'cycles' |
| provenance correctness | `Add-HDTResolvedVariable.Tests.ps1`, `Resolve-HDTVariable.Tests.ps1` Context 'provenance', `Get-HDTVariableProvenance.Tests.ps1` |
| malformed YAML producing a pointed configuration error | plan 02-02, `ConvertFrom-HDTYaml.Tests.ps1` |

## Self-Check: PASSED

All 21 files named in `key-files.created` exist on disk. All nine commits
(`a694fa2`, `6b948d3`, `91a0aca`, `0affc4e`, `a8e6fd0`, `f8c6573`, `756ebff`,
`9d62340`, `ef49127`) exist in `git log`. Both `min_lines` floors are met:
`Resolve-HDTVariable.ps1` is 290 lines (floor 180) and
`GatherAndResolve.EndToEnd.Tests.ps1` is 242 (floor 120). All three `key_links`
resolve: the end-to-end test seeds `samples/workspace` into the fake filesystem,
`Resolve-HDTVariable` writes only through `Add-HDTResolvedVariable`, and its only
outward call is `$ScriptInvoker.Invoke(...)`.
