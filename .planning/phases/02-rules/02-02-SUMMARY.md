---
phase: 02-rules
plan: 02
subsystem: rules
tags: [variable-map, json-schema, yaml, configuration-errors, validation, rules-yaml, fixtures]

# Dependency graph
requires:
  - phase: 01-harness plan 02
    provides: naming / PS5.1 / no-MDT contracts, which cover every new file automatically
  - phase: 01-harness plan 03
    provides: New-HDTFakeFileSystem, the $script:HDTImplementation discovery-time pattern
  - phase: 01-harness plan 04
    provides: Test-HDTSchemaVersion (DESIGN 12.3 refusal), build.ps1 ci/selfcheck
  - phase: 02-rules plan 01
    provides: Get-HDTMachineFact and its exact fact keys, which the variable map is tied to by contract
provides:
  - "Get-HDTVariableMap - the DESIGN 3.2 MDT translation table as data, 40 rows"
  - "Import-HDTRuleDocument - read, parse, validate and normalise rules.yaml through IFileSystem"
  - "Assert-HDTRuleDocument - the DESIGN 3.3 authoring rules, each with a pointed message"
  - "ConvertFrom-HDTYaml - the engine's only mention of ConvertFrom-Yaml"
  - "New-HDTErrorRecord - the one configuration-error shape (HDTConfigurationError)"
  - "schemas/rules.schema.json, schemas/machine.schema.json - draft-07"
  - "tests/fixtures/rules/*.yaml - thirteen documents: 3 valid, 8 invalid, 2 unparseable"
  - "tests/contract/VariableNamespace.Contract.Tests.ps1 - the map cannot drift from the gatherer"
  - "tests/contract/RulesSchema.Contract.Tests.ps1 - schema and engine must agree on every fixture"
affects: [02-rules plan 03, 03-sequence-engine, 05-bootimage, 09-console]

# Tech tracking
tech-stack:
  added:
    - "powershell-yaml 0.4.12 - imported LAZILY by ConvertFrom-HDTYaml, deliberately NOT in RequiredModules"
  patterns:
    - "Every configuration failure is $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord ...)), never throw 'string'"
    - "ConvertFrom-Yaml is called with -Ordered, always, and only from ConvertFrom-HDTYaml"
    - "A dictionary crossing a public boundary is [OrderedDictionary]::new([StringComparer]::OrdinalIgnoreCase)"
    - "A comment-based-help test asserts $help.Name before $help.Synopsis: Get-Help fuzzy-matches"
    - "A 'it threw' assertion also asserts FullyQualifiedErrorId, or it passes against CommandNotFoundException"
    - "A JSON Schema blind spot is listed in the contract test, not excluded from it"

key-files:
  created:
    - src/Hephaestus/Public/Get-HDTVariableMap.ps1
    - src/Hephaestus/Public/Import-HDTRuleDocument.ps1
    - src/Hephaestus/Private/New-HDTErrorRecord.ps1
    - src/Hephaestus/Private/ConvertFrom-HDTYaml.ps1
    - src/Hephaestus/Private/Assert-HDTRuleDocument.ps1
    - schemas/rules.schema.json
    - schemas/machine.schema.json
    - tests/unit/Get-HDTVariableMap.Tests.ps1
    - tests/unit/New-HDTErrorRecord.Tests.ps1
    - tests/unit/ConvertFrom-HDTYaml.Tests.ps1
    - tests/unit/Assert-HDTRuleDocument.Tests.ps1
    - tests/unit/Import-HDTRuleDocument.Tests.ps1
    - tests/contract/VariableNamespace.Contract.Tests.ps1
    - tests/contract/RulesSchema.Contract.Tests.ps1
    - tests/fixtures/rules/ (13 .yaml documents)
  modified:
    - src/Hephaestus/Hephaestus.psd1
    - docs/DESIGN.md
    - tests/fixtures/README.md
    - tests/helpers/README.md
    - .planning/ROADMAP.md

