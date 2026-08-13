---
phase: 04-imaging
plan: 02
subsystem: imaging-decisions
tags: [disk-selection, disk-layout, partition-plan, os-catalog, image-index, json-schema, pester, tdd, powershell-5.1]

# Dependency graph
requires:
  - phase: 01-foundations
    provides: the module skeleton, New-HDTErrorRecord, the naming/5.1/MDT contract tests
  - phase: 02-rules
    provides: the four-file document shape (schema, validator, contract, fixtures), ConvertFrom-HDTYaml, Expand-HDTVariableToken, Test-HDTSchemaVersion
  - phase: 03-sequence-engine
    plan: 04
    provides: Get-HDTFailureClass and its "a Configuration failure is never retried" rule
  - phase: 04-imaging
    plan: 01
    provides: the IDiskService row shapes, the IImageService row shape, the disk and image fixtures
provides:
  - "Select-HDTTargetDisk: DESIGN 9.1's refusal to guess which disk to wipe, seven exclusion rules in two classes"
  - "Get-HDTDiskLayout: uefi-standard and bios-standard as data, with the workspace.yaml override hook M4 will use"
  - "New-HDTDiskLayoutPlan: the partition arithmetic in exact bytes, with the MSR subtracted and never planned"
  - "Resolve-HDTDiskLayoutName: pinned name, then HDTDiskLayout, then firmware"
  - "Resolve-HDTImageIndex: DESIGN 9.2's index selection by number, name or edition, and its refusal"
  - "os.yaml as the fourth HDT document type: schemas/os.schema.json, Assert-HDTOperatingSystemDocument, OsSchema.Contract.Tests.ps1, tests/fixtures/os/"
  - "Import-HDTOperatingSystem and Get-HDTOperatingSystem, the write and read halves of the OS catalog"
  - "Four new error ids, all classified Configuration"
affects: [04-03-apply-and-boot, 04-04-integration-and-e2e, 05-boot-image, 07-applications]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A refusal carries its OWN error id rather than reusing HDTConfigurationError, so a log reader can tell a wipe refusal from a malformed YAML file - and the classifier's list is named, never a wildcard"
    - "An error record whose target object is not a path, so a console recovers the disk number without parsing prose"
    - "Layout definitions as one ordered dictionary literal, each number commented with the DESIGN or SPIKES line it came from"
    - "A validation rule that rejects the role name 'Reserved' by name, so a bug a spike hit cannot be reintroduced through an override hook"
    - "Criteria matched independently and intersected, rather than filtered in sequence, so a pair of criteria can disambiguate what neither can alone"
    - "The writer held to its own validator before it writes, so the round trip cannot drift"

key-files:
  created:
    - src/Hephaestus/Public/Select-HDTTargetDisk.ps1
    - src/Hephaestus/Public/Get-HDTDiskLayout.ps1
    - src/Hephaestus/Public/New-HDTDiskLayoutPlan.ps1
    - src/Hephaestus/Public/Resolve-HDTImageIndex.ps1
    - src/Hephaestus/Public/Import-HDTOperatingSystem.ps1
    - src/Hephaestus/Public/Get-HDTOperatingSystem.ps1
    - src/Hephaestus/Private/Resolve-HDTDiskLayoutName.ps1
    - src/Hephaestus/Private/Assert-HDTOperatingSystemDocument.ps1
    - src/Hephaestus/Private/Copy-HDTContentTree.ps1
    - src/Hephaestus/Private/ConvertTo-HDTYaml.ps1
    - src/Hephaestus/Private/ConvertTo-HDTOperatingSystemCatalog.ps1
    - schemas/os.schema.json
    - tests/unit/Select-HDTTargetDisk.Tests.ps1
    - tests/unit/Get-HDTDiskLayout.Tests.ps1
    - tests/unit/New-HDTDiskLayoutPlan.Tests.ps1
    - tests/unit/Resolve-HDTDiskLayoutName.Tests.ps1
    - tests/unit/Resolve-HDTImageIndex.Tests.ps1
    - tests/unit/Assert-HDTOperatingSystemDocument.Tests.ps1
    - tests/unit/Copy-HDTContentTree.Tests.ps1
    - tests/unit/Import-HDTOperatingSystem.Tests.ps1
    - tests/unit/Get-HDTOperatingSystem.Tests.ps1
    - tests/contract/OsSchema.Contract.Tests.ps1
    - tests/fixtures/os/ (15 files)
  modified:
    - src/Hephaestus/Hephaestus.psd1
    - src/Hephaestus/Private/Get-HDTFailureClass.ps1
    - src/Hephaestus/Private/New-HDTErrorRecord.ps1
    - tests/unit/Get-HDTFailureClass.Tests.ps1
    - tests/unit/New-HDTErrorRecord.Tests.ps1
    - tests/fixtures/README.md
    - tests/helpers/README.md

