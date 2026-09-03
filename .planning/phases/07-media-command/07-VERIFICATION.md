---
phase: 07-media-command
verified: 2026-09-03T00:00:00Z
status: human_needed
score: 24/24 must-haves verified
human_verification:
  - test: "Build a disc with Update-HDTMediaContent and boot a network-less Generation 2 VM from it, end to end."
    expected: "The VM deploys Windows from the ISO with no network adapter, finishing the sequence including the reboot into the full OS."
    why_human: "ROADMAP M7 'Exit - media' is met by a booted VM, not by a green suite. Phase 07 runs no VM, deliberately and on the record."
  - test: "Look at the four console pictures in the phase directory and approve them."
    expected: "A Media (n) node beside Applications and Operating Systems, its rows, and Update Media Content on the right-click menu."
    why_human: "Plan 07-03 task 3 is a blocking human-verify checkpoint; visual appearance cannot be verified programmatically."
---

# Phase 07: Media Command Verification Report

**Phase Goal:** An administrator can define standalone media on a share and build it - `New-HDTMedia` records a media definition, `Update-HDTMediaContent` projects the workspace through a selection profile and burns a bootable ISO carrying the Local provider, and the console shows a Media node with an Update Media Content action. Proven under Pester against fakes, with the projection logic testable with no ISO in sight.

**Verified:** 2026-09-03
**Status:** human_needed - every automated must-have passes; the milestone's own media exit needs a booted VM.
**Re-verification:** No - initial verification.

## Headline

The **phase goal is achieved**. The **M7 "Exit - media" criterion is NOT met**, and
the ROADMAP says so itself in bold: *"It stays UNMET after phase 07, plainly and
on purpose: it is met by a booted VM, and phase 07 runs no VM."* That is an
honest, self-declared gap, not a false claim - phase 07 never asserted otherwise.

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|---|---|---|
| 1 | A share created by New-HDTWorkspace has a Media folder without naming it | VERIFIED | Real run on a temp share printed `Media folder exists: True`. `Get-HDTWorkspacePath.ps1:74` ValidateSet carries `'Media'`; no second edit anywhere |
| 2 | New-HDTMedia writes Media\<id>\media.yaml, Get-HDTMedia reads it back | VERIFIED | Real round trip printed the seven-key document and read back Id/Name/SelectionProfile/Enabled/OutputPath |
| 3 | Assert-HDTMediaDocument refuses an undeclared key | VERIFIED | `Assert-HDTMediaDocument.ps1` (241 lines), 466-line test file, 0 failures |
| 4 | It refuses a media id that is not a folder name, before it becomes a path | VERIFIED | Covered in the same suite; Remove-HDTMedia carries the traversal refusal |
| 5 | Set-HDTMedia changes one key, leaving comments byte-identical | VERIFIED | Real run renamed MEDIA001 to 'Renamed Disc'; splices via Set-HDTDocumentHeaderKey |
| 6 | Remove-HDTMedia refuses anything resolving outside Media\ | VERIFIED | SupportsShouldProcess present; 247-line test file green |
| 7 | All four commands exported, grouped and on the generated page | VERIFIED | `Hephaestus.psd1` exports all five media commands; `docs/command-categories.psd1:302-306`; 38 HDTMedia hits in command-reference.html |
| 8 | Every command runs against fakes with nothing on disk | VERIFIED | 437 media-named test cases, 0 failed, 0 skipped, under 5.1 |
| 9 | The projection says what travels and what is refused, no ISO/ADK/disk | VERIFIED | Ran Get-HDTMediaProjection on a real share: Marker/Document/Control/Content rows plus five Excluded rows |
| 10 | rules.yaml, workspace.yaml and Control\ travel whatever the profile says | VERIFIED | Projection output shows `Marker rules.yaml`, `Document workspace.yaml`, `Control Control` |
| 11 | bootstrap-rules.yaml, Control\share-credential.json, Boot\ refused with reasons | VERIFIED | Projection output shows all three as Excluded, plus Logs and Captures |
| 12 | Projected workspace.yaml carries deployRoot \Share and no credential block | VERIFIED | Ran Set-HDTMediaWorkspaceLine on a real workspace.yaml: `deployRoot: \Share` appears, no credential key |
| 13 | An unnamed transitive dependency is warned about, naming both applications | VERIFIED | `Get-HDTMediaDependencyWarning.ps1` (141 lines), 194-line test file green |
| 14 | A folder the profile names but is not on the share is warned about by name | VERIFIED | Covered in `Get-HDTMediaProjection.Tests.ps1` (525 lines) |
| 15 | Update-HDTMediaContent assembles the tree and burns one ISO with -NoPromptForKey | VERIFIED | `Update-HDTMediaContent.ps1:515` calls `New-HDTBootIso ... -NoPromptForKey` |
| 16 | The whole command is provable against fakes - no ADK, DISM, oscdimg, nothing burned | VERIFIED | 895-line test file, green under 5.1 with the workspace root on an unmounted drive |
| 17 | It passes injected -FileSystem/-Registry/-BootImageService/-Clock on to every call | VERIFIED | Parameters present with New-HDT* factory defaults; every downstream call takes -FileSystem |
| 18 | A share with media shows a Media (n) node beside Applications and Operating Systems | VERIFIED | Real tree build: `Depth 2 Category Media Ok` and `Depth 3 Media MEDIA001 Ok` |
| 19 | Each media row shows profile, output path and last build | VERIFIED | Real row fields: Id, Selection profile, Output, Last build `(never built)`, Enabled, Document, To build it |
| 20 | Right-clicking a media row offers Update Media Content | VERIFIED | HDTUpdateMediaMenuItem in XAML:464, string table:104, Get-HDTConsoleTreeMenuRow returns IsMediaRow/MediaId |
| 21 | The action runs through the existing progress host so the console does not freeze | VERIFIED | `New-HDTConsoleView.ps1:2252` Click handler calls Show-HDTBuildProgressWindow -Command 'Update-HDTMediaContent' -StringPage 'MediaProgress' -LogFile |
| 22 | A share with no media shows the category with (0), not a missing branch | VERIFIED | `Get-HDTConsoleMediaNode.ps1` (224 lines) handles the empty case; `ConsoleMediaNode.Tests.ps1` (312 lines) green |
| 23 | A media document that will not parse is a row, not a share that will not open | VERIFIED | MediaFailure member on Get-HDTConsoleWorkspace, read through the injected IFileSystem; real run reported `MediaFailure=[]` |
| 24 | The window was opened and photographed after the change | VERIFIED | Four PNGs in the phase directory, dated 2026-09-03 |