key-decisions:
  - "The schema uses oneOf, not the anyOf the plan specified: anyOf ACCEPTS a rule declaring both set and setFrom, which the engine rejects, and the two validators must agree"
  - "Duplicate rule names are a documented JSON Schema blind spot - draft-07 cannot express uniqueness of a property across array items - listed in the contract test rather than excluded from it"
  - "powershell-yaml is imported lazily and is NOT in RequiredModules: it would make the module unimportable wherever the dependency is absent and complicate WinPE staging"
  - "No parser exception is kept as an InnerException: the parser's SENTENCE is copied into the message instead, so no YamlDotNet or MethodInvocationException type escapes the adapter at any depth"
  - "After parsing, the locator is the rule ('rule 2 (Latitude naming)'), not a line: the parsed object graph carries no line information, and pretending otherwise would be a lie in an error message"
  - "Assert-HDTRuleDocument delegates the version comparison to Test-HDTSchemaVersion, asserted with a mock, rather than reimplementing DESIGN 12.3"
  - "DESIGN 3.2 corrected: the MDT counterpart of HDTComputerName is OSDComputerName. One row, fixed in the document rather than worked around in code"

# Metrics
duration: 150min
completed: 2026-08-13
---

# Phase 02 Plan 02: Authoring rules.yaml Summary

**`rules.yaml` is now a validated, normalised document, and every way of getting
it wrong produces a message an administrator can act on: a malformed file names
the file and the line, a badly authored one names the file and the rule, and both
carry the error id `HDTConfigurationError` — proven on both engines against
thirteen fixture documents, with the JSON Schema and the engine's own validator
asserted to agree on every one of them.**

## Test evidence — every count from a real run

| Step | pwsh 7.5.8 | Windows PowerShell 5.1.26100.8655 |
|---|---|---|
| Baseline, before this plan | 499 passed / 0 failed / 9 skipped | — |
| Task 1 RED — `Get-HDTVariableMap` absent | **25 failed** / 0 passed | — |
| Task 1 GREEN (`-Task ci`) | 530 passed / 0 failed / 9 skipped, lint 0 across 53 files | 525 passed / 0 failed / 14 skipped |
| Task 2 RED — both functions absent | **30 failed** / 0 passed | — |
| Task 2 GREEN (`-Task ci`) | 568 passed / 0 failed / 9 skipped, lint 0 across 57 files | 563 passed / 0 failed / 14 skipped |
| Task 3 RED — schemas moved aside, both functions absent | **75 failed** / 0 passed / 2 skipped | — |
| **Final, `-Task ci`** | **653 passed / 0 failed / 11 skipped**, lint **0 diagnostics across 62 files**, selfcheck 4/4 | **623 passed / 0 failed / 41 skipped** |

Every RED count was observed, and its failure reason read, before the code that
turns it green. `git log --oneline` shows `test(02-02)` before every
`feat(02-02)`.

**The 5.1 skip count is 41, not 14, and that is the design.** 27 of them are the
`RulesSchema` contract: `Test-Json` does not exist under Windows PowerShell 5.1,
so the file skips with an explicit warning printed by the run —

```
WARNING: RulesSchema contract SKIPPED: Test-Json does not exist on PowerShell
5.1.26100.8655 (Desktop). The schema is validated on the pwsh 7 leg;
Assert-HDTRuleDocument is what runs here.
```

The other two skips are the sample-workspace tests plan 02-03 un-skips.

The exit-criteria demonstration for ROADMAP M1's "not a crash" bullet, run
through the public cmdlet against a fake filesystem:

```
C:\ws\rules.yaml(4): the YAML in this file could not be parsed. While scanning a
plain scalar value, found invalid mapping.
HDTConfigurationError,ConvertFrom-HDTYaml
```

and the same cmdlet against DESIGN 3.3's own example:

```
Index Name            SetFrom
----- ----            -------
    1 Lab subnet
    2 Latitude naming
    3 Fallback
```

## What plan 02-03 codes against

### `Import-HDTRuleDocument` — the exact object shape

```powershell
Import-HDTRuleDocument -Path <string> -FileSystem <object>   # both mandatory
```

Returns

