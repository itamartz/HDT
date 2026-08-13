---
phase: 05-bootimage
plan: 04
subsystem: boot image
tags: [bootimage, dism, oscdimg, iso, winpe, manifest, adk]

requires:
  - "05-01: Get-HDTAdkPath, Import-HDTWorkspaceDocument, Get-HDTBootImageComponent"
  - "05-02: Set-/Get-HDTShareCredential, Test-HDTShareAcl, Get-HDTShareAccessRule"
  - "05-03: Get-HDTBootstrapConfiguration, Payload/Start-HDTDeployment.ps1, Payload/Start-HDTResume.ps1"
  - "04-01: IFileSystem, Copy-HDTContentTree, the fake conventions"
provides:
  - "Update-HDTBootImage: one build, two artifacts, one manifest"
  - "New-HDTBootIso: the oscdimg wrapper with SPIKES S2's staging"
  - "New-HDTBootImageService and New-HDTFakeBootImageService: IBootImageService"
  - "IFileSystem.GetHash, the tenth method"
  - "A bootable WIM and a bootable ISO this repository built, for 05-05 to boot"
affects:
  - "docs/DESIGN.md 5.1 and 5.2 - what lands where inside the image, the staging, and the ISO is not the slow half"
  - "build.ps1 - the e2e task no longer requires a hand-built ISO"

tech-stack:
  added:
    - "Dism module: Mount-WindowsImage, Dismount-WindowsImage, Add-WindowsPackage, Add-WindowsDriver, Get-WindowsPackage, Get-WindowsImage, Export-WindowsImage"
    - "dism.exe /Set-ScratchSpace (there is no cmdlet)"
    - "oscdimg.exe"
  patterns:
    - "A fake that MODELS a mount: the code under test writes into it and reads back out"
    - "The shared journal projected down to named milestones for an ordered-ceremony assertion"

key-files:
  created:
    - src/Hephaestus/Public/New-HDTBootImageService.ps1
    - src/Hephaestus/Public/New-HDTBootIso.ps1
    - src/Hephaestus/Public/Update-HDTBootImage.ps1
    - src/Hephaestus/Private/Get-HDTStartnetScript.ps1
    - src/Hephaestus/Private/Get-HDTBootIsoArgument.ps1
    - src/Hephaestus/Private/New-HDTBootImageManifest.ps1
    - tests/contract/BootImageService.Contract.Tests.ps1
    - tests/integration/BootImage.Integration.Tests.ps1
    - tests/unit/New-HDTFakeBootImageService.Tests.ps1
    - tests/unit/Get-HDTStartnetScript.Tests.ps1
    - tests/unit/Get-HDTBootIsoArgument.Tests.ps1
    - tests/unit/New-HDTBootImageManifest.Tests.ps1
    - tests/unit/New-HDTBootIso.Tests.ps1
    - tests/unit/Update-HDTBootImage.Tests.ps1
  modified:
    - tests/helpers/HDTFakes/HDTFakes.psm1
    - src/Hephaestus/Public/New-HDTFileSystem.ps1
    - tests/contract/FileSystemService.Contract.Tests.ps1
    - build.ps1
    - docs/DESIGN.md
    - .planning/SPIKES.md

decisions:
  - "IFileSystem grew a tenth method, GetHash, rather than the builder growing a Get-FileHash call no fake could answer"
  - "The fake boot image service models a mount in the injected IFileSystem, so a builder that wrote after a discard is caught by a test"
  - "contentMarker is written as the constant 'rules.yaml': workspace.yaml has no such key and adding one is a schema change outside this plan"
  - "-EngineModulePath and -YamlModulePath are injectable, defaulting to the running module and Get-Module -ListAvailable"
  - "The repository is recognised by its .git folder, derived from the RUNNING module rather than from -EngineModulePath"
  - "DESIGN 5.1 corrected by measurement: the ISO leg costs two seconds, not half the build"

metrics:
  duration: "one session"
  completed: 2026-08-14
  tasks: 3
  commits: 14
---

# Phase 5 Plan 4: The boot image build Summary

`Update-HDTBootImage` turns an ADK, a workspace and the engine into a bootable
WIM and a hash-identical bootable ISO in 123 seconds, and records exactly what
went into them — proven against fakes in a two-second suite and then against the
real ADK, with `startnet.cmd` read back out of a mounted image.

## What was built

