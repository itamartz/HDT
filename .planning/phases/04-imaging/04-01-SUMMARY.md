---
phase: 04-imaging
plan: 01
subsystem: services
tags: [disk, imaging, dism, storage, bcdboot, bcdedit, reagentc, dependency-injection, fixtures, pester, tdd, powershell-5.1]

# Dependency graph
requires:
  - phase: 01-foundations
    provides: the module skeleton, the pscustomobject adapter shape, the naming/5.1/MDT contract tests
  - phase: 02-rules
    provides: the fixture capture-and-sanitise convention, the -FixturePath seeding pattern from New-HDTFakeCimProvider
  - phase: 03-sequence-engine
    plan: 01
    provides: the shared cross-service journal, the Record/GetOperationName shape every fake and adapter follows
  - phase: 03-sequence-engine
    plan: 02
    provides: New-HDTServiceCatalog and its GetRequired(service, caller) sentence
provides:
  - "IDiskService: nine methods, a real adapter over the Storage module and a hand-written fake"
  - "IImageService: five methods, a real adapter over Get-WindowsImage, Expand-WindowsImage, bcdboot, bcdedit and reagentc, and a hand-written fake"
  - "tests/contract/DiskService.Contract.Tests.ps1 and ImageService.Contract.Tests.ps1, one contract per service, both implementations in one file"
  - "The fake disk service's modelling of the implicit MSR, so SPIKES S6's duplicate-MSR bug cannot return unnoticed"
  - "tests/fixtures/disk/ and tests/fixtures/image/, captured off this machine and off both staged WIMs"
  - "New-HDTServiceCatalog gains Disk and Image - eleven properties"
affects: [04-02-disk-selection-and-layout, 04-03-apply-and-boot, 04-04-integration-and-e2e, 05-boot-image, 06-drivers]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A fake models the behaviour that bit a spike, rather than documenting it: InitializeDisk with GPT creates its own MSR, so a duplicate is visible to a test"
    - "A fake refuses an ambiguous target (two seeded disks numbered 0) rather than picking one - DESIGN 9.1 enforced in the double"
    - "Existence guards in an adapter, so both implementations of a contract throw the same type for the same mistake, and a destructive cmdlet is never reached for a target that does not exist"
    - "A contract's real row can be opt-in twice over: elevated AND an explicit environment variable, with a printed warning naming both when it is not"
    - "A fixture directory as a CATALOGUE of rows rather than a snapshot of one machine, with the base name's suffix choosing which listing a file seeds"

key-files:
  created:
    - src/Hephaestus/Public/New-HDTDiskService.ps1
    - src/Hephaestus/Public/New-HDTImageService.ps1
    - tests/contract/DiskService.Contract.Tests.ps1
    - tests/contract/ImageService.Contract.Tests.ps1
    - tests/unit/New-HDTFakeDiskService.Tests.ps1
    - tests/unit/New-HDTFakeImageService.Tests.ps1
    - tests/fixtures/disk/host-nvme-disk.json
    - tests/fixtures/disk/host-vhdx-disk.json
    - tests/fixtures/disk/gen2-vm-raw-disk.json
    - tests/fixtures/disk/host-partition.json
    - tests/fixtures/disk/host-volume.json
    - tests/fixtures/image/win11-ltsc-2024-install.json
    - tests/fixtures/image/ws2025-std-install.json
  modified:
    - src/Hephaestus/Hephaestus.psd1
    - src/Hephaestus/Public/New-HDTServiceCatalog.ps1
    - tests/helpers/HDTFakes/HDTFakes.psm1
    - tests/helpers/HDTFakes/HDTFakes.psd1
    - tests/helpers/README.md
    - tests/fixtures/README.md
    - tests/unit/FakeJournal.Tests.ps1
    - tests/unit/New-HDTServiceCatalog.Tests.ps1

key-decisions:
  - "The fake disk service REFUSES an ambiguous disk number rather than picking the first match. tests/fixtures/disk/ is a catalogue, so the host disk and the derived Gen2 VM disk are both number 0; a fake that silently picked one would lie about which disk a step wiped, and DESIGN 9.1's refusal to guess belongs in the double as well as in the step"
  - "The real adapter's guards filter client-side rather than passing -Number. Get-Disk -Number -1 throws System.OverflowException before it queries anything, because Number is a uint32 - so the contract's 'disk that does not exist' assertion could not be satisfied by the cmdlet's own error"
  - "The existence guards are what make ClearDisk(-1) safe to run for real: the guard throws before Clear-Disk is ever invoked, so the opt-in contract row proves 'records before it can throw' without a destructive cmdlet being reached"
  - "The fake image service's -FixturePath seeds by BASE NAME, and the contract's fake row seeds the real WIM path explicitly from the fixture file. That makes 'the fake is seeded from the fixture, the real row reads the WIM, both must agree' visible in the contract file rather than hidden in a factory"
  - "GetVolume filters to volumes with a drive letter, which is the interface's own definition of the listing rather than a decision the adapter took. Get-Volume reports an absent letter as [char] 0, which is neither empty nor whitespace"
  - "reagentc's verb: SetRecoveryImage uses /setreimage against the APPLIED IMAGE'S OWN Reagentc.exe by full path. DESIGN 9.2 names a verb that does not exist on Windows 11 24H2, and WinPE has no reagentc at all"

