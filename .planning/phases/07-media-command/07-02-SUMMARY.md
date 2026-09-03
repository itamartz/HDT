---
phase: 07-media-command
plan: 02
subsystem: transport-media
tags: [media, projection, provider-swap, iso, selection-profile]

requires:
  - Expand-HDTSelectionProfile
  - Copy-HDTContentTree
  - Set-HDTWorkspaceKey
  - Resolve-HDTApplicationOrder
  - Update-HDTBootImage
  - New-HDTBootIso
  - Get-HDTMedia
provides:
  - Update-HDTMediaContent
  - Get-HDTMediaProjection
  - Set-HDTMediaWorkspaceLine
  - Get-HDTMediaDependencyWarning
  - New-HDTMediaManifest
  - Test-HDTFileSystemFile
affects:
  - Copy-HDTContentTree
  - docs/DESIGN.md
  - docs/ROADMAP.md
  - docs/command-reference.html

tech-stack:
  added: []
  patterns:
    - "The projection is a list of rows, not a copy - so completeness is provable in milliseconds"
    - "The provider is derived from deployRoot, never configured"
    - "Every injected service is passed on to every command in the chain"

key-files:
  created:
    - src/Hephaestus/Private/Get-HDTMediaProjection.ps1
    - src/Hephaestus/Private/Set-HDTMediaWorkspaceLine.ps1
    - src/Hephaestus/Private/Get-HDTMediaDependencyWarning.ps1
    - src/Hephaestus/Private/New-HDTMediaManifest.ps1
    - src/Hephaestus/Private/Test-HDTFileSystemFile.ps1
    - src/Hephaestus/Public/Update-HDTMediaContent.ps1
    - tests/unit/Get-HDTMediaProjection.Tests.ps1
    - tests/unit/Set-HDTMediaWorkspaceLine.Tests.ps1
    - tests/unit/Get-HDTMediaDependencyWarning.Tests.ps1
    - tests/unit/New-HDTMediaManifest.Tests.ps1
    - tests/unit/Test-HDTFileSystemFile.Tests.ps1
    - tests/unit/Update-HDTMediaContent.Tests.ps1
    - tests/integration/MediaIso.Integration.Tests.ps1
  modified:
    - src/Hephaestus/Private/Copy-HDTContentTree.ps1
    - src/Hephaestus/Hephaestus.psd1
    - docs/command-categories.psd1
    - docs/command-reference.html
    - docs/DESIGN.md
    - docs/ROADMAP.md

decisions:
  - "The excluded-folder filter was removed from Get-HDTMediaProjection as unreachable: Get-HDTSelectionProfile validates on read, so a profile naming Boot is refused upstream"
  - "Test-HDTFileSystemFile extracted from Copy-HDTContentTree rather than duplicated"
  - "Update-HDTMediaContent takes -EngineModulePath and -YamlModulePath, which the plan did not list, because Update-HDTBootImage needs them and defaults them to real paths"
  - "ROADMAP M7 Exit - media recorded as STILL UNMET: it is met by a booted VM, and this plan runs none"

metrics:
  tasks: 3
  commits: 4
  completed: 2026-09-03
---

# Phase 07 Plan 02: Update-HDTMediaContent Summary

**`Update-HDTMediaContent` builds a standalone disc from a media definition —
a content projection plus a provider swap, with no second projection engine and
no ADK, DISM or oscdimg reached in any unit test.**

## What was built

| Piece | What it is |
|---|---|
| `Get-HDTMediaProjection` | The correctness heart, and it is PURE. One row per thing that travels, one per thing refused. Copies nothing, creates nothing. |
| `Set-HDTMediaWorkspaceLine` | The provider swap: `deployRoot: \Share` and the `credential:` block gone, two `Set-HDTWorkspaceKey` splices, no new splice code. |
| `Get-HDTMediaDependencyWarning` | The sentence naming BOTH applications. Warns, does not fix. Fails soft where `Resolve-HDTApplicationOrder` throws. |
| `New-HDTMediaManifest` | `New-HDTBootImageManifest`'s shape, both of its traps included. Carries no credential — there is no parameter for one. |
| `Test-HDTFileSystemFile` | `Copy-HDTContentTree`'s inline try/catch, lifted out and now shared. |
| `Update-HDTMediaContent` | The build. Twelve steps, `SupportsShouldProcess`, all services injected. |

## The exact ordered operation list, as shipped