key-decisions:
  - "Get-HDTFailureClass now compares the error id BEFORE the first comma against a named list, instead of a 'HDTConfigurationError*' wildcard. A wildcard over 'HDT*Error' would silently swallow every id a later phase invents, including ones that really are transient"
  - "New-HDTErrorRecord gained -TargetObject. DESIGN 9.1's refusals are about a disk NUMBER, and -Path was the only way to set a target object, which would have prefixed the message with '0: '"
  - "A supplied disk layout definition naming the role 'Reserved' is rejected by name. The override hook is the one route by which SPIKES S6's duplicate-MSR bug could return, and a message that says so is cheaper than rediscovering it on metal"
  - "New-HDTDiskLayoutPlan puts UseMaximumSize on the recovery row of uefi-standard, so the alignment slack lands in recovery rather than being left unallocated. Windows is therefore 15 MB smaller than the spike's hand-run produced"
  - "Resolve-HDTImageIndex matches each criterion independently and intersects them, rather than filtering in sequence. -Edition ServerStandard is ambiguous on the real Server 2025 media and -Edition ServerStandard -Index 2 is not; a sequential filter would have had to pick an order and would refuse a request that is perfectly clear"
  - "Copy-HDTContentTree tells a directory from a file with GetLength rather than a new IFileSystem method. Both implementations throw FileNotFoundException for a path that is not a file and the contract asserts that parity, so the classification behaves identically on either - and a nine-method interface 04-01 fixed did not have to widen"
  - "ConvertTo-HDTYaml exists as the one place the engine mentions ConvertTo-Yaml, mirroring ConvertFrom-HDTYaml. Writing os.yaml needs a serialiser and the plan did not name one"
  - "TWO schema blind spots are recorded, not the one the plan predicted. uniqueItems compares whole items, so draft-07 cannot express 'no two images share an index' unless the duplicated entries are identical"

patterns-established:
  - "The Select-HDTTargetDisk signature and its seven rules, which 04-03's DiskPartition step is written directly against"
  - "The New-HDTDiskLayoutPlan row shape, which DiskPartition executes row by row"
  - "The os.yaml field list and the catalog object shape, which ApplyImage reads"
  - "ImagePath as the named seam M4's content provider replaces"

# Metrics
duration: 175min
completed: 2026-08-13
---

# Phase 04 Plan 02: Disk Selection, Layouts and the OS Catalog Summary

**The decisions phase 04 makes before it touches anything — which disk (and when to refuse), which partitions and how big, which image index, and what an operating system in the workspace catalog is — all of it pure logic over 04-01's rows, all of it proven with no disk attached and no WIM mounted.**

## Performance

- **Duration:** ~175 min
- **Tasks:** 3 of 3
- **Files created:** 37 · **Files modified:** 7
- **Suite:** **3304 passed / 0 failed / 42 skipped** under pwsh 7.5.8 (`build.ps1 -Task ci`, exit 0); **3190 passed / 0 failed / 156 skipped** under Windows PowerShell 5.1.26100.8655 (`build.ps1 -Task test`, exit 0). Baseline before this plan was 2990 / 2904 — **+314 and +286**.
- PSScriptAnalyzer: 0 diagnostics across 230 files.