patterns-established:
  - "The nine IDiskService and five IImageService signatures 04-02 and 04-03 are written directly against"
  - "The disk, partition, volume and image row shapes, fixed by contract and asserted on both implementations"
  - "F12: assign ConvertFrom-Json to a variable before wrapping it in @(), or 5.1 loses every row after the first"

# Metrics
duration: 155min
completed: 2026-08-13
---

# Phase 04 Plan 01: The Disk and Image Services Summary

**`IDiskService` over the Storage module and `IImageService` over DISM, `bcdboot`, `bcdedit` and `reagentc` — each a real adapter, a hand-written fake and one contract both satisfy — so phase 04's destructive steps can be written as pure logic and proven with no disk attached.**

## Performance

- **Duration:** ~155 min
- **Tasks:** 2 of 2
- **Files created:** 13 · **Files modified:** 8
- **Suite:** **2990 passed / 0 failed / 42 skipped** under pwsh 7.5.8 (`build.ps1 -Task ci`, exit 0); **2904 passed / 0 failed / 128 skipped** under Windows PowerShell 5.1.26100.8655 (`build.ps1 -Task test`, exit 0). Baseline before this plan was 2856 / 2795.
- With the opt-in real disk row enabled (elevated, `HDT_ALLOW_DISK_TEST=1`): `DiskService.Contract.Tests.ps1` reports **36 passed / 0 failed**, both rows.
- PSScriptAnalyzer: 0 diagnostics across 209 files.

## Task Commits

1. **Task 1: IDiskService** — `9b04bb9` (test) → `c563480` (feat, the fake) → `a50e090` (test, the contract) → `1ccb9e8` (feat, the real adapter)
2. **Task 2: IImageService and the catalog** — `362331e` (test) → `693d682` (feat, the fake and the catalog) → `101de79` (test, the contract) → `c475a8c` (feat, the real adapter) → `a717e4a` (docs)

---

## What 04-02 and 04-03 are written against

### IDiskService — nine methods

```
GetDisk()      -> object[]   every disk on the machine
GetPartition() -> object[]   every partition on every disk
GetVolume()    -> object[]   every volume with a drive letter

ClearDisk(int diskNumber)                                        -> void
InitializeDisk(int diskNumber, string partitionStyle)            -> void
NewPartition(int diskNumber, long sizeByte, bool useMaximumSize,
             string gptType, bool isActive)                      -> the created row
SetPartitionDriveLetter(int diskNumber, int partitionNumber, string driveLetter) -> void
SetPartitionType(int diskNumber, int partitionNumber, string gptType)            -> void
FormatVolume(string driveLetter, string fileSystem, string label)                -> void
```

Three flat listings, no filters and no joins. A partition row carries its
`DiskNumber` and a volume row carries its `DriveLetter`, so **04-02 does the
joining** and the adapter stays a projection of three cmdlets.

`UseMaximumSize = $true` means `sizeByte` is ignored. An empty `gptType` means
"do not pass `-GptType`". An empty `driveLetter` means "remove the access path".

### The row shapes, fixed here

| `GetDisk()` | Type |
|---|---|
| `Number` | `[int]` |
| `FriendlyName` | `[string]` |
| `SerialNumber` | `[string]` |
| `SizeBytes` | `[long]` |
| `BusType` | `[string]` — `NVMe`, `SAS`, `USB`, `File Backed Virtual`, … |
| `PartitionStyle` | `[string]` — `RAW`, `MBR`, `GPT` |
| `IsBoot` / `IsSystem` / `IsReadOnly` / `IsOffline` | `[bool]` |
| `OperationalStatus` | `[string]` |

| `GetPartition()` | Type |
|---|---|
| `DiskNumber` / `PartitionNumber` | `[int]` |
| `DriveLetter` | `[string]`, empty when none |
| `SizeBytes` / `OffsetBytes` | `[long]` |
| `Type` | `[string]` — `Basic`, `System`, `Reserved`, `Recovery` |
| `GptType` | `[string]`, empty on MBR |
| `IsActive` / `IsHidden` / `IsBoot` / `IsSystem` | `[bool]` |