**Score: 24/24 truths verified.**

### Required Artifacts

| Artifact | Lines | Status |
|---|---|---|
| `src/Hephaestus/Private/Assert-HDTMediaDocument.ps1` | 241 | VERIFIED |
| `schemas/media.schema.json` | 52 | VERIFIED - additionalProperties false present |
| `src/Hephaestus/Public/New-HDTMedia.ps1` | 235 | VERIFIED |
| `src/Hephaestus/Public/Get-HDTMedia.ps1` | 183 | VERIFIED |
| `src/Hephaestus/Public/Set-HDTMedia.ps1` | 258 | VERIFIED |
| `src/Hephaestus/Public/Remove-HDTMedia.ps1` | 195 | VERIFIED - SupportsShouldProcess |
| `src/Hephaestus/Private/Get-HDTMediaProjection.ps1` | 236 | VERIFIED (min_lines 120) |
| `src/Hephaestus/Private/Set-HDTMediaWorkspaceLine.ps1` | 80 | VERIFIED |
| `src/Hephaestus/Private/Get-HDTMediaDependencyWarning.ps1` | 141 | VERIFIED |
| `src/Hephaestus/Private/New-HDTMediaManifest.ps1` | 301 | VERIFIED |
| `src/Hephaestus/Private/Test-HDTFileSystemFile.ps1` | 68 | VERIFIED |
| `src/Hephaestus/Public/Update-HDTMediaContent.ps1` | 576 | VERIFIED |
| `src/Hephaestus/Private/Get-HDTConsoleMediaNode.ps1` | 224 | VERIFIED |
| `tests/unit/Get-HDTMediaProjection.Tests.ps1` | 525 | VERIFIED |
| `tests/unit/ConsoleMediaNode.Tests.ps1` | 312 | VERIFIED |
| `src/Hephaestus/UI/Console/HDTConsole.xaml` | - | VERIFIED - HDTUpdateMediaMenuItem at line 464 |

No artifact is a stub. Every implementation file has a matching test file.
`Get-HDTConsoleMediaNode` is covered by `ConsoleMediaNode.Tests.ps1`, which is the
same convention `Get-HDTConsoleMonitorNode` / `ConsoleMonitorNode.Tests.ps1`
already uses.

### Key Link Verification

