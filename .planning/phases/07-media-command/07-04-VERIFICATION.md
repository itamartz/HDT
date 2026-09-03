---
phase: 07-04
verified: 2026-09-03T18:40:00Z
status: passed
score: 12/12 must-haves verified
---

# Phase 07-04: New Media / Remove Media on the Console Verification Report

**Phase Goal:** Close the deliberate deferral from phase 07-03 by wiring New
Media and Remove Media into the console's right-click tree menu - a New Media
dialog (id, name, selection profile, output path) off the Media category, a
Remove Media confirmation off a media item row, both wired through
Get-HDTConsoleTreeMenuRow.ps1 and New-HDTConsoleView.ps1, plus the deferral
language corrected in docs/DESIGN.md and docs/ROADMAP.md.

**Verified:** 2026-09-03
**Status:** passed
**Re-verification:** No - initial verification (no prior 07-04-VERIFICATION.md existed).

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|---|---|---|
| 1 | Right-clicking the Media category offers New Media, never on a media item, never with markup missing | VERIFIED | ConsoleTreeMenuWiring.Tests.ps1 "right-clicking the media rows to create one" - 3/3 assertions green |
| 2 | New Media opens a dialog asking for id, name, a selection profile from this share, and where the ISO goes | VERIFIED | HDTNewMedia.xaml has the four fields; rendered picture 07-04-02-new-media-dialog.png shows them plus the command-preview line |
| 3 | Create stays dark until the id is legal and unused | VERIFIED | Test-HDTConsoleNewMedia / Get-HDTConsoleNewMedia tests cover empty id, illegal id, empty name, duplicate media.yaml - 16/16 green |
| 4 | Pressing Create writes through New-HDTMedia and the tree shows it without reopening the share | VERIFIED | 07-04-02-tree-after-create.png shows Media (4) after Create with no share reopen |
| 5 | Cancel writes nothing | VERIFIED | No write path outside the Create click handler; IsCancel button pattern unchanged from New Task Sequence |
| 6 | The command-preview line is the exact New-HDTMedia line Create would run | VERIFIED | Get-HDTConsoleNewMediaCommand tests assert composition and -Output omission when blank; picture matches |
| 7 | Right-clicking a media item offers Remove Media; the category never does | VERIFIED | ConsoleTreeMenuWiring.Tests.ps1 "right-clicking the media rows to remove one"; menu pictures show correct asymmetry |
| 8 | Removing asks first, names what goes with it, names an ISO left outside the folder when applicable | VERIFIED | Get-HDTConsoleRemoval.ps1 Media case + IsoLeftBehind composed in click handler; confirm picture shows exact wording |
| 9 | Confirming runs Remove-HDTMedia and the row disappears without reopening the share; Cancelling removes nothing | VERIFIED | removeMedia.Add_Click mirrors removeApplication.Add_Click; live probe created and removed CONSOLE-PROBE, ending at the pre-existing 3 items |
| 10 | DESIGN.md 6.2.3, ROADMAP.md M7, and the two source comments no longer call this a deferral | VERIFIED | grep for the deferral phrase across docs and both source files returns nothing (checked independently below) |
| 11 | command-reference.html / command-categories.psd1 need no console-specific correction | VERIFIED | command-categories.psd1 lines 302-306 already list all five HDTMedia commands; command-reference.html has 13 New-/Remove-HDTMedia hits |
| 12 | The window was opened and photographed after the change | VERIFIED | 5 PNGs dated 2026-09-03, viewed directly by this verification, both dialogs render correctly with real data from the real share |

**Score: 12/12 truths verified.**

### Required Artifacts

