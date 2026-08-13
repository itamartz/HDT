---
phase: 04-imaging
plan: 03
subsystem: imaging-steps
tags: [step-types, disk-partition, apply-image, unattend, configure-boot, shouldprocess, benchmark, pester, tdd, powershell-5.1]

# Dependency graph
requires:
  - phase: 03-sequence-engine
    plan: 02
    provides: the step contract, Public/Steps auto-export, Get-HDTStepType discovery
  - phase: 03-sequence-engine
    plan: 04
    provides: Invoke-HDTStepAttempt and "a Configuration failure is never retried"
  - phase: 03-sequence-engine
    plan: 05
    provides: TaskSequence.EndToEnd.Tests.ps1, the model this plan's benchmark copies
  - phase: 04-imaging
    plan: 01
    provides: IDiskService, IImageService, their fakes and the contract both satisfy
  - phase: 04-imaging
    plan: 02
    provides: Select-HDTTargetDisk, Get-HDTDiskLayout, New-HDTDiskLayoutPlan, Resolve-HDTDiskLayoutName, Resolve-HDTImageIndex, Get-HDTOperatingSystem
provides:
  - "Five step types: Validate, DiskPartition, ApplyImage, ApplyUnattend, ConfigureBoot, each with its description function"
  - "Get-HDTStepProperty: the shared reader every step type uses - by name, defaulted, %Var%-expanded, coerced"
  - "Get-HDTFailureClass -ResultData: a refusal a step RETURNED rather than threw is still Configuration"
  - "tests/unit/Imaging.EndToEnd.Tests.ps1: the M3 benchmark, one WinPE leg with the exact ordered 27-operation list"
  - "samples/workspace/TaskSequences/DEMO-M3: the sequence the benchmark runs and 04-04 deploys"
  - "samples/workspace/OperatingSystems/Win11-LTSC-2024/os.yaml: the catalog sample with the real captured indices"
  - "tests/fixtures/unattend/win11-client.xml: the SPIKES S7 document, tokenised"
  - "New-HDTFakeDiskService -Failure: the seam that makes a disk step's failure path provable"
  - "Six new HDT* variables in Get-HDTVariableMap"
affects: [04-04-integration-and-e2e, 05-boot-image, 06-drivers, 07-applications]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "A step NEVER lets a refusal escape as a terminating error: it returns Failed with the errorId in the result's Data, because the step contract requires a result and a throw would turn it red"
    - "The classifier reads the result's Data as well as the thrown error, so a returned refusal is still never retried"
    - "One shared property reader per step family, so 'what does an absent property mean' has one answer rather than five"
    - "-As Bool PARSES rather than casts: [bool] 'false' is true in PowerShell, which would make 'setBootOrder: false' mean true"
    - "The protected drive letters are passed UNCONDITIONALLY, not behind any authored property"
    - "Warn-and-continue is named per failure and argued in the file, rather than being a blanket try/catch"
    - "A secret is minted by the step that needs it and written back to the run state, so one run has one secret however many steps want it"
    - "The benchmark's ordered list is asserted as one newline-joined string, because Pester abbreviates a long array and hides the operation that changed"