## Task Commits

1. **Task 1: the refusal** — `e4204bb` (test, 51 failing) → `85eccbb` (feat)
2. **Task 2: layouts and the plan** — `59556d7` (test, 82 failing) → `0fc2d44` (feat)
3. **Task 3: the OS catalog** — `2297a62` (test, 132 failing) → `f6d2abc` (feat)

Every RED commit was **watched failing for the right reason** before its GREEN, and every test that passed on its first run was strengthened rather than accepted (see *Tests that passed for the wrong reason*, below).

---

## What 04-03 is written against

### `Select-HDTTargetDisk` — the signature and the seven rules

```
Select-HDTTargetDisk -Disk <object[]> [-Partition <object[]>] [-Volume <object[]>]
                     [-DiskNumber <int>] [-MinimumSizeByte <long>]
                     [-ProtectDriveLetter <string[]>] [-AllowExistingData]
  -> the single disk row, or a terminating error
```

Every rule is evaluated for every disk and its reason recorded, so a refusal prints the whole table. `-MinimumSizeByte` defaults to **64424509440** (60 GB).

| # | Rule | Message fragment | Overridable by `-DiskNumber` |
|---|---|---|---|
| 1 | `IsSystem` or `IsBoot` | `disk N is the disk this machine booted from` | **never** |
| 2 | holds a letter in `-ProtectDriveLetter` | `holds drive letter Z, which this deployment is reading from or writing to` | **never** |
| 3 | `IsReadOnly` | `disk N is read-only` | **never** |
| 4 | `IsOffline` | `is offline, and HDT cannot bring a disk online` | **never** |
| 5 | not `RAW` **and** carries a volume with a file system, without `-AllowExistingData` | `carries existing data on volume D (NTFS)` | **never** — the sequence declares it instead |
| 6 | `BusType -eq 'USB'` | `disk N is a USB disk` | yes, with a warning |
| 7 | `SizeBytes -lt MinimumSizeByte` | `is N bytes, under the minimum of M bytes` | yes, with a warning |

Drive letters are normalised to one uppercase character, so `z`, `Z` and `Z:` are one letter. Rules 6 and 7 warn with `…, and was used anyway because the sequence named it.`

Outcomes:

| Situation | Error id | TargetObject |
|---|---|---|
| `-DiskNumber` names no disk | `HDTConfigurationError` | the number |
| `-DiskNumber` excluded by 1–5 | `HDTUnsafeTargetError` | the number |
| no disks at all | `HDTNoTargetDiskError` | `[int[]] @()` |
| no survivors | `HDTNoTargetDiskError` (one indented line per disk) | every disk number |
| two or more survivors | `HDTAmbiguousTargetError` | the candidate numbers |

### The four new error ids, and their classification

`HDTAmbiguousTargetError`, `HDTUnsafeTargetError`, `HDTNoTargetDiskError` and `HDTAmbiguousImageError` are all **`Configuration`**, so a refusal ends the run instead of being retried three times.

**`Get-HDTFailureClass` changed shape to do it.** It previously matched `FullyQualifiedErrorId -like 'HDTConfigurationError*'`; it now splits the id at the first comma and compares against a **named list of five**. A wildcard over `HDT*Error` would have swallowed every id a later phase invents. `tests/unit/Get-HDTFailureClass.Tests.ps1` asserts that an unknown `HDTSomethingElseError` is still `Transient`.

### `New-HDTDiskLayoutPlan` — the row shape

```
Order, Role, SizeByte, UseMaximumSize, FileSystem, Label, DriveLetter,
GptType, CreateGptType, IsActive
```

`Role` is one of `System`, `Windows`, `Recovery`. **Never `Reserved`** — `Initialize-Disk` creates the MSR.

### The two layouts as finally implemented

`Get-HDTDiskLayout` returns `Name`, `PartitionStyle`, `ReservedSizeByte`, `AlignmentSizeByte`, `Partition`.

**`uefi-standard`** — GPT, `ReservedSizeByte 16777216`, `AlignmentSizeByte 1048576`:

