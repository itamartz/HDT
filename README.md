# Hephaestus Deployment Toolkit (HDT)

A replacement for the Microsoft Deployment Toolkit, which has been in maintenance
mode since 2019. HDT keeps MDT's operational model — deployment share, task
sequences, driver store, application catalog — and rebuilds the engine on
PowerShell instead of VBScript/WSH.

**HDT depends on no MDT component.** The Windows ADK and WDS are used, and
nothing else from Microsoft's deployment stack.

## The PowerShell 5.1 constraint

The engine runs inside WinPE, and WinPE ships Windows PowerShell 5.1 only —
there is no `pwsh` there. Everything under `src/Hephaestus/` must therefore parse
and run under 5.1. No `??`, no `?.`, no ternary, no `ForEach-Object -Parallel`,
no `$PSStyle`, no `clean` blocks, no `ConvertFrom-Json -AsHashtable`.

The full suite runs under **both** engines, and a change is not done until it is
green under both.

## Repo layout

```
src/Hephaestus/     PowerShell module - the engine
src/HDT.Console/    WPF console (last, optional)
schemas/            JSON Schema per YAML file type
tests/unit/         Majority of tests - pure logic against fakes
tests/contract/     Schema, naming, no-MDT, PS 5.1 syntax, provider contracts
tests/integration/  Real DISM/VHDX/ADK
tests/e2e/          Hyper-V
tests/fixtures/     Real .inf headers, captured CIM shapes, sample workspaces
tests/helpers/      HDTTestTools - shared build and test helpers
samples/            Example workspaces and sequences
docs/               DESIGN.md, ROADMAP.md
```

## Building and testing

```powershell
./build.ps1 -Task test       # unit + contract suites (the default task)
./build.ps1 -Task lint       # PSScriptAnalyzer over every HDT source file
./build.ps1 -Task build      # validate the manifest and stage the module to out/
./build.ps1 -Task clean      # remove out/
./build.ps1 -Task selfcheck  # prove the harness catches a failing test
./build.ps1 -Task ci         # clean -> build -> lint -> test -> selfcheck
```

Tasks always run in the canonical order
`clean -> build -> lint -> test -> selfcheck`, whatever order they are given in.
The script exits 0 on success and 1 on failure.

Run it under both engines before calling anything done:

```powershell
pwsh -NoProfile -File ./build.ps1 -Task test
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File ./build.ps1 -Task test
```

`test` deliberately does not depend on `lint`: PSScriptAnalyzer is not importable
under Windows PowerShell 5.1 on every machine, and the exit criterion is that
`test` passes under 5.1. `lint` fails with an actionable message where the
analyzer is unavailable, so `./build.ps1 -Task ci` is expected to fail under 5.1
on such a machine — and to pass in CI, where the workflow installs the analyzer
for both editions.

Pester imports are pinned — `-MinimumVersion 5.0.0 -MaximumVersion 5.99.99`.
Pester 6.0.0 is installed on some machines and wins a bare import under 5.1.

## The harness proves itself

`./build.ps1 -Task selfcheck` does not test the product; it tests the test
harness, because a suite nobody has watched go red is not a suite. It runs the
deliberately red and deliberately green fixtures in `tests/selfcheck/` and the
deliberately dirty `tests/fixtures/analyzer/AnalyzerBait.ps1`, and fails unless:

1. the failing fixture fails,
2. the passing fixture passes,
3. a **child process** running the failing fixture exits non-zero — the exit-code
   path CI depends on, which cannot be observed from inside the run under test,
4. PSScriptAnalyzer reports violations for the bait, including
   `PSUseCompatibleSyntax`, which proves the 5.1 target version in
   `PSScriptAnalyzerSettings.psd1` is in force.

Check 4 is skipped with a warning where the analyzer cannot be imported.
`tests/selfcheck/` is never in `Run.Path` for `test`, so those fixtures can never
turn the real suite red. See `tests/helpers/README.md` section 9.