```powershell
[pscustomobject] @{
    Path          = <the path it was given, verbatim>
    SchemaVersion = <int>
    Rule          = @(
        [pscustomobject] @{
            Index   = <int, 1-based>
            Name    = <string>
            When    = <OrderedDictionary, OrdinalIgnoreCase; EMPTY, never $null, for a rule with no when>
            Set     = <OrderedDictionary, OrdinalIgnoreCase; $null for a setFrom rule>
            SetFrom = <string; $null for a set rule>
        }
    )
}
```

- `When` and `Set` are **re-materialised**, not passed through. Both are
  `[System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)`,
  so document order and case-insensitive lookup are guaranteed by this function
  rather than by whatever the parser happened to return.
- **Value types survive**: `HDTSkipWizard: true` arrives as `[bool]`,
  `schemaVersion: 1` as `[int]`, an unquoted `2026-08-13` as `[string]`.
- A missing file is `HDTConfigurationError` with `Category = ObjectNotFound`; the
  file is read with `TestPath` then `ReadAllText`, both recorded by the fake.

### `New-HDTErrorRecord` — signature and resulting error id

```powershell
New-HDTErrorRecord -Message <string> [-Path <string>] [-Line <int>]
                   [-ErrorId <string> = 'HDTConfigurationError']
                   [-Category <ErrorCategory> = 'InvalidData']
                   [-InnerException <Exception>]
    -> [System.Management.Automation.ErrorRecord]
```

Message composition, exactly:

| Given | Message |
|---|---|
| `-Path` and `-Line` | `{Path}({Line}): {Message}` |
| `-Path` only | `{Path}: {Message}` |
| neither | `{Message}` |

`-Path` is also the `TargetObject`. Thrown with
`$PSCmdlet.ThrowTerminatingError(...)`, the record's `FullyQualifiedErrorId` is
**`<ErrorId>,<FunctionName>`** — e.g. `HDTConfigurationError,ConvertFrom-HDTYaml`,
`HDTConfigurationError,Assert-HDTRuleDocument`. Match with
`-BeLike 'HDTConfigurationError*'`; the function half is not stable API.

Two error ids exist so far: `HDTConfigurationError` (bad authoring) and
`HDTDependencyError` (powershell-yaml missing, `Category = NotInstalled`).

### The fixture naming convention and the full list

`tests/fixtures/rules/`, and the prefix is a contract the schema test depends on:

| Prefix | Meaning |
|---|---|
| `valid-` | parses, passes the schema, passes `Assert-HDTRuleDocument` |
| `invalid-` | parses, fails `Assert-HDTRuleDocument`, and fails the schema except where noted |
| `unparseable-` | does not parse: `ConvertFrom-HDTYaml` throws |

| File | Content |
|---|---|
| `valid-design-example.yaml` | **DESIGN 3.3's example verbatim** — Lab subnet / Latitude naming / Fallback. 02-03's precedence tests run against it; do not improve it |
| `valid-setfrom.yaml` | a `setFrom:` rule plus a fallback |
| `valid-fallback-only.yaml` | one rule, no `when`, one `set` key |
| `invalid-missing-schemaversion.yaml` | no `schemaVersion` |
| `invalid-newer-schemaversion.yaml` | `schemaVersion: 99` |
| `invalid-rule-without-name.yaml` | a rule with no `name` |
| `invalid-rule-without-assignment.yaml` | neither `set` nor `setFrom` |
| `invalid-rule-with-both-assignments.yaml` | both `set` and `setFrom` |
| `invalid-unknown-rule-key.yaml` | `priority: 10` |
| `invalid-engine-variable.yaml` | `set: { _HDTLogPath: X:\Logs }` |
| `invalid-duplicate-rule-name.yaml` | two rules named `Fallback` |
| `unparseable-indentation.yaml` | mis-indented `set:` — parser error on **line 4** |
| `unparseable-duplicate-key.yaml` | `schemaVersion` twice — `Duplicate key schemaVersion` |

`tests/fixtures/README.md` carries the same table plus the encoding rule: UTF-8,
LF in git, and no test may depend on the line ending because `core.autocrlf`
converts on checkout.