| Order | Role | SizeByte | UseMax | FS | Label | Letter | GptType | CreateGptType |
|---|---|---|---|---|---|---|---|---|
| 1 | System | 272629760 | no | FAT32 | `System` | S | `{c12a7328-…}` | `{ebd0a0a2-…}` |
| 2 | Windows | computed | no | NTFS | `Windows` | W | — | — |
| 3 | Recovery | 1073741824 | **yes** | NTFS | `Windows RE tools` | R | `{de94bba4-…}` | — |

**`bios-standard`** — MBR, `ReservedSizeByte 0`:

| Order | Role | SizeByte | UseMax | FS | Label | Letter | IsActive |
|---|---|---|---|---|---|---|---|
| 1 | System | 524288000 | no | NTFS | `System Reserved` | S | **yes** |
| 2 | Windows | computed | **yes** | NTFS | `Windows` | W | no |

The arithmetic, asserted to the byte:

```
uefi:  windows = disk - 272629760 - 16777216 - 1073741824 - 1048576
bios:  windows = disk - 524288000 - 1048576          (no MSR allowance on MBR)
```

On the lab's 64 GiB disk that is ESP 260 MB, Windows **64235 MB**, recovery `UseMaximumSize`. SPIKES S6's hand-run produced 64250 MB; the 15 MB difference is the alignment slack, which now lands in **recovery** because that row carries `UseMaximumSize`. A disk where Windows would fall under `-MinimumWindowsSizeByte` (default 21474836480) is a refusal naming the disk size, the overhead, the resulting size and the shortfall.

### ⚠ The ESP two-step is UNVERIFIED BY CODE

`CreateGptType` is basic data `{ebd0a0a2-…}` and `GptType` is the ESP `{c12a7328-…}`: the partition is created as basic data, lettered, formatted, and **retyped afterwards**, because a partition created directly as an ESP cannot readily be given a drive letter to format through. **This is the field recipe, and nothing in this repository has ever executed it.** 04-04's integration task is where it first runs. If `Set-Partition -GptType` after `Format-Volume` does not behave, the finding goes into `SPIKES.md` and the layout changes — not the test.

### Layout-name precedence

```
Resolve-HDTDiskLayoutName -Variable <IDictionary> [-Layout <string>] [-Definition <IDictionary>]
```

1. the step's `layout:` property — `%Var%`-expanded first, and a token that resolved to nothing falls through instead of failing
2. the `HDTDiskLayout` variable
3. firmware: `HDTIsUEFI` true → `uefi-standard`

`HDTIsUEFI` is read as a boolean or as the text `True`. **Absent, it resolves to `bios-standard` WITH A WARNING** — an MBR disk on UEFI hardware fails in the first minute, a GPT disk on a BIOS machine fails after the image has been applied. The returned name is the layout's own casing, so callers may compare it exactly. An unknown name is a terminating error listing the names that exist.

### `Resolve-HDTImageIndex` precedence

```
Resolve-HDTImageIndex -Image <object[]> [-Index <int>] [-Name <string>]
                      [-Edition <string>] [-DefaultIndex <int>]
```

**Each criterion is matched independently and the results are intersected.** That is what makes `-Edition ServerStandard -Index 2` resolve where the edition alone is ambiguous on the real Server 2025 media.

- `-Index` — must exist, else `HDTConfigurationError` listing the indices.
- `-Name` — **exact (case-insensitive) first**; if none, a wildcard. A `-Name` containing `*` or `?` is used as written; one without is wrapped as `*name*`.
- `-Edition` — case-insensitive, exact.
- Intersection of 1 → that image. 0 → `HDTConfigurationError` naming every request. 2+ → `HDTAmbiguousImageError` listing the candidates.
- Nothing asked for: a single-image file → that image; else `-DefaultIndex`; else `HDTAmbiguousImageError` listing every index and name.

Exact-before-wildcard is load-bearing on real media: `Windows Server 2025 Standard` is index 1 **exactly** and is contained in index 2's name.