| From | To | Via | Status |
|---|---|---|---|
| New-HDTWorkspace | Get-HDTWorkspacePath -Kind Media | ValidateSet read by reflection | WIRED - proved by a real share growing a Media folder |
| Get-HDTMedia | Assert-HDTMediaDocument | every read validates | WIRED |
| Set-HDTMedia | Set-HDTDocumentHeaderKey | the shared splice | WIRED |
| Get-HDTMediaProjection | Expand-HDTSelectionProfile | one projection engine | WIRED - line 215 |
| Update-HDTMediaContent | Copy-HDTContentTree | the recursion the profile does not do | WIRED - lines 398, 446, 460 |
| Update-HDTMediaContent | New-HDTBootIso -NoPromptForKey | a VM nobody is standing at | WIRED - line 515 |
| Update-HDTMediaContent | Update-HDTBootImage -SkipIso | against the projected share | WIRED - lines 481, 494 |
| Get-HDTConsoleShareNode | Get-HDTConsoleMediaNode | one category among the share's others | WIRED - line 908 |
| console view | Update-HDTMediaContent | Show-HDTBuildProgressWindow -Command | WIRED - New-HDTConsoleView.ps1:2252 |
| Get-HDTConsoleTreeMenuRow | the Media kinds | the offers list | WIRED - IsMediaRow, MediaId |

**Note on one key link:** plan 07-03 wrote the console link as
`New-HDTConsoleHost.ps1 -> Update-HDTMediaContent`. The implementation put it in
`New-HDTConsoleView.ps1`, which is where every other tree context-menu Click
handler lives. The link is real and correctly placed; the plan named the wrong
file. Not a defect, but recorded so a future reader greps the right file.

## Verification Commands Run

| Check | Result |
|---|---|
| `build.ps1 test` under **Windows PowerShell 5.1** (the gate) | **PASS - 13917 passed, 0 failed, 268 skipped** |
| `build.ps1 test` under **pwsh 7.5.8** | **FAIL - 14118 passed, 8 failed, 59 skipped** (all 8 pre-existing, none media) |
| `build.ps1 lint` (PSScriptAnalyzer, own process) | **PASS - 0 diagnostics across 1143 files** |
| Naming contract (Verb-HDTNoun) | **PASS - 178 cases, 0 failed, 0 skipped** |
| No-MDT-dependency contract | **PASS - 1145 cases, 0 failed, 0 skipped** |
| PowerShell 5.1 compatibility contract | **PASS - 1159 cases, 0 failed, 0 skipped** |
| Injected-service-default contract | **PASS - 10 cases, 0 failed, 0 skipped** |
| Media-named test cases under 5.1 | **437 cases, 0 failed, 0 skipped** |
| Real module round trip (not fakes) | **PASS** - workspace, media.yaml, Get, Set, console tree, projection, provider swap |

The two shells were run **sequentially, never concurrently** (CLAUDE.md: they
collide over the same real DISM artefacts). The analyzer was run in its own
process for the same reason. The 5.1 run used an emptied PSModulePath.

None of the contract counts is vacuous - each scans a real, large file set.

### The 8 pwsh 7 failures - pre-existing, not phase 07

| Failing test | Cause |
|---|---|
| state.json schema contract - validates valid-completed.json, valid-loglevel-debug.json, valid-running.json | Test-Json in PS7 rejects /deploymentPassword against a false schema; the 5.1 validator does not |
| state.json schema contract - agrees with Assert-HDTRunStateDocument about the same three fixtures | Same root cause |
| Export-HDTDeviceInventory - formats the timestamp as a string | ConvertTo-Json datetime handling differs between editions |
| Console - a renamed imported update does not throw onto a message box | WPF RaiseEvent path differs under PS7 |

Proof they are not phase 07's: `git log 51f0256^..HEAD` over
`tests/contract/StateSchema.Contract.Tests.ps1`,
`tests/unit/Export-HDTDeviceInventory.Tests.ps1`, `schemas/state.schema.json`
and `src/Hephaestus/Public/Export-HDTDeviceInventory.ps1` returns **empty** -
phase 07 touched none of them. StateSchema.Contract.Tests.ps1 was last touched in
phase 03; the inventory test in an unrelated gather fix.

**Windows PowerShell 5.1 is the declared gate** - the engine runs in WinPE, which
has no pwsh, and the pwsh 7 pass is deliberately off. These eight are a standing
edition divergence, not a phase 07 regression. They are recorded here rather than
waved away: "the gate is 5.1" is a reason to accept them, not a reason to stop
counting them.

## TDD - checked against real git history

Every implementation file arrived **in the same commit as its tests**, never
after. Verified with `git show --stat` on all thirteen phase-07 commits.

