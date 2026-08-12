---
phase: 01-harness
plan: 03
subsystem: testing
tags: [pester, fakes, service-contracts, cim, filesystem, powershell-classes, fixtures]

# Dependency graph
requires:
  - phase: 01-harness plan 01
    provides: build.ps1 task runner, Pester 5 harness, Get-HDTSourceFile
  - phase: 01-harness plan 02
    provides: naming / PS5.1 / no-MDT contracts that now cover the new files automatically
provides:
  - "tests/helpers/HDTFakes - the fakes module, classes defined inline in HDTFakes.psm1"
  - "New-HDTFakeFileSystem - in-memory IFileSystem, eight methods, operation recording"
  - "New-HDTFakeCimProvider - ICimProvider seeded from captured fixtures, namespace aware"
  - "tests/contract/FileSystemService.Contract.Tests.ps1 - the IFileSystem contract as tests"
  - "tests/contract/CimProvider.Contract.Tests.ps1 - the ICimProvider contract as tests"
  - "tests/fixtures/cim/*.json - four sanitised CIM classes from DESIGN 3.2.1"
  - "tests/helpers/README.md - the nine fake conventions phases 02-09 follow"
  - "tests/fixtures/README.md - fixture layout, capture command, sanitisation table"
  - "$script:HDTImplementation contract-registry pattern - a real adapter is one row"
affects: [02-rules, 03-engine, 04-imaging, 05-boot-image, 06-drivers, 07-apps, 08-console]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "PowerShell classes defined inline in a .psm1 and reached only through a New-HDTFake* factory; never a type literal in a test"
    - "Contract test per service with a discovery-time $script:HDTImplementation registry, Describe -ForEach over it"
    - "Contract factories are invoked as & $Factory $repositoryRoot rather than closing over a discovery-phase variable"
    - "Fakes record every call - including read-only calls, and including calls that then threw - in $Operations with Sequence/Operation/Arguments"
    - "Fakes throw the exception type the real adapter throws; contracts assert -ExceptionType, not the message"
    - "CIM fixtures are JSON arrays named after the class, sanitised over the whole text before staging"

key-files:
  created:
    - tests/helpers/HDTFakes/HDTFakes.psd1
    - tests/helpers/HDTFakes/HDTFakes.psm1
    - tests/helpers/README.md
    - tests/unit/New-HDTFakeFileSystem.Tests.ps1
    - tests/unit/New-HDTFakeCimProvider.Tests.ps1
    - tests/contract/FileSystemService.Contract.Tests.ps1
    - tests/contract/CimProvider.Contract.Tests.ps1
    - tests/fixtures/README.md
    - tests/fixtures/cim/Win32_ComputerSystem.json
    - tests/fixtures/cim/Win32_ComputerSystemProduct.json
    - tests/fixtures/cim/Win32_BaseBoard.json
    - tests/fixtures/cim/Win32_BIOS.json
    - tests/fixtures/naming/ClassMember.psm1
  modified:
    - tests/helpers/HDTTestTools/tools/Get-HDTSourceFunction.ps1
    - tests/unit/Get-HDTSourceFunction.Tests.ps1

key-decisions:
  - "Class members are excluded from function discovery: PowerShell nests a FunctionDefinitionAst inside every FunctionMemberAst, and DESIGN 15.1 names commands while a service contract names its own methods"
  - "Contract factories take the repository root as an argument because Pester 5 drops discovery-phase variables before the run phase"
  - "An unseeded CIM class throws naming the class; a class seeded with an empty array returns @() - 'no such class' and 'class exists, no instances' are different facts"
  - "GetChildItem sorts ordinal explicitly, so an implementation cannot inherit whatever order its store happens to return"
  - "GetLength reports the UTF8 byte count, matching what a real adapter writing UTF8 without BOM would produce"
  - "OEMLogoBitmap is excluded from the Win32_ComputerSystem fixture: half a megabyte of byte array no test will read"

# Metrics
duration: 70min
completed: 2026-08-13
---

# Phase 01 Plan 03: First fakes and service contracts Summary

**Two hand-written service doubles — an in-memory filesystem and a CIM provider seeded from four sanitised classes captured off this machine — together with the IFileSystem and ICimProvider contracts written as tests rather than prose, so a real adapter added in a later phase is one row in a registry and not a new test file.**

## What was built

### `tests/helpers/HDTFakes/` — the fakes module

Both classes are defined **inline in `HDTFakes.psm1`**. Dot-sourced class
definitions are the known-flaky path across `-Force` re-imports; inline ones are
not. Tests reach them only through the factory, and never write the class name as
a type literal, because a type literal binds to whichever dynamic assembly loaded
first.