**`IBootImageService`** — nine methods over `Mount-WindowsImage` and friends,
plus `dism.exe /Set-ScratchSpace` (no cmdlet exists for it) and `oscdimg.exe`.
The real adapter is untested by design and stays dumb: two existence guards, two
exit-code checks, one lazy path resolution and one argument construction from the
boolean the interface carries. Its contract row calls `GetImageInfo` and nothing
else; the other eight mount, write or burn.

**`New-HDTFakeBootImageService`** is the first fake in this repository that
**models a mount**. Every other fake answers questions; this one holds the small
piece of state the code under test writes *into*. `MountImage` seeds
`<MountPath>\Windows\System32` into the injected `IFileSystem`, and
`DismountImage($false)` takes the whole tree away — so a builder that wrote after
discarding is caught by a test rather than by a boot image with no launcher in
it. `ExportImage` and `NewIso` produce files, which is what makes DESIGN 6.1.1's
copy provable without an ISO.

**Three pure functions.** `Get-HDTStartnetScript` returns five CRLF lines and no
more. `Get-HDTBootIsoArgument` is where SPIKES S2 lives — all six
firmware/no-prompt combinations asserted as exact strings, a refusal for a
boot-bit path with a space, and DESIGN 5.2's two warnings in the words the design
requires. `New-HDTBootImageManifest` is handed everything it records and returns
JSON text, so the caller writes it through `IFileSystem` like everything else.

**`New-HDTBootIso`** resolves the ADK, stages only the El Torito images the
firmware needs into a space-free directory, and burns. **`Update-HDTBootImage`**
is seventeen commented blocks in the order its test asserts.

## The seventeen steps, as the test reads them

The headline assertion projects the shared journal down to the build's
milestones and compares it element by element. The failure message is a list a
human can check against DESIGN 5.1:

```
ImportWorkspaceDocument, ResolveAdkPath, PrepareScratch, CopyWinPeWim,
CreateMediaSources, MountImage,
AddPackage:WinPE-WMI.cab, AddPackage:WinPE-WMI_en-us.cab,
AddPackage:WinPE-NetFx.cab, AddPackage:WinPE-NetFx_en-us.cab,
... eighteen in all, each language pack immediately after its component ...
SetScratchSpace, AddDriver, StageEngine, StageYaml,
StageDeploymentPayload, StageResumePayload, WriteBootstrap, WriteStartnet,
CopyExtraContent, DismountImage, ExportImage, CopyWimIntoMedia,
ResolveAdkPath, NewIso, WriteManifest
```

The **second `ResolveAdkPath`** is `New-HDTBootIso` resolving the ADK itself,
because it is a command in its own right. It is written into the expected list
with a comment, so the day somebody turns it into a parameter, the list says
what changed.

## The artifacts 05-05 will boot

| | Value |
|---|---|
| `C:\HDTLab\scratch\bootimage\Share\Boot\HDTPE_x64.wim` | **495 340 358 bytes** |
| `…\Boot\HDTPE_x64.iso` | **550 916 096 bytes** |
| `…\Boot\HDTPE_x64.manifest.json` | 6 859 bytes |
| WIM SHA256 | `30FF0972FE4E8D416EE150FFD6A4EEE48F93599B9CF6245AE76F20DFEE5A90E5` |
| `sources\boot.wim` inside the ISO | **the same hash** |
| manifest `isoBootWimSha256` | **the same hash** |

DESIGN 6.1.1 — the property ROADMAP M4 names explicitly — holds three ways:
the file on disk, the WIM inside the mounted ISO, and the manifest. Three,
because a manifest that agreed with itself but not with the disk would be worse
than none.

### Where the time goes

| | Measured |
|---|---|
| Full build (WIM + ISO) | **123 s** |
| The same build with `-SkipIso` | **120 s** |
| **The ISO leg** | **~2 s** |
| The whole integration file — two builds and a read-only re-mount, 24 tests | **291 s** |

**The plan budgeted 15–25 minutes; it takes two.** And DESIGN 5.1's claim that
"generating the ISO is the slow half of the build" is **false on this hardware
and has been corrected in the document**. The time goes on the mount, the
eighteen cabs and `Export-WindowsImage -CompressionType Max`. `-SkipIso` is worth
having for the artifact it does not produce, not for time it does not save.

### `startnet.cmd`, as read back out of the mounted image

```
@echo off
rem Written by Update-HDTBootImage. Do not edit inside the image; edit HDT.
set HDT_LAUNCHED_BY=startnet
wpeinit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTDeployment.ps1
```