### `os.yaml` — the field list

```yaml
schemaVersion: 1            # required, integer, = 1
id: Win11-LTSC-2024         # required, ^[A-Za-z0-9][A-Za-z0-9_.-]*$ (it is a folder name)
name: Windows 11 …          # required
description: …              # optional
type: wim                   # required, wim | ffu
architecture: x64           # optional, x86 | x64 | arm64
sourcePath: sources\install.wim   # required; relative to the OS folder unless rooted
importedUtc: '2026-08-13T…' # optional
defaultIndex: 1             # optional, must name an index that exists
images:                     # required, non-empty
  - index: 1                # required, integer >= 1, unique
    name: …                 # required
    description: …          # optional
    edition: EnterpriseS    # optional
    sizeBytes: 18356832906  # optional
    version: 10.0.26100.1742 # optional
```

Unknown keys are rejected at both levels.

`Get-HDTOperatingSystem` and `Import-HDTOperatingSystem` both return the same object, built by one private projection:

```
SchemaVersion, Id, Name, Description, Type, Architecture, SourcePath,
ImportedUtc, DefaultIndex, Path, OsFolder, ImagePath, Images[]
```

### The schema's TWO blind spots

The plan predicted one. There are two, both listed in `$script:HDTSchemaBlindSpot` with a fixture each:

| Fixture | Why draft-07 cannot express it |
|---|---|
| `invalid-default-index-absent.yaml` | no cross-field reference from `defaultIndex` into the `images` array |
| `invalid-duplicate-index-distinct.yaml` | `uniqueItems` compares **whole items**, so it cannot say "no two images share an index" when the entries differ elsewhere |

`invalid-duplicate-index.yaml` sits alongside the second to show where the schema *does* reach: its two entries are identical, so `uniqueItems` catches it, and the two validators agree.

### ⚠ The content provider seam, named so M4 does not rediscover it

`ImagePath` on the catalog object **is the seam**. DESIGN 6 abstracts content access behind `Resolve-Content` / `Copy-Content` / `Test-Content` and M4 ships the `Smb` and `Local` providers. Until then `ConvertTo-HDTOperatingSystemCatalog` resolves a relative `sourcePath` against the OS folder — exactly what a provider would return for `Local` — and keeps a rooted one as it is, because media too large to bring into the share is registered where it stands. **When M4 lands, `ApplyImage` changes from "ask the catalog" to "ask the provider" and no step logic moves.**

### `diskLayouts:` in `workspace.yaml` — stated, not quietly diverged from

DESIGN 9.1 says named layouts live in `workspace.yaml`. **That document does not exist yet** — M4 introduces it for the boot image — so the built-ins live in `Get-HDTDiskLayout` and `-Definition` is the hook the `diskLayouts:` block will arrive through. A supplied definition overrides a built-in of the same name and extends the set otherwise, and `Resolve-HDTDiskLayoutName` passes it straight through, so nothing has to be rewritten when M4 lands.

---

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 3 — Blocking] `New-HDTErrorRecord` could not carry a target object that is not a path**

- **Found during:** Task 1, writing the `carries the disk number as the TargetObject` test.
- **Issue:** `TargetObject` was set from `-Path`, and `-Path` also prefixes the message. A refusal about disk 0 would have had to be raised with `-Path '0'`, producing `0: disk 0 is the disk this machine booted from`.
- **Fix:** added `-TargetObject`, which wins over `-Path` when supplied and leaves the message alone. Two tests added to `New-HDTErrorRecord.Tests.ps1`, watched failing with `A parameter cannot be found that matches parameter name 'TargetObject'`.
- **Commit:** `85eccbb`

**2. [Rule 3 — Blocking] Nothing in the engine could write YAML**

- **Found during:** Task 3. `Import-HDTOperatingSystem` writes `os.yaml`; the plan named no serialiser.
- **Fix:** `ConvertTo-HDTYaml`, the mirror of `ConvertFrom-HDTYaml` down to the lazy import and the `HDTDependencyError` for a missing `powershell-yaml`. It is the only place in the engine that mentions `ConvertTo-Yaml`, as `ConvertFrom-HDTYaml` is the only place that mentions the other half.
- **Commit:** `f6d2abc`