| `GetVolume()` | Type |
|---|---|
| `DriveLetter` | `[string]` |
| `FileSystem` / `FileSystemLabel` | `[string]` |
| `SizeBytes` / `SizeRemainingBytes` | `[long]` |

### IImageService — five methods

```
GetImageInfo(string imagePath) -> object[]  Index, Name, Description, Edition,
                                            SizeBytes, Architecture, Version
ApplyImage(string imagePath, int index, string applyPath)               -> void
InstallBootFile(string osRoot, string systemVolume, string firmware)    -> void
SetRecoveryImage(string osRoot, string recoveryPath)                    -> void
SetBootOrderFirst()                                                     -> void
```

`Index` is `[int]`, `SizeBytes` is `[long]`, everything else is `[string]`.
**`Architecture` is a numeric DISM code, not a string** — both staged media
report `9`, which is amd64. It is recorded as it arrives; a fixture that
prettified it would be a fixture that lied about the tool.

### The fake's MSR modelling, and the partition numbering it implies

`InitializeDisk(n, 'GPT')` on the fake **adds a `Reserved` partition** —
`PartitionNumber 1`, `OffsetBytes 1048576`, `SizeBytes 16777216`,
`GptType {e3c9e316-0b5c-4db8-817d-f92df00215ae}`, `IsHidden $true` — because
`Initialize-Disk -PartitionStyle GPT` does (SPIKES S6). `InitializeDisk(n, 'MBR')`
adds nothing.

**Consequence 04-02 must expect: the first partition an author creates on a GPT
disk is number 2, not 1.** A test that assumed 1 would pass against a naive fake
and fail on metal. HDT must never create an MSR itself; `PSDPartition.ps1`
initialises GPT on line 97 and creates one by hand on line 116, which is exactly
the duplicate the spike recorded.

The fake also **refuses `NewPartition` on a disk that is still `RAW`**, as
`New-Partition` does, so a step that forgot `InitializeDisk` cannot pass here
and fail on metal.

### The seed-key normalisation both fakes use

`New-HDTFakeImageService` normalises an image path exactly as
`New-HDTFakeScriptInvoker` normalises a script path: backslashes folded to
forward slashes, matched case-insensitively. One key serves both hashtables, and
a test is not a test of which separator the author happened to type.

`New-HDTFakeDiskService -FixturePath` accepts **a directory or a single file**,
and the base name's suffix chooses the listing: `*-disk.json`,
`*-partition.json`, `*-volume.json`.

### The catalog's two new properties

```
New-HDTServiceCatalog -FileSystem -Clock [-Registry] [-Lsa] [-Process] [-Power]
                      [-ScriptInvoker] [-Cim] [-Environment] [-Disk] [-Image]
```

Eleven properties, every one defined even when `$null`. `GetRequired('Disk',
'DiskPartition')` returns the service or throws naming both. `FileSystem` and
`Clock` are still the only mandatory two — a NoOp sequence runs on two services.

---

## Which fixtures are captured and which one is derived

| Fixture | Kind | Source |
|---|---|---|
| `disk/host-nvme-disk.json` | captured | `Get-Disk` on this host. `IsBoot` and `IsSystem` both **true** — the row 04-02's selection rule must refuse unconditionally |
| `disk/host-partition.json` | captured | `Get-Partition` — ESP 260 MB, MSR 16 MB, Windows, Recovery 2 GB |
| `disk/host-volume.json` | captured | `Get-Volume`, lettered volumes only |
| `disk/host-vhdx-disk.json` | captured | `C:\HDTLab\scratch\imgtest-a.vhdx` mounted **read-only**, dismounted in a `finally`. `BusType` is `File Backed Virtual`, and `IsReadOnly` is `true` **because** the capture used `-Access ReadOnly` |
| `disk/gen2-vm-raw-disk.json` | **DERIVED** | Shape is this host's real `Get-Disk` projection; values are SPIKES S6's observation from inside a Gen2 VM — `Number 0`, `BusType SAS`, `PartitionStyle RAW`, 64 GB, every flag false |
| `image/win11-ltsc-2024-install.json` | captured | `Get-WindowsImage` against the staged Windows 11 WIM |
| `image/ws2025-std-install.json` | captured | `Get-WindowsImage` against the staged Server 2025 WIM |

**`gen2-vm-raw-disk.json` is a debt with a named closing date.** There is no HDT
test VM yet. **04-04 replaces it with a true capture from the E2E VM and asserts
the derived row matched**, and deletes the note in `tests/fixtures/README.md`.

