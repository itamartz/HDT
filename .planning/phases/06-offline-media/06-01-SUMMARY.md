---
phase: 06-offline-media
plan: 01
subsystem: variables
tags: [media, variables, rules, validation]
requires: []
provides:
  - Get-HDTDeploymentMethod
  - HDTDeploymentMethod (variable map row, not writable)
  - the map-driven refusal in Assert-HDTRuleDocument and Resolve-HDTVariable
affects:
  - src/Hephaestus/Public/Get-HDTVariableMap.ps1
  - src/Hephaestus/Private/Assert-HDTRuleDocument.ps1
  - src/Hephaestus/Public/Resolve-HDTVariable.ps1
tech-stack:
  added: []
  patterns:
    - "Writable is a default with an explicit opt-out, the way Secret already is"
    - "a refusal driven by a map column, not by a name written into the validator"
key-files:
  created:
    - src/Hephaestus/Public/Get-HDTDeploymentMethod.ps1
    - tests/unit/Get-HDTDeploymentMethod.Tests.ps1
  modified:
    - src/Hephaestus/Public/Get-HDTVariableMap.ps1
    - src/Hephaestus/Private/Assert-HDTRuleDocument.ps1
    - src/Hephaestus/Public/Resolve-HDTVariable.ps1
    - src/Hephaestus/Hephaestus.psd1
    - docs/command-categories.psd1
    - docs/command-reference.html
    - docs/DESIGN.md
    - tests/contract/VariableNamespace.Contract.Tests.ps1
    - tests/unit/Get-HDTVariableMap.Tests.ps1
    - tests/unit/Assert-HDTRuleDocument.Tests.ps1
    - tests/unit/Resolve-HDTVariable.Tests.ps1
decisions:
  - "Get-HDTDeploymentMethod is public, because Start-HDTDeployment.ps1 is a script and only FunctionsToExport exists there"
  - "Writable became an explicit per-row opt-out rather than a prefix rule"
  - "the refusal loops the map's non-writable set, so the next engine variable is refused the day its row lands"
  - "setFrom's output guard was widened too - it is a second door and it was open"
metrics:
  tasks: 3
  commits: 3
  gate: "13432 passed, 0 failed, 268 skipped; lint 0 diagnostics across 1110 files"
  completed: 2026-09-02
---

# Phase 06 Plan 01: HDTDeploymentMethod exists Summary

`HDTDeploymentMethod` is now a name the module knows about on every surface that
enumerates names — one command that decides it from the provider, one map row
that documents it as engine-owned, and a refusal that stops an administrator
declaring it through either of the two doors that could set it.

Nothing here publishes a value or changes a deployment's behaviour. Plan 02
publishes it; plan 03 reads it.

## What was built

**`Get-HDTDeploymentMethod -Provider Smb|Local` → `UNC`|`MEDIA`.** Two values,
and the `ValidateSet` is the refusal, so a third gets the same shape of error
`Resolve-HDTDeployRoot` gives for the same mistake. No `OSD`, no `SCCM` — those
are MECM's and rule 4 forbids the dependency.

It decides from the provider `bootstrap.json` already names rather than from
MDT's drive walk for a media marker. MDT's `LiteTouch.wsf` (lines 267-324) has
nothing better to go on; HDT does, and the difference is that the answer cannot
disagree with the provider actually in use — a stale marker on a second disk
cannot talk a deployment out of the network it is really reading from.

**The drift test is written against the set.** It reads `Resolve-HDTDeployRoot`'s
`-Provider` `ValidateSet` by reflection and asserts every value in it produces
`UNC` or `MEDIA`. A provider added there tomorrow fails here rather than
silently defaulting.

**The map row, and `Writable` as a fact.** `Get-HDTVariableMap.ps1` computed
`Writable` from the underscore, which was both the default and the law.
`HDTDeploymentMethod` carries no underscore — MDT's name is `DeploymentMethod`
and a step condition reads `%HDTDeploymentMethod%` — and is still not an
administrator's to set, so the row spells out `Writable = $false` the way a
handful of rows already spell out `Secret`. `HDTDeploymentType` is untouched:
still writable, still `DeploymentType`, still `NEWCOMPUTER`, and a media
deployment is still `NEWCOMPUTER`.

**The refusal is driven by the map column.** `Assert-HDTRuleDocument` refuses
every name `Get-HDTVariableMap` marks not writable, so the next engine-published
variable is refused the day its row lands rather than the day somebody remembers
the validator. The `_HDT*` check keeps its own message, which names the naming
convention and is the right thing to say for that case.

## The finding the plan asked for: setFrom has a door, and it was open

The plan asked this be recorded either way. **`setFrom`'s returned variables
ARE validated, in one place, and that guard was widened here.**

`Resolve-HDTVariable.ps1` (now ~line 279) already refused a returned name
starting with `_`. It runs at RESOLVE time, after every document validator has
finished — so before this change a rule that could not write
`HDTDeploymentMethod` in its own `set:` block could call a `setFrom` script that
returned it and have it accepted. Same map column guards both now, and a
set-driven test in `tests/unit/Resolve-HDTVariable.Tests.ps1` loops every
non-writable name through the script path.