key-files:
  created:
    - src/Hephaestus/Private/Get-HDTStepProperty.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTValidateStep.ps1
    - src/Hephaestus/Public/Steps/Get-HDTValidateStepDescription.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTDiskPartitionStep.ps1
    - src/Hephaestus/Public/Steps/Get-HDTDiskPartitionStepDescription.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTApplyImageStep.ps1
    - src/Hephaestus/Public/Steps/Get-HDTApplyImageStepDescription.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTApplyUnattendStep.ps1
    - src/Hephaestus/Public/Steps/Get-HDTApplyUnattendStepDescription.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTConfigureBootStep.ps1
    - src/Hephaestus/Public/Steps/Get-HDTConfigureBootStepDescription.ps1
    - tests/unit/Get-HDTStepProperty.Tests.ps1
    - tests/unit/Invoke-HDTValidateStep.Tests.ps1
    - tests/unit/Invoke-HDTDiskPartitionStep.Tests.ps1
    - tests/unit/Invoke-HDTApplyImageStep.Tests.ps1
    - tests/unit/Invoke-HDTApplyUnattendStep.Tests.ps1
    - tests/unit/Invoke-HDTConfigureBootStep.Tests.ps1
    - tests/unit/Imaging.EndToEnd.Tests.ps1
    - tests/fixtures/unattend/win11-client.xml
    - samples/workspace/OperatingSystems/Win11-LTSC-2024/os.yaml
    - samples/workspace/TaskSequences/DEMO-M3/sequence.yaml
    - samples/workspace/TaskSequences/DEMO-M3/unattend.xml
  modified:
    - src/Hephaestus/Hephaestus.psd1
    - src/Hephaestus/Private/Get-HDTFailureClass.ps1
    - src/Hephaestus/Private/Invoke-HDTStepAttempt.ps1
    - src/Hephaestus/Public/Get-HDTVariableMap.ps1
    - tests/helpers/HDTFakes/HDTFakes.psm1
    - tests/helpers/README.md
    - tests/fixtures/README.md
    - tests/unit/Get-HDTFailureClass.Tests.ps1
    - tests/unit/New-HDTFakeDiskService.Tests.ps1
    - tests/unit/Get-HDTVariableMap.Tests.ps1
    - tests/contract/StepContract.Tests.ps1
    - samples/README.md
    - samples/workspace/TaskSequences/STD-CLIENT/sequence.yaml
    - docs/DESIGN.md
    - docs/ROADMAP.md

key-decisions:
  - "Get-HDTFailureClass gained -ResultData rather than steps throwing their refusals. The step contract invokes every type with an empty property bag and requires a result whose Status is in the closed set; a step that threw would turn that red. So the errorId travels in the result's Data and the classifier reads it there"
  - "The thrown error outranks the result data. An exception says what actually went wrong; the data says what the step believed"
  - "-As Bool parses rather than casts, because [bool] 'false' is $true in PowerShell - a cast would make 'setBootOrder: false' mean true on the one property whose whole purpose is to turn something off"
  - "New-HDTFakeDiskService gained -Failure. Nothing else can make that fake fail on a well-formed call sequence - ClearDisk leaves the disk RAW, so every later call finds exactly the state it wanted - which left DiskPartition's failure path unprovable"
  - "DiskPartition publishes HDTOSVolume and friends even under -WhatIf, so a dry run of a whole sequence stays coherent: the steps after it plan against the volumes it would have created. It still calls no write method"
  - "ApplyUnattend MINTS the deployment password when neither a variable nor the state has one, and writes it back to the state. Without it a WinPE-half sequence with no Restart deploys a machine whose Administrator password is the literal string %HDTAdminPassword%, identical on every machine HDT ever builds"
  - "ConfigureBoot warns and continues for the whole recovery-image branch and for the firmware reorder, and fails for bcdboot. A machine with no registered WinRE boots; a machine with no boot files does not"
  - "No step in this plan moves the log to the formatted volume. DESIGN 4.4.1's relocation touches New-HDTLogContext, Copy-HDTLog and the state document's mirror, and belongs with phase 05's Start-HDTDeployment. A half-done relocation would be worse than the honest gap"
  - "The benchmark asserts its ordered list as one newline-joined string, because Pester abbreviates a long array to '...16 more' - and a failure message that hides the operation which changed is not a specification a human can read"

patterns-established:
  - "The five step property lists, defaults and published variables, which 04-04's real run is written against"
  - "The refusal-to-result-data convention, which every later destructive step follows"
  - "The 27-line ordered operation list as the specification of what HDT does to a machine in WinPE"

# Metrics
duration: 210min
completed: 2026-08-13
---

# Phase 04 Plan 03: The Five Imaging Steps and the M3 Benchmark Summary

**The WinPE half of a Windows 11 deployment — validate, partition, apply, stage the unattend, make the machine boot its own disk — running end to end in a three-second Pester run against hand-written fakes, asserting the exact ordered list of twenty-seven operations it would have performed on a machine.**

## Performance