`SerialNumber` is sanitised to `FIXTURE-SERIAL-0001` in every disk row. Nothing
in the image fixtures is sanitised: a WIM's index catalogue carries no machine
identity.

### The capture confirms PROJECT.md rather than contradicting it

Both claims the plan asked to be checked held:

- Windows 11 WIM **index 1 = `Windows 11 Enterprise LTSC`, `EnterpriseS`**;
  index 2 is Enterprise N LTSC.
- Server 2025 WIM **index 2 = `Windows Server 2025 Standard (Desktop
  Experience)`**; 1 is Standard, 3 and 4 are Datacenter core and Desktop.

No correction to PROJECT.md is needed. Both are now fixtures the contract
asserts on, so they cannot drift silently.

---

## Native tools that have STILL NEVER BEEN EXECUTED by this repository

Stated plainly, because nothing in this plan proves them:

| Tool | Wrapped by | First executed in |
|---|---|---|
| `Expand-WindowsImage` | `ApplyImage` | 04-04 |
| `bcdboot.exe` | `InstallBootFile` | 04-04 |
| `Reagentc.exe /setreimage` | `SetRecoveryImage` | 04-04 |
| `bcdedit.exe /set {fwbootmgr} …` | `SetBootOrderFirst` | 04-04 |
| `Clear-Disk`, `Initialize-Disk`, `New-Partition`, `Set-Partition`, `Format-Volume`, `Remove-PartitionAccessPath` | the six changing `IDiskService` methods | 04-04, against a mounted scratch VHDX |

What **has** run for real: `Get-Disk`, `Get-Partition`, `Get-Volume` (the opt-in
contract row, elevated, read-only) and `Get-WindowsImage` against both staged
WIMs. `New-HDTImageService.GetImageInfo` on the staged Windows 11 media matches
`tests/fixtures/image/win11-ltsc-2024-install.json` row for row.

**This machine's disk 0 was `GPT`, `IsBoot True`, `IsSystem True` with four
partitions before this plan and is byte-for-byte the same after it.** Verified
after every run of the real contract row.

---

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 1 — Bug] `Get-Disk -Number -1` throws `OverflowException`, not a
not-found error**

- **Found during:** Task 1, first green run of the contract's real row.
- **Issue:** `Get-Disk`'s `-Number` is a `[uint32]`, so `-1` overflows during
  parameter binding, before anything is queried. The contract requires
  `ArgumentOutOfRangeException` from both implementations for the same mistake,
  and the plan's design deliberately uses `-1` because it cannot name a real
  disk.
- **Fix:** both existence guards filter client-side —
  `Get-Disk | Where-Object { $_.Number -eq $DiskNumber }` — and throw
  `ArgumentOutOfRangeException` themselves. This also makes the assertion
  *safer* than the plan assumed: `Clear-Disk` is never reached at all.
- **Files:** `src/Hephaestus/Public/New-HDTDiskService.ps1`
- **Commit:** `1ccb9e8`

**2. [Rule 1 — Bug] `ConvertFrom-Json` silently lost three of four captured
partitions under Windows PowerShell 5.1**

- **Found during:** Task 1, the 5.1 leg — the pwsh 7 leg was green.
- **Issue:** under 5.1, `ConvertFrom-Json` writes a top-level JSON array to the
  pipeline **without enumerating it**, so `@(ConvertFrom-Json $text)` is one
  element — the whole array. Every fixture row after the first vanished, and the
  fake reported one nonsense partition where the machine has four. Six tests
  failed under 5.1 and none under 7.
- **Fix:** assign to a variable first, wrap second. Applied in the fake's
  fixture loaders and in the two test files that read a fixture directly.
  Recorded as **F12** in `tests/helpers/README.md` so it is a permanent rule
  rather than a rediscovery. `New-HDTFakeCimProvider` was already written the
  correct way, which is why it had not bitten before.
- **Files:** `tests/helpers/HDTFakes/HDTFakes.psm1`,
  `tests/unit/New-HDTFakeDiskService.Tests.ps1`, `tests/helpers/README.md`
- **Commit:** `1ccb9e8`

**3. [Rule 2 — Missing critical functionality] The fake refuses an ambiguous
disk number**

- **Found during:** Task 1, writing the fixtures.
- **Issue:** the plan puts `host-nvme-disk.json` and `gen2-vm-raw-disk.json` in
  the same directory and has the contract seed the whole directory. Both carry
  disk `0`. A fake that picked the first match would report success for a
  `ClearDisk(0)` that named an ambiguous target — the precise failure mode
  DESIGN 9.1 exists to prevent, hidden inside the double meant to prove the rule.