**3. [Rule 1 — Bug] A test title containing `<id>` failed the whole suite**

- **Found during:** Task 3, the first full-suite run after GREEN — the filtered run of the same file was green.
- **Issue:** `It 'writes os.yaml under OperatingSystems\<id>'`. Pester expands `<name>` in a test title as a data variable, so the title itself raised `the variable $id cannot be retrieved because it has not been set`. One test failed in the suite and none in isolation.
- **Fix:** renamed the test and wrote the reason above it. **This is why a filtered green run is not a green run.**
- **Commit:** `f6d2abc`

**4. [Rule 2 — Missing critical functionality] The layout override hook rejects the role `Reserved` by name**

- **Found during:** Task 2.
- **Issue:** `-Definition` is the one route by which SPIKES S6's duplicate-MSR bug could come back — a workspace author declaring the MSR the way `PSDPartition.ps1` creates it.
- **Fix:** `Reserved` is not in the allowed role set, and the message says why: *"the Microsoft Reserved partition is created by initialisation and must not be declared (SPIKES S6)"*.
- **Commit:** `0fc2d44`

### Departures from the plan's letter

**A. A second schema blind spot, and a fixture for it.** The plan lists `invalid-duplicate-index.yaml` as an ordinary invalid fixture and predicts one blind spot. `uniqueItems` only catches a duplicate index when the entries are otherwise identical, so `invalid-duplicate-index-distinct.yaml` was added and listed as blind spot two. Claiming the schema catches duplicate indices in general would have been false.

**B. `Copy-HDTContentTree` uses a fourth `IFileSystem` method.** The plan describes "`GetChildItem` walk + `CreateDirectory` + `CopyItem`". With only those three, an empty directory and a file are indistinguishable. `GetLength` classifies them, and both implementations throw `FileNotFoundException` for a path that is not a file — parity the `IFileSystem` contract already asserts. The alternative was widening a nine-method interface 04-01 fixed; the reasoning is now recorded in `tests/helpers/README.md`.

**C. A private `ConvertTo-HDTOperatingSystemCatalog`.** Not in the plan's file list. It exists so `Import-HDTOperatingSystem` and `Get-HDTOperatingSystem` return the same shape *by construction* rather than by two authors agreeing, which is what makes the plan's `writes a document Get-HDTOperatingSystem reads back` test meaningful.

**D. Four fixtures beyond the plan's twelve** — `invalid-missing-name.yaml`, `invalid-bad-architecture.yaml`, `invalid-duplicate-index-distinct.yaml`, and the ordinary-vs-blind-spot pair described in A. Each isolates exactly one authoring mistake, as `rules/` does.

**E. `Import-HDTOperatingSystem` validates the document it built before writing it.** Not asked for. It makes "the writer and the validator cannot drift" true at run time as well as in a test.

**F. Extra tests beyond the plan's lists** — notably `refuses an explicit diskNumber naming a read-only disk`, `ignores a partition on another disk when judging existing data`, `allows a destination that merely shares a name prefix` (the `Win11-copy` / `Win11` case a bare `StartsWith` gets wrong), `accepts the string False for HDTIsUEFI`, and `plans an awkward non-power-of-two disk exactly`.

### Tests that passed for the wrong reason, and were strengthened

Three tests were green on their first RED run and were fixed before the RED commit, per `tests/helpers/README.md` section 12:

| Test | Why it passed | Fix |
|---|---|---|
| `never selects this machine, whose real row is the fixture` | bare `Should -Throw` is satisfied by `CommandNotFoundException` | assert `HDTNoTargetDiskError*` and the message |
| `takes no disk service parameter` | `Get-Command` writes a non-terminating error, and `$null.Parameters.Keys` satisfies `-Not -Contain` | `-ErrorAction Stop` plus assert `$command.Name` first |
| `never plans a partition with a negative size` | the loop swallows the exception, so a version that threw for every size would pass | assert the planned row count is 9 |