Asserted element by element in `tests/unit/Update-HDTMediaContent.Tests.ps1`,
projected off the shared journal (DESIGN 12.2.1):

```
ReadMediaDocument
ImportWorkspaceDocument
ProjectShare
ReadApplicationCatalog
PrepareScratch
ResolveAdkPath
CreateMediaSources
ProjectContent
WriteProjectedWorkspace
ResolveAdkPath           <- Update-HDTBootImage resolves its own
MountBootImage
ExportBootImage
MoveWimToMedia
RemoveProjectedBoot
ResolveAdkPath           <- New-HDTBootIso resolves its own
NewIso
PublishIso
WriteManifest
```

**Eighteen milestones, twelve reported steps.** The step count is the command's
own (`$stepTotal = 12`); the boot image reports its seventeen through the same
sink, which is why the progress test filters on `Total`.

The three `ResolveAdkPath` entries are not a defect. `Update-HDTBootImage` and
`New-HDTBootIso` are commands in their own right and resolve the ADK themselves
rather than being handed paths by a caller they do not require — the boot image
suite already records the same thing about the second one.

## The projection, as an exact list

For `everything` on a full share, twice-asserted in
`tests/unit/Get-HDTMediaProjection.Tests.ps1`:

```
Marker:rules.yaml
Document:workspace.yaml
Control:Control
Excluded:Control\share-credential.json
Content:Applications
Content:OperatingSystems
Content:Drivers
Content:TaskSequences
Content:Scripts
Excluded:bootstrap-rules.yaml
Excluded:Boot
Excluded:Logs
Excluded:Captures
```

Row shape: `Kind`, `Source`, `FullPath`, `Destination`, `Reason`, `Present`,
`Rewritten`.

## The returned object — plan 03 puts this on screen

```
Id                [string]            the media definition's id
IsoPath           [string]            where the ISO was published
IsoSizeBytes      [long]
IsoSha256         [string]
BootWimSha256     [string]            sources\boot.wim's hash
SelectionProfile  [string]
Projected         [pscustomobject[]]  the rows that travelled
Excluded          [pscustomobject[]]  the rows refused, each with its Reason
Warning           [string[]]          missing folders and missing dependencies
ManifestPath      [string]
```

Under `-WhatIf` the same shape comes back with the artifact fields empty and
`Projected`/`Excluded`/`Warning` populated — which is what makes `-WhatIf` the
pass worth running first: it is where the warnings are, without the ten minutes.

## Nothing in `Set-HDTWorkspaceKey` or `Update-HDTBootImage` had to change

Both did exactly what their headers said. `Set-HDTWorkspaceKey` removed the
`credential:` block with its last key, as documented; `Update-HDTBootImage`
derived `Local` from the projected `deployRoot` with no media flag threaded
through it. `Copy-HDTContentTree` changed only to call the extracted
`Test-HDTFileSystemFile`; its own suite stayed green.

## Deviations from plan

### 1. The in-projection refusal filter was removed as unreachable

**Found during:** Task 1, on the first GREEN run.

`Get-HDTSelectionProfile` validates the document **on read**, and
`Assert-HDTSelectionProfileDocument` allows only
`Get-HDTSelectionProfileContentFolder`'s five folders as an include's first
segment. So a profile naming `Boot` is refused by name — quoting the folder —
before any projection is asked for, and the `It 'refuses them even when a
profile tries to include one'` the plan specified could not be written: the
seeded document poisoned every other test in the file, because one illegal
include refuses the whole document.

The filter in `Get-HDTMediaProjection` was therefore dead code. It was removed
and replaced by a header paragraph saying where the real refusal lives, plus two
tests: one asserting the upstream refusal by message, one asserting the `Boot`
Excluded row is there for every profile including the built-ins.

**Why this is the right call and not a weakening:** a second filter for a case
that cannot arrive would read as the guarantee while the real one lived
elsewhere, and no test could reach it.

### 2. `-EngineModulePath` and `-YamlModulePath` added to the signature

**Found during:** Task 3.

The plan's signature did not list them, but `Update-HDTBootImage` requires both
and defaults `-EngineModulePath` to `$script:HDTModuleRoot` — the real module
directory on disk. Without forwarding them, the unit suite's boot image build
would have read the real module tree through the fake filesystem. They default
exactly as `Update-HDTBootImage`'s do.

### 3. `Test-HDTFileSystemFile` extracted