- **Duration:** ~210 min
- **Tasks:** 3 of 3
- **Files created:** 22 · **Files modified:** 15
- **Suite:** **3652 passed / 0 failed / 42 skipped** under pwsh 7.5.8 (`build.ps1 -Task ci`, exit 0, all four self-checks passed); **3538 passed / 0 failed / 156 skipped** under Windows PowerShell 5.1.26100.8655 (`build.ps1 -Task test`, exit 0). Baseline before this plan was 3304 / 3190 — **+348 and +348**.
- PSScriptAnalyzer: **0 diagnostics across 247 files**.
- The benchmark itself: **38 assertions in 3.2 s**, on both engines.

## Task Commits

| Task | RED | GREEN |
|---|---|---|
| 1a the reader and the classifier | `d187557` (32 failing) | `d43ee1c` |
| 1b Validate | `f0f8d57` (25 failing) | `081f1a3` |
| 1b′ the fake's failure seam | `60fed95` (9 failing) | `e9fbc50` |
| 1c DiskPartition | `737a3ba` (52 failing) | `d4781fd` |
| 2a ApplyImage | `7900b21` (29 failing) | `7fda46e` |
| 2b ApplyUnattend | `cc5ddd4` (32 failing) | `992a2a1` |
| 2c ConfigureBoot | `c2713b2` (27 failing) | `cf9d8c6` |
| 3 the benchmark | `b94d32e` | — |
| 3 the variable map | `4a49c9b` (3 failing) | `28739ea` |
| 3 the documents | `391f404` | — |

**Every RED commit was watched failing for the right reason before its GREEN**, and the full suite was green before each commit pair was made.

---

## What 04-04 is written against

### The five steps: properties, defaults and published variables

#### `Validate`

| Property | Type | Default | Meaning |
|---|---|---|---|
| `minRamMB` | long | none | fails if `HDTMemory` is below it, **and fails if `HDTMemory` was never gathered** |
| `minDiskGB` | long | none (60 for the selection) | fails if no disk is at least this big |
| `requireUefi` | bool | `false` | fails if `HDTIsUEFI` is not true |
| `diskNumber` | int | none | passed to `Select-HDTTargetDisk` |
| `wipe` | bool | `false` | mirrors `DiskPartition`, so the pre-flight makes the same call |
| `requireVariable` | list or scalar | none | each named variable must be non-empty |

Publishes nothing. `Data` carries `diskNumber` on success, `errorId` and `failedCheck` on a refusal. **Every check is opt-in except the target disk selection**, which always runs — that is the reason the step exists.

**It reports every failed check, not the first.** Two trips to the bench is the failure that assertion prevents.

#### `DiskPartition`

| Property | Type | Default | Meaning |
|---|---|---|---|
| `layout` | string | firmware decides | `%Var%`-expanded by `Resolve-HDTDiskLayoutName` |
| `wipe` | bool | `false` | → `-AllowExistingData` |
| `diskNumber` | int | none | the ambiguity override |
| `minDiskGB` | long | **60** | → `-MinimumSizeByte` |

Publishes `HDTTargetDisk` (int), `HDTSystemVolume`, `HDTOSVolume`, `HDTRecoveryVolume` (empty for `bios-standard`). `Data` carries `diskNumber`, `layout`, `partitionStyle`, `plan`.

`[CmdletBinding(SupportsShouldProcess = $true)]`, gated on
`ShouldProcess("disk N (FriendlyName, X GB)", 'Clear and repartition')`.

#### `ApplyImage`

| Property | Type | Default | Meaning |
|---|---|---|---|
| `os` | string | none | catalog id, `%Var%`-expanded |
| `image` | string | none | an explicit WIM path instead; indices read via `GetImageInfo` |
| `index` / `name` / `edition` | int / string / string | the catalog's `defaultIndex` | intersected, not filtered in sequence |
| `target` | string | **`primary`** | `primary` = `%HDTOSVolume%`; a letter with or without a colon also works |

Publishes `HDTImageIndex`. `Data` carries `imagePath`, `index`, `imageName`, `target`, `durationMs`.

#### `ApplyUnattend`

| Property | Type | Default | Meaning |
|---|---|---|---|
| `template` | string | none, required | relative to the sequence folder, or rooted |
| `target` | string | `%HDTOSVolume%` | a drive letter |
| `expand` | bool | **`true`** | `%Var%` expansion over the whole document |

Publishes `HDTUnattendPath`. `Data` carries `path`, `byteCount`, `template` — **never the document**.