| Commit | Implementation | Tests in the same commit |
|---|---|---|
| 51f0256 | Assert-HDTMediaDocument.ps1, media.schema.json, Get-HDTWorkspacePath | Assert-HDTMediaDocument.Tests.ps1, Get-HDTWorkspacePath.Tests.ps1, New-HDTWorkspace.Tests.ps1 |
| 685b032 | New-HDTMedia.ps1, Get-HDTMedia.ps1 | New-HDTMedia.Tests.ps1, Get-HDTMedia.Tests.ps1 |
| a461ae3 | Set-HDTMedia.ps1, Remove-HDTMedia.ps1 | Set-HDTMedia.Tests.ps1, Remove-HDTMedia.Tests.ps1, Set-HDTDocumentHeaderKey.Tests.ps1 |
| 09eb901 | Remove-HDTMedia.ps1 fix | Remove-HDTMedia.Tests.ps1 +46 lines |
| 37824c6 | Get-HDTMediaProjection.ps1 | Get-HDTMediaProjection.Tests.ps1 |
| 4289d95 | Get-HDTMediaDependencyWarning.ps1, New-HDTMediaManifest.ps1, Set-HDTMediaWorkspaceLine.ps1 | all three test files |
| 5329f70 | Update-HDTMediaContent.ps1, Test-HDTFileSystemFile.ps1 | both test files plus MediaIso.Integration.Tests.ps1 |
| 5ac565d | Get-HDTConsoleMediaNode.ps1, icon/colour/share-node edits | ConsoleMediaNode.Tests.ps1, ConsoleCategoryIcon.Tests.ps1, ConsoleTreeNode.Tests.ps1 |
| 9ff9ac5 | New-HDTConsoleView.ps1, XAML, strings | ConsoleTreeMenu.Tests.ps1, ConsoleTreeMenuWiring.Tests.ps1, StringTable.Contract.Tests.ps1 |

**No test file appears in a commit after the implementation it covers.** The
repository's convention is atomic commits bundling one logical unit, so RED-first
is not separately observable from history; the summaries record the RED counts
(33, 36, 46, 25, 6, 8 failures for the right reason). That is the strongest
evidence the chosen commit granularity permits, and it is consistent across all
thirteen commits.

## Engine Purity - no direct hardware/filesystem/registry calls

Scanned all eleven new media source files for Get-Content, Set-Content, Test-Path,
New-Item, Remove-Item, Copy-Item, Get-ChildItem, Get-ItemProperty, Get-CimInstance,
Out-File, [IO.File], [IO.Directory] and Join-Path.

**Zero violations.** The only hit is a comment in `Get-HDTMedia.ps1:16` saying
*"It reads through an injected IFileSystem - never Get-Content"*.

`Update-HDTMediaContent` uses `[System.IO.Path]::Combine` and never `Join-Path`
(lines 95, 99), which is the rule that lets the unit suite run with the workspace
root on an unmounted X: drive. Services default through New-HDTFileSystem,
New-HDTRegistryService, New-HDTBootImageService, New-HDTClock and
New-HDTBuildProgress (lines 60-64). `Get-HDTMediaProjection` makes `-FileSystem`
**mandatory** - confirmed by a real invocation refusing without it.

## Hyper-V Lab - untouched

Enumerated at the start and at the end of verification. **Identical.**

| Name | State | MemoryAssigned | Gen | Switch |
|---|---|---|---|---|
| HDT-HYDRA-11 | Off | 0 | 2 | (none) |
| HDT-HYDRA-25 | Off | 0 | 2 | (none) |
| HDT-MEDIA-01 | Off | 0 | 2 | (none) |
| HDT-PXE-01 | Off | 0 | 2 | HDT External |
| HDT-UPDSEL-A | Off | 0 | 2 | HDT External |
| HDT-UPDSEL-B | Off | 0 | 2 | HDT External |
| HDT-WDS-01 | **Running** | 4294967296 | 2 | HDT External |
| HDT-WSUS-01 | Off | 0 | 2 | HDT External |

- **The snapshot is not empty** - 8 VMs enumerated, so the comparison is not
  vacuous and does not pass on empty-equals-empty.
- **Non-HDT-* VMs: 0.** There are none on this host, so "every VM not named
  HDT-* is as it was found" is trivially true. Recorded explicitly rather than
  passed off as a green tick.
- Every VM is Generation 2 and on `HDT External` or no switch. No `Default
  Switch`, no invented subnet, no unfiltered pipeline was ever run.