| Artifact | Status | Details |
|---|---|---|
| src/Hephaestus/UI/Console/HDTNewMedia.xaml | VERIFIED | 213 lines added in commit 31f2a65; contains HDTNewMediaCreateButton |
| src/Hephaestus/Private/Get-HDTConsoleNewMedia.ps1 | VERIFIED | Forwards -FileSystem to Get-HDTSelectionProfile |
| src/Hephaestus/Private/Test-HDTConsoleNewMedia.ps1 | VERIFIED | Mirrors New-HDTMedia's own id regex |
| src/Hephaestus/Private/Get-HDTConsoleNewMediaCommand.ps1 | VERIFIED | Composes exact New-HDTMedia line, omits -Output when blank |
| src/Hephaestus/Private/Get-HDTConsoleRemoval.ps1 | VERIFIED | Media added to -Kind ValidateSet with its own case (line 195) |
| src/Hephaestus/Private/New-HDTConsoleView.ps1 | VERIFIED | -NewMediaXaml param, newMedia/removeMedia gating, both click handlers, IsoLeftBehind composition |
| src/Hephaestus/Public/New-HDTConsoleHost.ps1 | VERIFIED | ShowNewMedia ScriptMethod |
| src/Hephaestus/Public/Show-HDTConsole.ps1 | VERIFIED | -NewMediaXamlPath plumbing |
| src/Hephaestus/UI/Console/HDTConsole.xaml | VERIFIED | HDTNewMediaMenuItem, HDTRemoveMediaMenuItem present |
| src/Hephaestus/Strings/en-us.psd1 | VERIFIED | NewMedia page and menu headers; StringTable.Contract.Tests.ps1 green |
| docs/DESIGN.md | VERIFIED | Line 1940 amended, names both dialogs/commands and the item/category asymmetry |
| docs/ROADMAP.md | VERIFIED | Line 772 amended, dated, names phases 07-04-01/07-04-02 |
| tests/unit/Get-HDTConsoleNewMedia.Tests.ps1 | VERIFIED | 16/16 passing, 3 Describe blocks |
| tests/unit/ConsoleRemoval.Tests.ps1 | VERIFIED | New media-definition Context green |
| tests/unit/ConsoleTreeMenuWiring.Tests.ps1 | VERIFIED | New Describe blocks for create-row and remove-row menus green |

No artifact is a stub; every implementation file has a matching test committed
in the same commit as the implementation (TDD - see below).

### Key Link Verification

| From | To | Via | Status |
|---|---|---|---|
| New-HDTConsoleView.ps1 | New-HDTConsoleHost.ShowNewMedia | Create click on Media category, gated by -NewMediaXaml | WIRED |
| New-HDTConsoleHost.ps1 | New-HDTMedia | dialog's own Create button inside ShowNewMedia | WIRED |
| Show-HDTConsole.ps1 | HDTNewMedia.xaml | -NewMediaXamlPath, read and forwarded | WIRED |
| New-HDTConsoleView.ps1 | Remove-HDTMedia | Get-HDTConsoleRemoval -Kind Media, -WhatIf preflight, MessageBox | WIRED |
| docs/DESIGN.md | shipped New/Remove Media | amended 6.2.3 note | WIRED (amended, matches shipped commands and asymmetry) |

### TDD Verification (git history, checked directly)

| Commit | Contents |
|---|---|
| 84eba51 | Get-HDTConsoleNewMedia.Tests.ps1 (201 lines) plus 3 new production files, same commit |
| 31f2a65 | ConsoleTreeMenuWiring.Tests.ps1 extension (+81) plus HDTNewMedia.xaml, New-HDTConsoleHost.ps1, New-HDTConsoleView.ps1, Show-HDTConsole.ps1, HDTConsole.xaml, en-us.psd1, same commit |
| ca176e0 | ConsoleRemoval.Tests.ps1 (+44) plus ConsoleTreeMenuWiring.Tests.ps1 (+57) plus Get-HDTConsoleRemoval.ps1, New-HDTConsoleView.ps1, HDTConsole.xaml, en-us.psd1, same commit |

Tests and implementation land together in every commit; no case of
implementation preceding its test in a separate commit.

### Requirements Coverage

No REQUIREMENTS.md entry maps specifically to 07-04; the phase is scoped by
ROADMAP.md's M7 media console note, covered above.

### Anti-Patterns Found

None. Grep for TODO/FIXME/placeholder/console-log-only patterns in the new
files returned nothing. Test-HDTConsoleNewMedia performs real refusal logic,
not a stub. ShowNewMedia and removeMedia.Add_Click both call the real engine
commands, not a placeholder.