### `Get-HDTVariableMap` — 40 rows

`Get-HDTVariableMap [-Name <string[]>]`, wildcards allowed, emitting
`HDTName` / `MdtName` / `Writable` / `Origin` / `Description`. `Origin` is a
`Class.Property` pair for a CIM fact, `environment.<name>`, `registry.<name>`,
`engine`, or `authored` — so the map doubles as the index of what
`Get-HDTMachineFact` reads. The contract test gathers the facts from the captured
fixtures and asserts every key it produces is in the map, which is the link that
stops the two drifting apart.

## Schema constructs that turned out unenforceable

**One, and it is documented rather than hidden.** JSON Schema draft-07 cannot
express "no two rules share a `name`" — there is no uniqueness constraint over a
property across array items — so `invalid-duplicate-rule-name.yaml` is the single
`invalid-` fixture `Test-Json` **accepts**. It is listed in
`$script:HDTSchemaBlindSpot` in the contract test, which asserts *both* halves:
the schema accepts it, and the engine rejects it. If a future schema gains the
ability, that test goes red and the file must be moved out of the list.

Everything else the plan asked for is enforced, verified by running `Test-Json`
against all thirteen fixtures. Confirming F6: the schema's *message* is often not
the real problem — `invalid-engine-variable.yaml` is reported as
`Required properties ["setFrom"] are not present at '/rules/0'`, true in schema
terms and useless to the person who wrote `_HDTLogPath`. `Assert-HDTRuleDocument`
owns the message a user reads; the schema is a gate for the console, editors and
CI (DESIGN 2.2).

## Phase 05 must stage powershell-yaml into the boot image

`powershell-yaml` is **not** in the manifest's `RequiredModules`, deliberately:
it would make the module unimportable wherever the dependency is absent, and it
would complicate WinPE staging. `ConvertFrom-HDTYaml` imports it lazily and
reports `HDTDependencyError` naming the module and `Install-Module powershell-yaml`
when it cannot.

**WinPE has no gallery.** Phase 05 must copy the `powershell-yaml` module into
the boot image alongside the engine, or every deployment fails at the first
`rules.yaml` read with that dependency error. Verified working identically on
both engines: version 0.4.12, `-Ordered` returning an `OrderedDictionary` in
document order on both.

## Deviations from plan

### Auto-fixed issues

**1. [Rule 1 - Bug] The plan's schema used `anyOf` for `set` / `setFrom`, which accepts a rule declaring both**
- **Found during:** Task 3, probing `Test-Json` against the fixtures before writing the contract test
- **Issue:** the plan specified `"anyOf": [{ "required": ["set"] }, { "required": ["setFrom"] }]` and, separately, that `invalid-rule-with-both-assignments.yaml` must fail the schema. `anyOf` is satisfied when *both* branches match, so the schema accepted it while the engine rejected it — the two validators would have disagreed on a fixture, which is the exact failure the agreement test exists to catch.
- **Fix:** `oneOf`. A rule with only `set` matches exactly one branch and is valid; a rule with both matches two and is rejected. Verified: `Expected 1 matching subschema but found 2 at '/rules/0'`.
- **Files modified:** `schemas/rules.schema.json`
- **Commit:** `6122608`

**2. [Rule 1 - Bug] `Get-Help` fuzzy-matches, so a help test passed for a command that did not exist**
- **Found during:** Task 3 RED
- **Issue:** `Get-Help -Name Assert-HDTRuleDocument -ErrorAction Stop` did not throw — it returned **`Get-HDTVariableMap`'s** help object, because `Get-Help` falls back to a search when no command matches exactly. `$help.Synopsis | Should -Not -BeNullOrEmpty` therefore passed against a command nobody had written. The two earlier help tests only went red because no similarly-named command existed yet, which means they would have started lying later.
- **Fix:** every comment-based-help test asserts `$help.Name | Should -BeExactly '<command>'` first. Applied to all five, including the three already green.
- **Files modified:** `tests/unit/Get-HDTVariableMap.Tests.ps1`, `tests/unit/New-HDTErrorRecord.Tests.ps1`, `tests/unit/ConvertFrom-HDTYaml.Tests.ps1`, `tests/unit/Assert-HDTRuleDocument.Tests.ps1`, `tests/unit/Import-HDTRuleDocument.Tests.ps1`
- **Commit:** `628f0da`