**Found during:** Task 3. `Control\` travels minus `share-credential.json`, so
its children have to be classified file-or-directory — the same question
`Copy-HDTContentTree` answered with an inline `try`/`catch` on `GetLength`. Two
copies of a try/catch that reads like a bug would not survive the first tidy-up,
so it was lifted out, given its own RED-first suite, and `Copy-HDTContentTree`
now calls it.

### 4. Four test-side corrections during Task 3's GREEN

None changed a claim, all changed how it was proved:

- the staging tree is removed in the `finally`, so assertions that inspected it
  after the build had to read the journal instead;
- the default test build passes **no** `-AdkRoot`, so the ADK is resolved through
  the injected registry — a stronger statement of "no ADK need be installed"
  than an explicit root, which bypasses the registry entirely;
- `Should -Not -Throw` runs its scriptblock in a child scope, so an assignment
  inside it does not reach the enclosing one (two fail-soft tests);
- a `[string[]]` test helper needs `[AllowEmptyString()]` for a document with
  blank lines in it.

### 5. Two defects found by the gate and fixed

- `docs/DESIGN.md` carried **three raw backspace characters**, from a `\b` in the
  generator script that wrote the section. This is precisely the defect
  `AuthoredFileHygiene.Contract.Tests.ps1` exists for, and it found it. The tree
  now scans clean for every control character other than tab, CR and LF.
- The second `.EXAMPLE` on `Update-HDTMediaContent` named `$root`, a variable the
  example never assigned. `ExampleQuality.Contract.Tests.ps1` refused it.

### 6. Bugs found in my own code by its tests

- `.Split('\', '/')` binds to `Split(char, int)` in PowerShell and tried to read
  `/` as a count. Fixed with an explicit `[char[]]`.
- `& $scriptblock` enumerates its result into the pipeline, so a one-row
  projection arrived at the manifest as a scalar and serialised as an object —
  which is the exact defect `New-HDTMediaManifest`'s own array guard threw on.
  Fixed by wrapping at the assignment.

## ROADMAP M7 — four edits, not one bullet

1. **Heading and deferral quote.** `MEDIA DEFERRED TO v2` became
   `MEDIA COMMANDS BUILT, MEDIA EXIT UNMET`; the quote saying "`New-HDTMedia`
   stays deferred" was **amended with the date rather than deleted**, following
   the `HDTDeploymentMethod` block's worked example.
2. **The `New-HDTMedia` bullet** is now two commands — the definition and the
   build — which is MDT's split and what §6.2 implements.
3. **"Exit — media"** now names `Update-HDTMediaContent` (the criterion named a
   command that does not build anything, so it could have been ticked on the
   wrong evidence) and is recorded **NOT MET**, plainly: it is met by a booted
   VM, and this plan runs none.
4. **"Tests first"** became a table recording where each item is met. Two of the
   three were **already met before this phase**: provider-swap equivalence by
   `tests/contract/ContentProvider.Contract.Tests.ps1` (the run-time half; the
   build-time half is `Set-HDTMediaWorkspaceLine`'s suite), and
   `HDTDeploymentMethod` by plans 06-01/06-02. The projection-completeness
   wording was amended from "sequence" to "selection profile", because DESIGN
   §6.2 settles that and the design is authoritative.

## Verification

| Suite | Result |
|---|---|
| `tests/unit/Get-HDTMediaProjection.Tests.ps1` | 34 passed |
| `tests/unit/Set-HDTMediaWorkspaceLine.Tests.ps1` + 2 others | 36 passed |
| `tests/unit/Test-HDTFileSystemFile.Tests.ps1` + `Copy-HDTContentTree` | 16 passed |
| `tests/unit/Update-HDTMediaContent.Tests.ps1` | 48 passed |
| `tests/integration/MediaIso.Integration.Tests.ps1` | 4 passed against **real oscdimg** |
| `./build.ps1 test` (Windows PowerShell 5.1) | see below |

Every task was RED first and verified for the right reason: 33, 36, 5 and 48
`CommandNotFoundException` failures respectively.

**No test in this plan builds a real ISO from a real share, mounts an image,
starts a VM or touches Hyper-V.** The integration file burns a tiny tree in a
directory it creates under `C:\HDTLab\scratch\HDT-media-iso-*`, removes it by
explicit `-LiteralPath` behind a name guard, and skips itself without an ADK.