Staged at **`<target>:\Windows\Panther\unattend.xml`**. The relative template resolves through `Get-HDTWorkspacePath -Kind TaskSequences -ChildPath <sequenceId>, <template>`, where `<sequenceId>` is `$Context.State.sequenceId` first and `HDTTaskSequenceID` second. **No literal `'TaskSequences'` appears in the step.**

#### `ConfigureBoot`

| Property | Type | Default | Meaning |
|---|---|---|---|
| `firmware` | string | **`auto`** | `auto` reads `HDTIsUEFI`; `UEFI` or `BIOS` pins it |
| `recovery` | bool | **`true`** | skipped anyway when `HDTRecoveryVolume` is empty |
| `setBootOrder` | bool | **`true`** | SPIKES S6's fourth finding |

Publishes nothing. `Data` carries `osVolume`, `systemVolume`, `firmware`, `recoveryVolume`, `recoveryRegistered`, `bootOrder`.

### The exact ordered operation list, as finally asserted

Twenty-seven operations, from `tests/unit/Imaging.EndToEnd.Tests.ps1`, filtered to `DiskService`, `ImageService` and the three filesystem operations that are side effects on a machine (excluding writes under the log path):

```
 1  DiskService.GetDisk                   # Validate: the pre-flight reads,
 2  DiskService.GetPartition              #   and only reads
 3  DiskService.GetVolume
 4  DiskService.GetDisk                   # DiskPartition: the three listings again
 5  DiskService.GetPartition
 6  DiskService.GetVolume
 7  DiskService.ClearDisk                 # SPIKES S6: -RemoveData -RemoveOEM, before Initialize
 8  DiskService.InitializeDisk            # GPT; THIS is what creates the MSR
 9  DiskService.NewPartition              # ESP, created as basic data so it can take a letter
10  DiskService.SetPartitionDriveLetter   # S:
11  DiskService.FormatVolume              # FAT32
12  DiskService.SetPartitionType          # now it becomes the ESP
13  DiskService.NewPartition              # Windows
14  DiskService.SetPartitionDriveLetter   # W:
15  DiskService.FormatVolume              # NTFS
16  DiskService.NewPartition              # Recovery, UseMaximumSize
17  DiskService.SetPartitionDriveLetter   # R:
18  DiskService.FormatVolume              # NTFS
19  DiskService.SetPartitionType          # the recovery type
20  ImageService.ApplyImage               # index 1 to W:\
21  FileSystem.CreateDirectory            # W:\Windows\Panther
22  FileSystem.WriteAllText               # unattend.xml (SPIKES S7's verified location)
23  ImageService.InstallBootFile          # bcdboot W:\Windows /s S: /f UEFI
24  FileSystem.CreateDirectory            # R:\Recovery\WindowsRE
25  FileSystem.CopyItem                   # Winre.wim, out of the applied image
26  ImageService.SetRecoveryImage         # the applied image's own Reagentc.exe
27  ImageService.SetBootOrderFirst        # SPIKES S6: or the machine reboots into WinPE
```

**Two differences from the list the plan predicted**, both real and both correct:

1. **The three read calls appear twice**, once for `Validate` and once for `DiskPartition`. That is the pre-flight doing its job: it makes the same selection with the same arguments, so a deployment that will refuse refuses in step 1.
2. **`ImageService.GetImageInfo` does not appear at all.** `os.yaml` carries the indices, so the apply never opens a 4 GB WIM over SMB to find out what is in it. A test asserts that explicitly.

Alongside the list, the benchmark asserts the machine it would have left behind: **four partitions, exactly one of them `Reserved`**, a 260 MB FAT32 ESP typed `System`, an NTFS `Windows` volume, a recovery partition carrying `{de94bba4-…}`, and **no operation naming disk 1**.

### The refusal-to-result-data convention, and the classifier change

A step never lets a refusal escape as a terminating error. It catches, logs `step.fail`, and returns:

```powershell
New-HDTStepResult -Status Failed -Message $refusal.Exception.Message `
    -Data ([ordered] @{ errorId = 'HDTAmbiguousTargetError' })