First byte `0x40`, not `0xEF` — no BOM, which `cmd.exe` would read as a command
and fail on with no useful message. `X:\HDT\` carries `bootstrap.json`,
`Start-HDTDeployment.ps1`, `Start-HDTResume.ps1` and `Modules\`, and
`WinPE-PowerShell` put `powershell.exe` where that last line expects it.

## What the fakes and the plan had wrong

**This is the most valuable section of this document.** Four things, all found by
running against the real tools.

**1. `Get-WindowsImage`'s `ImageSize` is the UNCOMPRESSED size, not the file
size.** The plan's `<verified_facts>` records `winpe.wim` as 340 134 390 bytes —
that is the **file**. DISM reports **2 009 251 937**. The contract test asserted
the file size against the DISM number and **went red on the real row**, which is
exactly what the real row is for. Both numbers are now pinned and labelled. This
is repository-wide: `IImageService.SizeBytes` has always been `ImageSize` too.

**2. `powershell-yaml` ships `lib\net47`, not `net47` at the module root.**
SPIKES S9.1 recorded "its net47 flavour loads against WinPE-NetFx" and an
assertion written from that sentence looked in the wrong place. It was the one
test the first real integration run turned red. The staging was correct — the
whole tree is copied — so this was a defect in the test.

**3. Windows PowerShell 5.1's `ConvertTo-Json` puts two spaces after a colon;
pwsh 7 puts one.** An assertion that pinned the formatting was green on one
engine and red on the other. Use `-Match '"key":\s*"value"'`.

**4. A PowerShell class method will not compile a variable assigned only inside
a `try`** — `ParserError: Variable is not assigned in the method`. It bites in
`HDTFakes.psm1` and nowhere else, because the fakes are the only classes here.

**The built image is deliberately NOT byte-comparable to SPIKES S1's**, and it
could not be: S1's `boot.wim` is 503 853 178 bytes (`2C70D1A2…`), HDT's is
495 340 358 (`30FF0972…`). HDT's carries the engine, `powershell-yaml`, both
payload scripts, `bootstrap.json` and a `startnet.cmd` that launches the engine
rather than dropping to a prompt — and is *smaller* despite carrying more,
because `-CompressionType Max` is doing work the hand build's export did not. A
byte-identical result would have meant the engine was not in there.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `IFileSystem` grew a tenth method, `GetHash`**
- **Found during:** Task 2, writing `New-HDTBootIso`
- **Issue:** The plan requires `New-HDTBootIso` to return the SHA256 of the ISO
  it produced and `Update-HDTBootImage` to record three hashes in the manifest.
  A 550 MB ISO cannot go through `ReadAllText`, and a `Get-FileHash` call in the
  builder would be a call no fake could answer — the exact shape PROJECT
  constraint 4 exists to prevent.
- **Fix:** Added `GetHash` to both implementations and to the contract, test
  first: seven assertions per row including the **value** for `'hello'`, so a
  fake with its own hashing scheme could not let a builder that compared nothing
  pass. Documented in `tests/helpers/README.md`.
- **Commits:** `8fe5a71`, and the GREEN that followed

**2. [Rule 1 - Bug] The contract asserted `winpe.wim`'s file size against DISM's
uncompressed size**
- **Found during:** Task 1, the first run of the real contract row
- **Fix:** Both numbers pinned and labelled; see "what the fakes had wrong".

**3. [Rule 1 - Bug] The repository check derived its root from
`-EngineModulePath`**
- **Found during:** Task 2. With `-EngineModulePath 'C:\Modules\Hephaestus'` the
  computed repository root was `C:\`, so the refusal never fired.
- **Fix:** Derived from `$script:HDTModuleRoot` — the repository a build must not
  write into is the one this code is running from.

**4. [Rule 1 - Bug] `-Credential` on a private function took a hashtable**
- **Found during:** Task 2 lint. `PSUsePSCredentialType` is a Warning and
  therefore breaks `-Task ci`.
- **Fix:** Renamed to `-CredentialRecord`, which is also what it is.

**5. [Rule 1 - Bug] Two test assertions pinned engine-specific JSON formatting
and a class-method variable scope**
- See items 3 and 4 of "what the fakes had wrong".

**6. [Rule 1 - Bug] `lib\net47`, not `net47`**
- **Found during:** Task 3, the first real integration run — the only red test in
  it.

### Deliberate departures from the plan's wording

**`contentMarker` is written as the constant `'rules.yaml'`, not carried across
from `workspace.yaml`.** The plan says "carried across from `workspace.yaml`
verbatim", but `workspace.yaml` **has no `contentMarker` key** —
`Assert-HDTWorkspaceDocument`'s `$allowedRootKey` list, settled in 05-01, is
`schemaVersion, id, name, deployRoot, logLevel, credential, bootImage`. Adding
one is a schema change with its own contract test and fixtures, and it is not
this plan's. `deployRoot` **is** carried verbatim, which is the half that
matters, and `Get-HDTBootstrapConfiguration` already defaults `contentMarker` to
DESIGN 3.3's `rules.yaml`. The test is named
`'carries contentMarker across'` and asserts the value that reaches the image.

**`-EngineModulePath` and `-YamlModulePath` were added.** The plan describes
staging "from the running module's `ModuleBase`" and resolving `powershell-yaml`
with `Get-Module -ListAvailable`. Both remain the defaults — an AST test asserts
`-EngineModulePath` defaults to `$script:HDTModuleRoot` — but neither is
reachable from a unit test against a fake filesystem, and a build host staging a
specific engine version is a real use case. `-AccessRule` was added for the same
reason: without it the ACL warning path could not be driven.

**`-Image` was added to `New-HDTFakeBootImageService`.** The plan's factory
signature omits it, but the contract requires the fake row to report the same
`GetImageInfo` answer as the real one.

**SPIKES numbered S11, not S10.** S10 is 05-03's media-loss entry; renumbering a
finding somebody may already have cited would be worse than a gap.

## Verification

| Check | Result |
|---|---|
| `pwsh -NoProfile -File ./build.ps1 -Task ci` | **exit 0** — 4694 passed, 0 failed, 54 skipped; lint 0 diagnostics across 328 files |
| `powershell.exe -NoProfile -File ./build.ps1 -Task test` | **exit 0** — 4549 passed, 0 failed, 199 skipped |
| `./build.ps1 -Task integration` (elevated) | **exit 0** — 98 passed, 0 failed, 18 skipped |
| `git log --oneline` | a `test(05-04)` before every `feat(05-04)` |
| DISM/oscdimg naming | only `New-HDTBootImageService.ps1` |
| No quote inside `-bootdata` | asserted, and the space refusal names SPIKES S2 |
| Equivalence hash | agrees three ways, checked by hand as well as by the suite |
| `Get-WindowsImage -Mounted` after the run | empty; ISO not attached; `git status` unchanged |

`./build.ps1 -Task e2e` **still cannot run**: `C:\HDTLab\media` is missing (SPIKES
S10, unchanged). Nothing in this plan needs it — this plan adds no e2e test — and
the e2e task's *other* precondition, which used to demand SPIKES S1/S3's
hand-built ISO, has been corrected to accept the ADK so 05-05 can build its own
boot vehicle.

## Lab safety

**No Hyper-V call of any kind.** `CM01` and `DC01` were never touched. Everything
written lives under `C:\HDTLab\scratch\bootimage\`, created by the code that
removes it; the artifacts are left for inspection and for 05-05. This host's
disk 0 was snapshotted before and asserted identical after, and
`git status --porcelain` is compared before and after so a build that scattered a
mount folder into the working tree would be caught.

## For 05-05

- The boot vehicle exists and this repository built it:
  `C:\HDTLab\scratch\bootimage\Share\Boot\HDTPE_x64.iso`, 550 916 096 bytes,
  UEFI, no keypress (`efisys_noprompt.bin`, SPIKES S3).
- `startnet.cmd` sets **`HDT_LAUNCHED_BY=startnet`**, which
  `Start-HDTDeployment.ps1` records into `RESULT.json`. **That is the field that
  proves nobody typed the command**, and it is the thing 05-05 exists to assert.
- The image carries a **volume-relative `deployRoot`** unchanged, so the VM
  discovers its content volume rather than being told a drive letter that would
  be wrong.
- Rebuild in **two minutes**, not fifteen. `-SkipIso` saves two seconds; do not
  reach for it.

## Self-Check: PASSED

Every file this document names exists on disk; every commit hash it cites is in
`git log`; every `min_lines` floor in the plan's `must_haves` is met
(`Update-HDTBootImage.ps1` 799 / 350, `New-HDTBootIso.ps1` 255 / 150,
`New-HDTBootImageService.ps1` 325 / 200,
`BootImage.Integration.Tests.ps1` 618 / 250). The three artifacts under
`C:\HDTLab\scratch\bootimage\Share\Boot\` are present at the sizes recorded
above.