Exports exactly `New-HDTFakeCimProvider`, `New-HDTFakeFileSystem` — verified
under both engines.

### IFileSystem — final method signatures

Phase 02 onward codes against exactly these:

| Method | Behaviour |
|---|---|
| `[bool] TestPath([string] $Path)` | true if a file or directory exists at Path |
| `[string] ReadAllText([string] $Path)` | contents; `FileNotFoundException` if absent, `UnauthorizedAccessException` if Path is a directory |
| `[void] WriteAllText([string] $Path, [string] $Content)` | overwrites; creates missing parent directories |
| `[void] CreateDirectory([string] $Path)` | idempotent; creates intermediates |
| `[void] RemoveItem([string] $Path, [bool] $Recurse)` | no-op if absent; `IOException` for a non-empty directory when `$Recurse` is `$false` |
| `[void] CopyItem([string] $Source, [string] $Destination)` | `FileNotFoundException` if Source absent; creates destination parents |
| `[string[]] GetChildItem([string] $Path)` | immediate children as full paths, sorted **ordinal**; `DirectoryNotFoundException` if absent |
| `[long] GetLength([string] $Path)` | UTF8 byte count; `FileNotFoundException` if absent |

Paths are normalised with `[System.IO.Path]::GetFullPath()`, stripped of a
trailing separator (except a bare root such as `C:\`) and compared
case-insensitively. Backed by two `OrdinalIgnoreCase` hashtables — one for file
content, one as a directory set, held separately so an empty directory still
exists.

### ICimProvider — final method signatures

| Method | Behaviour |
|---|---|
| `[object[]] GetInstance([string] $ClassName)` | instances from the default namespace `root/cimv2` |
| `[object[]] GetInstance([string] $Namespace, [string] $ClassName)` | explicit namespace — needed for `root/cimv2/security/microsofttpm` / `Win32_Tpm` (DESIGN 3.2.1) |
| `[void] AddInstance([string] $Namespace, [string] $ClassName, [object[]] $Instance)` | fake-only seeding, not recorded |

Keyed by `"namespace|class"` lower-cased with separators normalised, so
`root\cimv2` and `root/cimv2` are the same namespace. A class that was never
seeded **throws naming the class**, the way `Get-CimInstance` reports an invalid
class; a class seeded with an empty array **returns `@()`**, because "the class
exists but this machine has no instances" is a different fact that a fact
gatherer has to be able to tell apart.

### The `$Operations` record shape

Both fakes, and every fake after them:

```
[System.Collections.ArrayList] $Operations   # one [pscustomobject] per call
    Sequence   1-based call number
    Operation  the method name
    Arguments  object[] of the arguments, in declaration order

[string[]] GetOperationName()                # the ordered operation names
```

Three rules that make it useful: read-only calls record too; the record is
written **before** the method can throw, so query order shows what the code under
test *tried*; and seeding is never recorded, so the first entry is the first
thing the code under test did.

The DESIGN 12.2.1 assertion, in miniature and green:

```powershell
$fs.GetOperationName() | Should -Be @('CreateDirectory', 'WriteAllText', 'TestPath', 'ReadAllText')
```

### The contract-registry pattern

Each `tests/contract/<Service>.Contract.Tests.ps1` declares, **at discovery
time** (Pester 5 expands `-ForEach` while discovering, so a `BeforeAll` registry
yields zero test cases):

```powershell
$script:HDTImplementation = @(
    @{ Name = 'FakeCimProvider'; Factory = { param($RepositoryRoot) New-HDTFakeCimProvider -FixturePath (Join-Path -Path $RepositoryRoot -ChildPath 'tests/fixtures/cim') } }
)

Describe 'ICimProvider contract: <Name>' -ForEach $script:HDTImplementation {
    BeforeEach { $script:cim = & $Factory $script:repoRoot }
```

The factory is **passed** the repository root rather than closing over it: a
discovery-phase variable does not survive into the run phase. Adding the real
adapter in phase 02 is one row.

### Fixture sanitisation rule

Captured with `Get-CimInstance | Select-Object -Property * -ExcludeProperty Cim*, PS*, OEMLogoBitmap`,
written as a **JSON array** named after the class, then sanitised by replacing
over the whole JSON text, case-insensitively, keeping every property present and
its type identical:

| Property | Replacement |
|---|---|
| `SerialNumber`, `IdentifyingNumber` | `FIXTURE-SERIAL-0001` |
| `UUID` | `4C4C4544-0031-3610-8052-B7C04F515A31` |
| host name in `Name` / `Caption` / `DNSHostName` | `FIXTUREPC` |
| `UserName` | `FIXTUREPC\Fixture` |
| `PrimaryOwnerName` | `Fixture` |

Whole-text replacement matters: the real serial also appeared inside
`SoftwareElementID` and `BIOSVersion`. Manufacturer, model, SKU, family and
firmware version are kept — hardware facts, not personal ones, and phase 02's
rule matching needs a realistic `Model` to match on.

## Test evidence — every count from a real run

| Step | pwsh 7.5.8 | Windows PowerShell 5.1.26100.8655 |
|---|---|---|
| Task 1 RED (fakes module absent) | 37 failed / 204 passed | — |
| Class-member bug RED | 2 failed / 11 passed (single file) | — |
| Task 1 GREEN | 246 passed / 0 failed | 244 passed / 0 failed |
| Task 2 RED (`New-HDTFakeCimProvider` absent) | 26 failed / 24 passed (three files) | — |
| Task 2 GREEN, final | **276 passed / 0 failed / 9 skipped** | **274 passed / 0 failed / 11 skipped** |
| `lint` | 0 diagnostics across 32 files | not run (PSScriptAnalyzer is not importable under 5.1 here — by design, `test` never depends on `lint`) |
| `build.ps1 -Task ci` | exit 0 | — |
| `build.ps1 -Task test` | — | exit 0 |

The 9/11 skips are pre-existing engine-conditional tests from plans 01-01 and
01-02, not new.

**Failure path proven, not assumed.** With `[array]::Sort(...)` removed from
`GetChildItem` and the CIM "invalid class" message stripped of the class name,
the contracts went red — 2 failed under pwsh (`returns children sorted`,
`throws for a class that does not exist, naming the class`), 1 under 5.1 (the
CIM one; the unsorted case happened to enumerate in the expected order on that
engine, so the sort break was masked there). Both breakages were reverted and
`git status` is clean.

**Fixture leak scan, run against committed content:** zero hits for this
machine's real serial, UUID, host name or user name in any of the four JSON
files; `git log --all -S` finds zero commits that ever contained the real serial
or UUID.

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 1 - Bug] Class members were being reported as functions by `Get-HDTSourceFunction`**

- **Found during:** Task 1 GREEN. The naming contract failed with 17 violations
  the moment the first PowerShell class entered the repository —
  `HDTFakeFileSystem`, `TestPath`, `ReadAllText` and so on, none of which are
  commands.
- **Issue:** PowerShell represents a constructor, instance, hidden or static
  method as a `FunctionMemberAst` that **contains a `FunctionDefinitionAst`**, so
  `FindAll({ ... -eq 'FunctionDefinitionAst' }, $true)` matches every class
  member. DESIGN 15.1 governs command names; a service contract fixes its own
  method names (`IFileSystem.TestPath`). Left alone, this rule would have banned
  PowerShell classes from the project outright.
- **Fix:** skip any `FunctionDefinitionAst` whose parent is a `FunctionMemberAst`.
  Written test-first: `tests/fixtures/naming/ClassMember.psm1` (class with all
  four member kinds plus a top-level and a nested function) and three new `It`s,
  RED at 2 failed / 11 passed before the one-line fix.
- **Files modified:** `tests/helpers/HDTTestTools/tools/Get-HDTSourceFunction.ps1`,
  `tests/unit/Get-HDTSourceFunction.Tests.ps1`,
  `tests/fixtures/naming/ClassMember.psm1`
- **Commits:** `772fe23` (RED), `1d397e8` (GREEN)

**2. [Rule 3 - Blocking] Contract factories could not close over a discovery-phase variable**

- **Found during:** Task 2 RED. The CIM contract failed with
  `The variable '$script:HDTFixturePath' cannot be retrieved because it has not
  been set` — the wrong reason, so the RED was not yet honest.
- **Issue:** Pester 5 discards script-scope variables set during discovery before
  the run phase begins. The plan's sketch
  (`Factory = { New-HDTFakeCimProvider -FixturePath "$PSScriptRoot/../fixtures/cim" }`)
  has the same problem: `$PSScriptRoot` is not bound in the run-phase scope either.
- **Fix:** the factory is invoked as `& $Factory $repositoryRoot` and declares
  `param($RepositoryRoot)` if it uses it. Applied to both contract files so the
  registry pattern is identical, and documented in `tests/helpers/README.md`.
- **Commit:** `84a159d`

**3. [Rule 2 - Missing] Two coverage gaps in the fakes' own tests**

Added beyond the plan's list, because the other assertions depend on them:
`does not record seeding as an operation` (both fakes — without it the
`Sequence` numbering assertions are meaningless), `reads no data from the real
filesystem`, `records a query that threw`, `treats backslash and forward slash
namespace separators as the same namespace`, and `is independent between
instances` for the CIM fake.

**4. [Rule 3 - Blocking] Analyzer diagnostics on the new files**

`PSUseShouldProcessForStateChangingFunctions` on `New-HDTFakeFileSystem` and
`New-HDTFakeCimProvider` — suppressed with the justification already established
by `New-HDTPesterConfiguration` in plan 01-01 ("builds an in-memory object; it
changes no state"). `PSReviewUnusedParameter` on an unused
`param($RepositoryRoot)` in the filesystem registry row — that row now simply
ignores the argument.

### Judgement calls worth recording

- **`OEMLogoBitmap` excluded from the CIM capture.** The plan's capture command
  produced a **501 KB** `Win32_ComputerSystem.json`, essentially all of it one
  byte array. Excluded; the file is now 2.2 KB. Recorded in
  `tests/fixtures/README.md` as rule 4 of the capture.
- **Contract file paths are rooted at `$TestDrive`.** The plan did not say where
  the contract's paths should live. Using `$TestDrive` means a real filesystem
  adapter added in phase 04 passes the same file without editing a single path.
- **`GetLength` is a UTF8 byte count.** The contract says "byte length"; the fake
  stores strings, so the honest reading is the encoding a real adapter would
  write with (`WriteAllText` without BOM).

### Not a deviation, but the user should know

A concurrent process committed to this repository again mid-execution —
`4c1788f "Resolve DESIGN 4.5.2: LSA secret and AutoLogonCount coexist natively"`
landed between the plan's RED and GREEN commits for Task 2. It touched only
`docs/DESIGN.md`, nothing this plan owns; CI was re-run green afterwards.

Separately, the pre-existing `.planning/SPIKES.md` header records
`Host: LAP-AMMSO01` — this machine's real host name, committed in an earlier
phase as spike provenance. It is outside this plan's scope and no fixture
contains it, but it is the one place the real host name exists in git history.

## Verification against the plan's block

1. `pwsh -NoProfile -File ./build.ps1 -Task ci` → **exit 0** (clean, build,
   lint 0 diagnostics / 32 files, test 276 passed).
2. `powershell.exe -NoProfile -File ./build.ps1 -Task test` → **exit 0**
   (274 passed).
3. `Get-Command -Module HDTFakes` → exactly `New-HDTFakeCimProvider`,
   `New-HDTFakeFileSystem`, under both engines.
4. No fixture contains the real serial, UUID, host name or user name —
   scanned against the committed blobs and against all of git history.
5. Both contract files carry the `$script:HDTImplementation` registry at
   discovery time, with the future adapter row present as a comment.

Additionally confirmed that the plan 01-02 contracts pick the new files up
automatically: `Get-HDTSourceFile` now returns 31 files including
`HDTFakes.psm1` and still excludes `tests/fixtures/**`; 18 functions discovered
(up from 16), including both new factories; 0 naming violations, 0 compatibility
violations, 0 MDT dependencies.

## What phase 02 can now do on day one

Gather facts behind `ICimProvider` against
`New-HDTFakeCimProvider -FixturePath ./tests/fixtures/cim` with no machine
attached, assert on real `Manufacturer` / `Model` / `SerialNumber` / `UUID`
shapes, seed `Win32_Tpm` into `root/cimv2/security/microsofttpm`, read and write
`rules.yaml` through `New-HDTFakeFileSystem`, and assert the exact ordered list
of operations the gatherer performed. Adding the real `Get-CimInstance` adapter
means appending one row to `$script:HDTImplementation` and writing no new test.

## Self-Check: PASSED

All 15 claimed files verified present on disk. All 8 claimed commit hashes
verified in `git log --all`. Artifact minimums met: `HDTFakes.psm1` 475 lines
(min 120), `tests/helpers/README.md` 171 lines (min 30). Both contract files
contain `ForEach`; both key_links resolve (`FileSystemService.Contract.Tests.ps1`
names `New-HDTFakeFileSystem`; `HDTFakes.psm1` reaches
`tests/fixtures/cim/*.json` through `ConvertFrom-Json`). Working tree clean
after the deliberate-failure demonstration was reverted.