## Continuous integration

`.github/workflows/ci.yml` runs on `windows-latest` in a matrix over `pwsh` and
`powershell` — the latter *is* Windows PowerShell 5.1, which is what makes the
dual-engine requirement real rather than aspirational. `fail-fast` is disabled so
both editions always report. Module versions are pinned, and the workflow runs
`./build.ps1 -Task ci`, the same entry point developers use; CI never grows its
own build logic (DESIGN §12.2.5).

## Variables and rules

HDT replaces `CustomSettings.ini` + `ZTIGather` with `rules.yaml` and a
five-source resolution engine — and, unlike MDT, it tells you *why* every
variable ended up as it did.

```powershell
Import-Module ./src/Hephaestus/Hephaestus.psd1

$fact  = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
                            -RegistryService (New-HDTRegistryService) `
                            -EnvironmentProvider (New-HDTEnvironmentProvider)
$rules = Import-HDTRuleDocument -Path 'X:\Deploy\rules.yaml' -FileSystem (New-HDTFileSystem)
$r     = Resolve-HDTVariable -RuleDocument $rules -Fact $fact -ScriptInvoker (New-HDTScriptInvoker)

Get-HDTVariableProvenance -Resolution $r | Format-Table Order, Name, Value, Source, Rule -AutoSize
```

```
Order Name              Value            Source       Rule
----- ----              -----            ------       ----
    1 HDTComputerName   PC-PF3EKMR0      Rule         Fallback
    2 HDTJoinWorkgroup  WORKGROUP        Rule         Fallback
    3 HDTMake           LENOVO           GatheredFact
```

Sources, highest precedence first: `CommandLine`, `MachineOverride`, `Rule` /
`RuleScript`, `GatheredFact`, `SequenceDefault`. Nothing overwrites a variable an
earlier source resolved, so a later rule can only act as a fallback. The same
records go to `<_HDTLogPath>\Gather\provenance.json` via
`Export-HDTVariableProvenance`.

See [samples/README.md](samples/README.md) for a workspace to copy.

## Status

**Phase 01 (M0 — skeleton and harness) is complete.** The module skeleton, the
`HDTTestTools` and `HDTFakes` helper modules, `build.ps1`, the naming /
PowerShell 5.1 / no-MDT contract tests, the first service fakes and their
contracts, the harness self-proof and CI are all in place. `./build.ps1 -Task
test` is green on a clean clone under both engines.

**Phase 02 (M1 — variables and rules) is complete.** Fact gathering behind
`ICimProvider`, the `rules.yaml` parser and schema, the five-source resolution
engine with `%Var%` expansion and `setFrom:` script rules, and provenance —
queryable with `Get-HDTVariableProvenance` and written to `provenance.json`. The
M1 exit criterion is demonstrated end to end in
`tests/unit/GatherAndResolve.EndToEnd.Tests.ps1`, over fixtures and fakes only.

## Test-driven, without exception

A failing Pester test exists before the implementation it covers. Every time.
The sole exception is thin adapters over external tools (DISM, CIM, oscdimg,
registry), which must stay branch-free precisely because they are not unit
tested.

## Command naming

**Every PowerShell command in HDT is named `Verb-HDTNoun`, with `HDT` uppercase**
— public cmdlets, private helpers, adapters, test helpers and build functions
alike. Approved verbs only, singular nouns.

The engine dot-sources user scripts from `Scripts\` and third-party step types
from `Modules\` inside WinPE, so an unprefixed `Invoke-Dism` is a live collision
risk. This is enforced by a contract test in `tests/contract/`, not by review.

## Documentation

- [docs/DESIGN.md](docs/DESIGN.md) — the technical design. Authoritative.
- [docs/ROADMAP.md](docs/ROADMAP.md) — milestones M0–M8, each with a
  "Tests first" list and exit criteria.