### Full Gate (run directly, not taken from SUMMARY)

build.ps1 test result: 13965 passed, 0 failed, 268 skipped, Windows
PowerShell 5.1.26100.8655.

build.ps1 lint result: 0 diagnostics across 1148 files.

Both run in separate processes under Windows PowerShell 5.1 only (the gate;
pwsh 7 pass intentionally not run).

Targeted suites also run directly and independently confirmed green:
Get-HDTConsoleNewMedia.Tests.ps1, ConsoleRemoval.Tests.ps1,
ConsoleTreeMenuWiring.Tests.ps1, StringTable.Contract.Tests.ps1,
ConsoleSurface.Contract.Tests.ps1 - 252 passed, 0 failed.

Naming.Contract.Tests.ps1 and NoMdtDependency.Contract.Tests.ps1 both present
and green (1156 passed total in that combined run), confirming the
Verb-HDTNoun naming contract and zero-MDT-dependency contract both cover this
phase's new commands.

### Engine/Hardware Boundary

The new console-side files (Get-HDTConsoleNewMedia.ps1,
Test-HDTConsoleNewMedia.ps1, Get-HDTConsoleNewMediaCommand.ps1) contain no
direct filesystem/registry/CIM calls - checked directly, no New-Item,
Get-Content, Set-Content, Get-ChildItem, Test-Path, System.IO, or
Get-CimInstance hits. They forward an injected -FileSystem to
Get-HDTSelectionProfile. This is console UI code, not engine step code, so the
injected-service rule applies at the level these files actually touch; the
engine commands they call (New-HDTMedia, Remove-HDTMedia) already carry the
injected-service pattern from phase 07-01, unchanged by this phase.

### Hyper-V Lab State

Enumerated the full VM set on this host: HDT-HYDRA-11, HDT-HYDRA-25,
HDT-MEDIA-01, HDT-PXE-01, HDT-UPDSEL-A, HDT-UPDSEL-B, HDT-WDS-01,
HDT-WSUS-01 - all 8 match the HDT- prefix, all Off except HDT-WDS-01
(Running, pre-existing state unrelated to this phase). This phase is
console-only; neither plan nor either SUMMARY records any VM work, and no VM
was created, removed, or changed by 07-04-01 or 07-04-02. Non-empty snapshot,
not an empty-equals-empty pass.

### Human Verification Required

None outstanding. The plan's own blocking checkpoint:human-verify (Task 3 of
07-04-02) was completed, and its five pictures were reviewed directly as part
of this verification: the New Media dialog fields and command-preview line
match the plan's four-field requirement; the category menu shows New Media
without Remove Media; the item menu shows Remove Media; the confirmation
names the item, the share, and what goes with it, with no undo. All match the
plan's own how-to-verify checklist.

### Workspace Share Check

C:\HDTLab\Share was not spliced - this phase is console-only. The live probe
in 07-04-02's SUMMARY created and removed a CONSOLE-PROBE media item against
the real share for the photographs, ending with exactly the pre-existing
HYDRATION-USB, WIN11-FIELD, HYDRA media items - confirmed in the picture
sequence (Media (3) before, Media (4) after Create). No file under
src/Hephaestus/Templates/ was touched by this phase (not in either plan's
files_modified list, confirmed).

### Gaps Summary

None. Every truth this phase set out to prove - New Media reachable only from
the category, Remove Media reachable only from the item, both refusing what
the underlying engine commands would refuse, the four deferral-language spots
corrected, the console-generated surfaces checked and confirmed to need no
change, and the photographs taken against the real lab share - is verified
directly against the repository, not merely asserted by the executor's
SUMMARY.

The working tree at verification time carried unrelated modifications (edits
to 06-*/07-01/02/03 PLAN.md files, docs/command-reference.html, an untracked
.planning/RECOMMENDATIONS-2026-09-02.md, and an untracked
07-04-02-PLAN.md) - these are concurrent-session artifacts outside this
phase's files_modified lists in both 07-04-01-PLAN.md and 07-04-02-PLAN.md,
and were left untouched by this verification.

---

*Verified: 2026-09-03*
*Verifier: Claude (gsd-verifier)*