Two more (`rejects a missing name`, `rejects an image without a name`) passed because `CommandNotFoundException`'s own message contains the word *name*; both now assert the error id as well.

### Authentication gates

None.

---

## Verification

| Plan check | Result |
|---|---|
| 1. `pwsh -File ./build.ps1 -Task ci` | exit 0 — lint 0 diagnostics / 230 files, **3304 passed, 0 failed, 42 skipped**, selfcheck 4 of 4 |
| 2. `powershell.exe -File ./build.ps1 -Task test` | exit 0 — **3190 passed, 0 failed, 156 skipped** |
| 3. `test(04-02)` before every `feat(04-02)` | yes, three pairs, verified in `git log` |
| 4. `Select-HDTTargetDisk -Disk ((New-HDTDiskService).GetDisk())` on this machine | `HDTNoTargetDiskError,Select-HDTTargetDisk` — *"no disk on this machine can be used as the deployment target: - disk 0 is the disk this machine booted from"* |
| 5. No Storage or DISM cmdlet named in the three files | 0 matches |
| 6. `New-HDTDiskLayoutPlan` never returns a `Reserved` row | 0 for both layouts |
| 7. Schema and validator agree on every fixture, blind spots listed | yes — 2 blind spots, both justified in `tests/fixtures/README.md` |

**The live task-3 verification, against the real staged media:**

```
schemaVersion: 1
id: Win11-LTSC-2024
type: wim
architecture: x64
sourcePath: C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim
defaultIndex: 1
images:
- index: 1   name: Windows 11 Enterprise LTSC     edition: EnterpriseS    version: 10.0.26100.1742
- index: 2   name: Windows 11 Enterprise N LTSC   edition: EnterpriseSN   version: 10.0.26100.1742

Resolve-HDTImageIndex -Edition EnterpriseS  ->  Index 1

HDTAmbiguousImageError,Resolve-HDTImageIndex
2 images match edition 'ServerStandard', and HDT will not guess which to apply:
1 = Windows Server 2025 Standard; 2 = Windows Server 2025 Standard (Desktop Experience).
```

## Lab safety

**No Hyper-V call of any kind was made except one read-only `Hyper-V\Get-VM` at the end.** `CM01` and `DC01` are `Off` and untouched. **This host's disk 0 was `GPT`, `IsBoot True`, `IsSystem True` with four partitions before this plan and is identical after it** — nothing in this plan can write to a disk: the only new commands that touch anything write text files, and they do it through an injected filesystem. The scratch workspace `C:\HDTLab\Share` gained two `os.yaml` files, which is what it is for.

## Notes for 04-03

- `Select-HDTTargetDisk` returns the **disk row**, not a number. `DiskPartition` passes `-ProtectDriveLetter` for the workspace root and the log path, or rule 2 protects nothing.
- Execute a plan row by row: `CreateGptType` at creation, then letter, then format, then `SetPartitionType` to `GptType`. **The first partition an author creates on a GPT disk is number 2** — `InitializeDisk` made the MSR.
- A `UseMaximumSize` row ignores its `SizeByte`. Only the recovery row of `uefi-standard` and the Windows row of `bios-standard` carry it.
- `Resolve-HDTDiskLayoutName` is private; `DiskPartition` calls it from inside the module.
- `Get-HDTOperatingSystem(...).ImagePath` is what `ApplyImage` feeds to `IImageService.ApplyImage`, and `Resolve-HDTImageIndex` decides the index. Do not add a second path resolver.
- 04-03 still owes `docs/DESIGN.md` 9.2 the correction 04-01 identified: the recovery-image verb it names does not exist on Windows 11 24H2, and WinPE ships no `reagentc.exe`.

## Self-Check: PASSED

All 23 created source, schema and test files plus the 15 `tests/fixtures/os/` files exist on disk. All six commits (`e4204bb`, `85eccbb`, `59556d7`, `0fc2d44`, `2297a62`, `f6d2abc`) exist in `git log`.