- **Fix:** `FindDisk` throws `InvalidOperationException` naming the ambiguity
  when two seeded rows carry the number, with a unit test asserting it. The
  fixtures README states plainly that `disk/` is a catalogue of rows, not a
  snapshot of one machine.
- **Files:** `tests/helpers/HDTFakes/HDTFakes.psm1`,
  `tests/unit/New-HDTFakeDiskService.Tests.ps1`, `tests/fixtures/README.md`
- **Commit:** `c563480`

**4. [Rule 2 — Missing critical functionality] The fake refuses `NewPartition`
on a RAW disk**

- **Found during:** Task 1.
- **Issue:** not in the plan's test list, but it is the same class of defect as
  the MSR: a step that forgot `InitializeDisk` would pass against a permissive
  fake and fail on metal.
- **Fix:** `NewPartition` throws for a `RAW` disk, as `New-Partition` does.
- **Commit:** `c563480`

### Departures from the plan's letter

**A. `New-HDTFakeDiskService -FixturePath` also accepts a single file.** The
plan describes a directory. A directory alone cannot express "seed only this
host's disk", which is what the "leaves the host disk untouched" test needs, so
the parameter accepts either. One branch, documented.

**B. The image fake's `-FixturePath` seeds by base name, and the contract's fake
row seeds the WIM path explicitly.** The plan's signature has `-FixturePath` but
does not say what key a fixture file seeds; an image is keyed by *path* and a
file base name is not one. Seeding the real WIM path in the contract's factory
makes "the fake is seeded from the fixture, the real row reads the WIM, both
must agree" visible in the contract file itself.

**C. The `setosimage` token does not appear anywhere in
`New-HDTImageService.ps1`, including in comments.** The plan's verification
greps for it. The comments say "the verb DESIGN 9.2 names" and list what
`reagentc` actually has, which carries the same warning without tripping the
check.

**D. Two contract assertions were added beyond the plan's list** — `records
ClearDisk before it can throw` and `records the three listings in the order they
were called` for `IDiskService`, and `reports two indices for the staged Windows
11 media` and `reports a version for every index` for `IImageService`.

### Authentication gates

None.

---

## Verification

| Plan check | Result |
|---|---|
| 1. `pwsh -File ./build.ps1 -Task ci` | exit 0 — lint 0 diagnostics / 209 files, **2990 passed, 0 failed, 42 skipped**, selfcheck 4 of 4 |
| 2. `powershell.exe -File ./build.ps1 -Task test` | exit 0 — **2904 passed, 0 failed, 128 skipped** |
| 3. `test(04-01)` before every `feat(04-01)` | yes, four pairs, verified in `git log` |
| 4. No step or private file names a disk or image tool | 0 matches |
| 5. Both adapters branch only on guards and exit codes | yes, each commented |
| 5a. No `setosimage`; `SetRecoveryImage` builds its path from `$OsRoot` | 0 matches; path built from `$OsRoot` |
| 6. `gen2-vm-raw-disk.json` labelled derived, 04-04 named | yes, in `tests/fixtures/README.md` |
| 7. `Get-Disk` reports disk 0 unchanged | `GPT`, `IsBoot True`, `IsSystem True`, 4 partitions |

Each RED commit was **watched failing for the right reason** before its GREEN:
`CommandNotFoundException` for the factory under test, and for the catalog, `A
parameter cannot be found that matches parameter name 'Disk'`.

## Notes for 04-02 and 04-03

- The MSR is created by `InitializeDisk`. **Do not create one.** The ESP is
  partition 2 on a GPT disk.
- Do not filter disks on `BusType` expecting a VM-specific value: a Gen2 VM disk
  reports `SAS`. Filter on "not USB, over minimum size, not `IsBoot`, not
  `IsSystem`" and then assert exactly one candidate.
- `GetVolume()` reports only lettered volumes. To learn about an unlettered
  partition, read `GetPartition()`.
- `SetBootOrderFirst()` exists and is callable; `ConfigureBoot` owns deciding
  when. Without it a machine reboots into WinPE and the deployment loops
  (SPIKES S6).
- 04-03 must correct `docs/DESIGN.md` 9.2: the recovery-image verb it names does
  not exist on Windows 11 24H2, and WinPE ships no `reagentc.exe`.

## Self-Check: PASSED

All 13 created files exist on disk. All nine commits
(`9b04bb9`, `c563480`, `a50e090`, `1ccb9e8`, `362331e`, `693d682`, `101de79`,
`c475a8c`, `a717e4a`) exist in `git log`.