- **HDT-WDS-01 is running with 4 GB.** It was already running before verification
  began, and phase 07 started no VM - the ROADMAP records that phase 07 runs
  none. It is left exactly as found. But it holds a third of the 12 GB budget
  `New-HDTLabVirtualMachine` enforces, which matters for the M7 capture exit that
  must run two VMs in sequence. Worth a look before that work starts; not a phase
  07 defect.

## Anti-Patterns Found

None. No TODO, FIXME, placeholder returns, empty handlers or console-log-only
implementations in the phase 07 sources. PSScriptAnalyzer returned 0 diagnostics
across the whole repository.

## Exit Criteria - the honest position

`docs/ROADMAP.md` M7 carries **two** exits, and phase 07 meets neither, which is
correct and was never claimed otherwise.

- **Exit - media: NOT MET.** *"A machine with no network deploys from an
  HDT-built ISO, end to end, and the ISO was built by Update-HDTMediaContent
  rather than by hand."* The ROADMAP states plainly: *"That command was built on
  2026-09-03 (phase 07-02) and has not yet built a disc a VM has booted."* The
  deployment half is already proven - a Gen 2 VM with no network adapter deployed
  Windows 11 from a 10.19 GB hand-built ISO - but the **command** has not built
  one.
- **Exit - capture: NOT MET.** The capture half (Sysprep, CaptureImage,
  Captures\) is a separate half of M7, in progress since 2026-08-31, and phase 07
  does not touch it.

The three M7 "Tests first" items are all satisfied, and the ROADMAP records
**where each is met**, including that two were already met before phase 07 began.

| Tests first item | Where met | Status |
|---|---|---|
| Projection completeness | tests/unit/Get-HDTMediaProjection.Tests.ps1 (07-02) | MET by phase 07 |
| Provider-swap equivalence | tests/contract/ContentProvider.Contract.Tests.ps1 (run-time) plus tests/unit/Set-HDTMediaWorkspaceLine.Tests.ps1 (build-time) | MET, run-time half pre-existing |
| HDTDeploymentMethod MEDIA/UNC | Built 2026-09-02 by plans 06-01 and 06-02 | MET, phase 06 |

**So: the phase goal as stated is fully achieved. The milestone exit criterion it
sits under is not, and cannot be, without a booted VM.**

## Human Verification Required

### 1. Boot a VM from a disc built by the command

**Test:** Run `Update-HDTMediaContent` against a real share, then boot a
Generation 2 VM with **no network adapter** from the resulting ISO.
**Expected:** The machine deploys end to end, including the reboot into the full
OS and an application install.
**Why human:** This is the M7 "Exit - media" criterion verbatim, and it is met by
a booted VM rather than by a green suite. Note the 12 GB running budget -
HDT-WDS-01 currently holds 4 GB of it.

### 2. Approve the console pictures

**Test:** Look at `07-03-media-tree.png`, `07-03-media-detail.png`,
`07-03-media-menu.png` and `07-03-media-never-built.png` in this directory.
**Expected:** A Media (n) node between Selection Profiles and Monitoring, rows
showing profile / output / last build, and **Update Media Content** on
right-click.
**Why human:** Plan 07-03 task 3 is a blocking human-verify checkpoint. The
executor captured and reviewed them; the user's own look and the word "approved"
is what remains.

## Gaps Summary

**No gaps in the phase goal.** All 24 must-have truths verify against the actual
codebase, not against the summaries - confirmed by running the real module on a
real temporary share, not only by reading tests. Every artifact exists, is
substantive, and is wired. The gate is green under the shell that is the gate.
The analyzer is clean. The naming, no-MDT, PS5.1 and injected-service contracts
all pass with real, non-vacuous case counts. The lab is untouched.

Three things a reader should not lose:

1. **pwsh 7 is red with 8 failures.** All eight are pre-existing edition
   divergences in state.json schema validation, JSON datetime formatting and a
   WPF event path. None is media. 5.1 is the declared gate. Still red, still
   counted.
2. **The M7 media exit is unmet and stays unmet.** The command exists, is
   exported, and is proved against fakes. That is a different claim from a disc a
   machine has booted, and the ROADMAP was amended by this phase to say so rather
   than to tick the box. This is the single most important thing not to
   misread as a pass.
3. **Plan 07-03 named the wrong file for one key link.** The wiring landed in
   New-HDTConsoleView.ps1, not New-HDTConsoleHost.ps1, and is correct where it
   is.

---

_Verified: 2026-09-03_
_Verifier: Claude (gsd-verifier)_