```

`Get-HDTFailureClass` gained `-ResultData`; `Invoke-HDTStepAttempt` passes `$result.Data`. An `errorId` in the named configuration list (`HDTConfigurationError`, `HDTAmbiguousTargetError`, `HDTUnsafeTargetError`, `HDTNoTargetDiskError`, `HDTAmbiguousImageError`) classifies as `Configuration`, so a refusal is never retried. Proven twice: at the classifier, and at the loop — a `DiskPartition` step declaring `retry: { count: 2 }` on an ambiguous machine runs **once**, and the fake clock records **zero** milliseconds slept.

### The unattend, and how the password stays out of the logs

Staged at `W:\Windows\Panther\unattend.xml`. `%HDTAdminPassword%` resolves in this order, with no fourth outcome:

1. an `HDTAdminPassword` variable the rules resolved;
2. `$Context.State.deploymentPassword`;
3. **minted with `New-HDTDeploymentPassword`, written back to the state, and used.**

Step 3 only fires when the template actually names the token. The log carries **the path and the byte count only**; assertions prove the secret appears in neither `HDT.jsonl`, `HDT.log` nor the step log, and that the document body (`<unattend`, `AdministratorPassword`) appears in no record at any level, Debug included.

### `ConfigureBoot`'s warn-and-continue cases

| Case | Outcome |
|---|---|
| `Winre.wim` absent from the applied image | **Warning, skip**, still sets the boot order, returns `Completed` |
| `SetRecoveryImage` throws | **Warning, continue**, still sets the boot order, returns `Completed` |
| `SetBootOrderFirst` throws | **Warning, continue**, returns `Completed`; the warning says the media must be removed or demoted by hand |
| `InstallBootFile` throws | **`Failed`**, and the boot order is not touched |

### Everything here is proven only against a fake

At the end of this plan, **every behaviour above is proven against hand-written doubles and nothing else.** No disk was cleared, no image applied, no boot file written, no firmware order changed. Specifically unproven until 04-04:

- that `Set-Partition -GptType` after `Format-Volume` behaves — the ESP create-letter-format-retype recipe is the field recipe, not a verified one;
- that the applied image's `Reagentc.exe /setreimage` works against an offline target from inside WinPE — nobody has ever run it;
- that `bcdedit {fwbootmgr} displayorder … /addfirst` succeeds in a Gen2 VM's firmware;
- that a machine built by this sequence reaches OOBE. SPIKES S6 did it **by hand**; 04-04 is where the *code* does it.

---

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 3 — Blocking] `New-HDTFakeDiskService` gained `-Failure`**

- **Found during:** Task 1c, writing `Context 'failure'`.
- **Issue:** The fake cannot be made to fail on a well-formed sequence of calls. The obvious trick — seeding a disk that is already `GPT` so `InitializeDisk` throws — does not work, because `ClearDisk` sets the style back to `RAW` first. `DiskPartition`'s entire failure path was unprovable.
- **Fix:** `-Failure`, mirroring `New-HDTFakeImageService` exactly: same parameter shape, same `System.InvalidOperationException`, checked *after* the call records so the attempt stays visible.
- **Files:** `tests/helpers/HDTFakes/HDTFakes.psm1`, `tests/unit/New-HDTFakeDiskService.Tests.ps1`, `tests/helpers/README.md`
- **Commits:** `60fed95` (test) → `e9fbc50` (feat)

**2. [Rule 1 — Bug] The unattend fixture leaked the password into an XML comment**

- **Found during:** Task 2b, by the assertion `mints one password for a run, not one per token` — which counted **three** occurrences of the secret in the staged document instead of two.
- **Issue:** The fixture's own explanatory comment named `%HDTAdminPassword%` in prose. Expansion runs over the **whole document**, comments included, so the minted password was substituted there too — putting the deployed machine's local Administrator password into a comment inside the unattend that ships to it.
- **Fix:** the comment now names the tokens without their per-cent signs, and says why. The assertion that caught it is unchanged.
- **Files:** `tests/fixtures/unattend/win11-client.xml`
- **Commit:** `cc5ddd4`

**3. [Rule 1 — Bug] The benchmark's password assertion would have passed against an empty string**

- **Found during:** Task 3, first run of the benchmark.
- **Issue:** It read `state.deploymentPassword` **after** the run — but DESIGN 4.5.3's teardown runs in the loop's `finally` and nulls it on a successful run. The "it never reached the log" assertion would have been comparing the log against `''`.
- **Fix:** the secret is read back out of the staged unattend, which is the one place it still exists.
- **Files:** `tests/unit/Imaging.EndToEnd.Tests.ps1`
- **Commit:** `b94d32e`

**4. [Rule 1 — Bug] The benchmark's refusal leg did not actually create an ambiguity**

- **Found during:** Task 3, first run.
- **Issue:** The plan specified growing the content disk to 64 GB so two disks qualify. It does not work — and the reason is worth having: disk 1 carries drive letter `Z`, the workspace root, so **exclusion rule 2 removes it however large it is**. The guard that stops HDT wiping the share it is reading from also keeps that disk out of the ambiguity. Written as the plan specified, the "refusal" leg would have quietly *succeeded* and proved nothing.
- **Fix:** the refusal leg adds a **third** blank 64 GiB disk instead. A new assertion, `leaves the workspace disk out of the ambiguity`, pins the reason.
- **Files:** `tests/unit/Imaging.EndToEnd.Tests.ps1`
- **Commit:** `b94d32e`

### Deliberate departures from the plan text

**1. The step contract's hand-maintained registry list was extended in two steps, not one.** The plan put all five new type names into `Context 'the registry itself'` during task 1. That would have left the suite red across four commits (the three task-2 types did not exist yet), which breaks "green before moving on". `Validate` and `DiskPartition` went in with task 1; `ApplyImage`, `ApplyUnattend` and `ConfigureBoot` with task 2. The final state is exactly what the plan asked for.

**2. `Invoke-HDTStep -Step … -Context … -WhatIf` (in the plan's task-1 verify block) is not a thing.** The dispatcher does not declare `SupportsShouldProcess`, so it cannot take `-WhatIf`, and giving it one would make a non-destructive function ask for confirmation. Two other paths were verified instead, and both are the real ones:

- `Invoke-HDTDiskPartitionStep … -WhatIf` directly — proven by unit test and run live against this host;
- `Invoke-HDTTaskSequence … -WhatIf`, which short-circuits at the sequence level and never enters a step at all.

**3. `Validate` gained a `wipe` property the plan did not list.** Without it the pre-flight would run `Select-HDTTargetDisk` with *different* arguments from the step it is pre-flighting, and would refuse a machine `DiskPartition` would have accepted — which is the one thing a pre-flight must not do.

**4. `ApplyImage` publishes `durationMs` in its result data as well as the log.** The plan asked for the elapsed time in the log; putting it in `Data` too costs nothing and gives 04-04 a number to assert on.

### Not done, and deliberately

**No step moves `_HDTLogPath` to the formatted volume.** DESIGN 4.4.1 says it moves to `<target>\HDT\Logs` once the target volume exists. Relocating a live log context mid-run touches `New-HDTLogContext`, `Copy-HDTLog` and the state document's mirror, and it belongs with phase 05's `Start-HDTDeployment`. Phase 04 leaves the log where the leg started it and relies on the `-LogDestination` copy-back the loop already performs in its `finally`, which 04-04's launcher points at the content disk. This is stated plainly rather than half-done.

---

## Verification

| # | Check | Result |
|---|---|---|
| 1 | `pwsh -NoProfile -File ./build.ps1 -Task ci` | **exit 0** — 3652 passed / 0 failed / 42 skipped, lint 0 diagnostics across 247 files, 4 of 4 self-checks |
| 2 | `powershell.exe -NoProfile -File ./build.ps1 -Task test` | **exit 0** — 3538 passed / 0 failed / 156 skipped under 5.1.26100.8655 |
| 3 | `git log --oneline` shows `test(04-03)` before every `feat(04-03)` | yes, seven pairs |
| 4 | `Get-HDTStepType` lists all ten types; `StepContract.Tests.ps1` green over them | yes — ApplyImage, ApplyUnattend, CommandLine, ConfigureBoot, DiskPartition, NoOp, PowerShell, Restart, SetVariable, Validate |
| 5 | No file under `Public/Steps/` names a Storage cmdlet, DISM, a native boot tool, CIM or the filesystem directly | **verified at the token level.** A plain `Select-String` returns three hits, all of them prose inside comment-based help naming SPIKES S6's recipe (`Clear-Disk -RemoveData -RemoveOEM`, `Initialize-Disk`). An AST scan that discards comment tokens returns **zero** |
| 6 | The benchmark asserts the ordered list and completes in under ten seconds on both engines | **3.2 s**, 38 assertions; the seven new test files run 222 assertions under 5.1 with **none skipped** |
| 7 | The benchmark's disk ends with exactly one `Reserved` partition | yes |
| 8 | `DEMO-M3/sequence.yaml` is the file the benchmark reads, byte for byte | yes — `Get-Content -Raw` off `samples/`, seeded as text |

Additionally, per the plan's task-3 verify: **one expectation was deliberately broken** (`ImageService.SetBootOrderFirst` removed from the expected list) and the failure output read. It prints the whole 27-line actual list under `-Because` and names the divergence, which is the readability the list exists for. Restored immediately; suite re-run green.

### Verified live, against this host's real hardware

Built a context over the **real** `New-HDTDiskService` and ran both steps against it:

```
WhatIf status   : Failed
WhatIf errorId  : HDTNoTargetDiskError
Validate status : Failed
Validate errorId: HDTNoTargetDiskError
Message: no disk on this machine can be used as the deployment target:
  - disk 0 is the disk this machine booted from; disk 0 holds drive letter C,
    which this deployment is reading from or writing to