**3. [Rule 1 - Bug] Two "it threw" assertions passed against `CommandNotFoundException`**
- **Found during:** Task 2 RED and Task 3 RED
- **Issue:** `ConvertFrom-HDTYaml.does not leak a MethodInvocationException` and `Import-HDTRuleDocument.rejects every invalid fixture` both asserted only that *something* failed. A missing implementation throws `CommandNotFoundException`, which is not a `MethodInvocationException` and is not nothing — so both were green before any code existed.
- **Fix:** both now assert the identity of the failure (`FullyQualifiedErrorId -like 'HDTConfigurationError*'`, plus the message for the first), and both were then observed failing. Recorded in `tests/helpers/README.md` section 12 with the `Get-Help` trap.
- **Files modified:** `tests/unit/ConvertFrom-HDTYaml.Tests.ps1`, `tests/unit/Import-HDTRuleDocument.Tests.ps1`
- **Commits:** `c3415b1`, `52e15d7`

### Deliberate departures from the plan text

- **The parser exception is not kept as an `InnerException`.** The plan's
  `New-HDTErrorRecord` has an `-InnerException` parameter and `ConvertFrom-HDTYaml`
  could have used it, but the task's own done-criterion is that "no YamlDotNet or
  MethodInvocationException type escapes the adapter" — and an inner exception
  escapes. The parser's *sentence* is copied into the message instead, and the
  test walks the whole exception chain asserting neither type appears at any
  depth. `-InnerException` remains available and tested for callers that wrap a
  type of their own.
- **`Test-HDTScalarValue` was not created.** Writing a private helper during GREEN
  would have been a production function with no failing test of its own, so the
  five-type check is a local `$isScalar` expression at each of its two use sites.
- **The `-Skip` reason is warned at discovery time, not in `BeforeAll`.** The plan
  asked for `Write-Warning` in `BeforeAll`; Pester 5 does not run `BeforeAll` for a
  skipped `Describe`, so the warning would never have printed. It is emitted at
  file scope when `Test-Json` is absent, which is what produces the message quoted
  above in the real 5.1 run.
- **Three extra `It` blocks beyond the plan's lists**, each closing a gap the
  listed ones left: `covers every MDT name DESIGN 3.2 documents` (the reverse
  direction of the mapping), `marks every engine variable of DESIGN 4.4.1 as
  engine-owned`, and `keeps the value types the parser produced` (order and
  case-insensitivity were asserted, the types were not).
- **An extra top-level authoring rule.** `Assert-HDTRuleDocument` rejects an
  unknown *document* key as well as an unknown *rule* key, because the schema's
  top-level `additionalProperties: false` does, and the agreement test would
  eventually have found the gap.

## Known gaps, stated plainly

- **The schema is only exercised under pwsh 7.** `Test-Json` does not exist under
  Windows PowerShell 5.1 — which is the engine that runs in WinPE — so the 5.1 leg
  proves `Assert-HDTRuleDocument` and nothing about the schema. That asymmetry is
  the reason the engine carries its own validator at all, and the skip is loud
  rather than silent.
- **Duplicate rule names are engine-only**, as above.
- **`samples/workspace/` does not exist yet**, so two schema tests ship `-Skip`
  with the reason "written by plan 02-03". 02-03 removes both skips.
- **`%Var%` expansion, `when` matching and precedence are not implemented here.**
  This plan is the authoring half of M1: read, validate, normalise. Resolution is
  02-03.
- **No rules document has been read from a real share.** Every test drives
  `Import-HDTRuleDocument` through `New-HDTFakeFileSystem`; the real `IFileSystem`
  adapter does not arrive until phase 04.

## Self-Check: PASSED

All 15 created files verified present on disk; all 8 commits verified present in
`git log`.