For plan 02 and anything later: **the refusal has exactly two doors and both are
closed.** The document validator and the setFrom output guard.

## Surfaces that already got it for free, and four that did not

`New-HDTWorkspace.ps1:325`, `Get-HDTConsoleEditorState.ps1:442` and
`Get-HDTConsoleSequenceEditor.ps1:168` filter their variable catalogues on
`$_.Writable`, so they exclude `HDTDeploymentMethod` with no edit — which is the
map-driven design paying for itself.

**Four other refusals still test the underscore rather than the column**, and
are therefore places a non-underscore engine variable could still be assigned.
They were outside this plan's scope and were deliberately not changed:

| File | Line | Refuses |
|---|---|---|
| `Public/Get-HDTMachineOverride.ps1` | 168 | a per-machine override CSV column |
| `Public/Set-HDTSequenceVariable.ps1` | 96 | a variable set from the console editor |
| `Private/Add-HDTResolvedVariable.ps1` | 125 | a resolved variable, at the sink |
| `Private/Assert-HDTSequenceDocument.ps1` | 184 | a `variables:` block in a sequence.yaml |

None of them can be reached by `rules.yaml`, which is what this plan was asked
to close. A follow-up that widens all four to the map column would be four
edits and four set-driven tests, and it is the honest next step for whoever
adds the second non-underscore engine variable.

## Deviations from Plan

**1. [Rule 3 - Blocking] The manifest is not alphabetical, so "alphabetical
position" had no meaning.** The plan said `Get-HDTDeploymentMethod` sorts
between `Get-HDTDeploymentFailure` (line 150) and `Get-HDTDiskLayout` (line 79)
— those are 70 lines apart and `FunctionsToExport` is grouped by subject, not
sorted. Placed it beside `Resolve-HDTDeployRoot`, its closest sibling, and in
`command-categories.psd1` under `disks-and-imaging` for the same reason (that is
where `Resolve-HDTDeployRoot` already lives).

**2. [Rule 1 - Bug in a test I had just written] The shared probe scriptblock
made every assertion pass or fail on the wrong thing.** The first cut of the
`Assert-HDTRuleDocument` context passed a `$script:`-scoped scriptblock into
`InModuleScope`. A scriptblock runs in the session state it was CREATED in, so
`ConvertFrom-HDTYaml` was not visible and eight assertions failed on
`CommandNotFound` instead of on the validator. Rewritten to the file's existing
inline pattern, with a comment saying why it is written out in full.

**3. [Method] Two refusal assertions passed before the implementation existed
and were tightened.** `{ Get-HDTDeploymentMethod -Provider 'Http' } | Should
-Throw` passes while the command does not exist at all. Both now assert the
`ValidateSet` message, so they were red for the right reason.

**4. The description does not mention OSD or SCCM.** The plan's suggested
description text ended "MDT also has OSD and SCCM; HDT has neither" while the
plan's own test asserted the description mentions neither. Followed the test:
the MECM explanation is in the comment above the row and in `DESIGN.md`, where
CLAUDE.md says the reasoning belongs, and the description offers only the two
values the engine can produce.

**5. `Hephaestus.bundle.ps1` is gitignored** and so is not in any commit, though
it was regenerated with `./build.ps1 -Task bundle` after every source change as
the plan required.

**6. The gate bumped the module version** to 0.16.0 and rewrote the source
hashes — `build.ps1 ci` runs the `version` task. Left uncommitted; that is a
release action, not this plan's.

## Verification

Run under Windows PowerShell 5.1 only. The pwsh 7 pass was not run.

- Affected suites, all green: **162 passed, 0 failed** across
  `Get-HDTDeploymentMethod`, `Get-HDTVariableMap`, `Assert-HDTRuleDocument`,
  `Resolve-HDTVariable`, `VariableNamespace.Contract`, `CommandReference.Contract`.
- Full gate: `BUILD SUCCEEDED (clean, version, bundle, build, lint, test,
  selfcheck) on PowerShell 5.1.26100.8655` — **13432 passed, 0 failed, 268
  skipped**, lint **0 diagnostics across 1110 files**.
- Read the row back, which the tests cannot do for you:
  `HDTDeploymentMethod / DeploymentMethod / False / engine` beside
  `HDTDeploymentType / DeploymentType / True / engine`.
- Probed against real YAML through `Import-HDTRuleDocument`, not only against a
  hand-built hashtable. It threw, naming the file, `rule 1 ('Wrong')`,
  `HDTDeploymentMethod`, the reason it is a fact about how the machine booted,
  and `Get-HDTVariableMap` as the way to find what a rule may set.

## Commits

| Commit | Task |
|---|---|
| `3003650` | `Get-HDTDeploymentMethod` and the four surfaces a public command reaches |
| `72bf892` | the map row, and `Writable` stops being a prefix |
| `92529e6` | the refusal, by either door |

## Self-Check: PASSED

Every created file exists, all three commit hashes resolve, the command is named
in the manifest, `command-categories.psd1` and `command-reference.html`, and the
map-driven `$unsettable` set appears in both validators.