```

Both refusal rules fired on the real machine — rule 1 (boot disk) **and** rule 2 (the protected workspace letter), which is exactly the guard `DiskPartition` passes unconditionally.

## Lab safety

**No Hyper-V call was made except one read-only `Hyper-V\Get-VM` at the end.** `CM01` and `DC01` are `Off` and untouched; `HDT-PE-Test` (S1's spike VM) is `Off` and untouched. No VM was created, started, modified or removed.

**This host's disk 0 was GPT / IsBoot True / IsSystem True with 4 partitions before this plan and is identical after**, verified before and after every run that touched the real disk service — including the two live runs above, both of which refused before reaching a write.

## Notes for 04-04

1. **The sequence to deploy is `samples/workspace/TaskSequences/DEMO-M3/sequence.yaml`, unchanged.** The benchmark reads that exact file; if the lab run needs it altered, alter it and let the benchmark tell you what changed.
2. **The workspace must be on a disk the run can see and must not be the target.** The benchmark's topology is the VM's: a 64 GiB blank target and a smaller content disk carrying the workspace volume. `minDiskGB: 60` is what excludes the content disk from the choice — with a content disk of 60 GB or more, HDT will refuse, correctly.
3. **The log stays where the leg started it.** Pass `-LogDestination` on the loop pointing at the content disk, or the log dies with the RAM disk.
4. **Assert on the operations, not just the outcome.** Everything in the 27-line list is a call the real adapters will make; a real run that diverges from it is the interesting result.
5. **Three things are being run for the first time ever** and any of them may need a SPIKES entry: `Set-Partition -GptType` after `Format-Volume`; the applied image's `Reagentc.exe /setreimage` against an offline target from WinPE; and `bcdedit {fwbootmgr} … /addfirst` in a Gen2 VM. The last two warn and continue by design, so **read the warnings** — a green run does not mean all three worked.
6. **The deployment password is minted by `ApplyUnattend`** and appears in `state.json` until the teardown nulls it. If 04-04 needs to log into the built machine, capture it from the state document mid-run or from the staged unattend, not from the log — it is not there.

## Self-Check: PASSED

Every file this summary claims exists, exists. Every commit hash it names is in
`git log`. The four `key_links` the plan requires are present
(`Select-HDTTargetDisk` ×3, `GetRequired('Disk'` ×1, `Panther` ×2,
`SetBootOrderFirst` ×2), and every artifact exceeds its `min_lines`:
`Invoke-HDTDiskPartitionStep.ps1` 272 (≥220), `Invoke-HDTApplyImageStep.ps1` 199
(≥140), `Invoke-HDTConfigureBootStep.ps1` 223 (≥150),
`Imaging.EndToEnd.Tests.ps1` 505 (≥250).
`samples/workspace/TaskSequences/DEMO-M3/unattend.xml` and
`tests/fixtures/unattend/win11-client.xml` are byte-identical.
