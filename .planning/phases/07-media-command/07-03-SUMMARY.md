---
phase: 07-media-command
plan: 03
subsystem: console
tags: [console, media, wpf, tree, context-menu]
requires:
  - Get-HDTMedia, New-HDTMedia, Remove-HDTMedia (07-01)
  - Update-HDTMediaContent (07-02)
  - Show-HDTBuildProgressWindow -Command/-Argument/-StringPage/-LogFile
provides:
  - Get-HDTConsoleMediaNode - the Media category and its item rows
  - Workspace.Media / Workspace.MediaFailure on Get-HDTConsoleWorkspace
  - Kind 'Media' in the icon, colour, node and menu-row surfaces
  - HDTUpdateMediaMenuItem and the MediaProgress string page
affects:
  - Get-HDTConsoleShareNode - a ninth category between Selection Profiles and Monitoring
  - Get-HDTConsoleTreeMenuRow - IsMediaRow and MediaId
  - New-HDTConsoleView - the menu guard and one Click handler
tech-stack:
  added: []
  patterns:
    - the category builder in its own file, as Get-HDTConsoleMonitorNode is
    - the progress window taking a command NAME and a plain hashtable
key-files:
  created:
    - src/Hephaestus/Private/Get-HDTConsoleMediaNode.ps1
    - tests/unit/ConsoleMediaNode.Tests.ps1
  modified:
    - src/Hephaestus/Private/Get-HDTConsoleIcon.ps1
    - src/Hephaestus/Private/Get-HDTConsoleIconColor.ps1
    - src/Hephaestus/Private/New-HDTConsoleNode.ps1
    - src/Hephaestus/Private/Get-HDTConsoleWorkspace.ps1
    - src/Hephaestus/Private/Get-HDTConsoleShareNode.ps1
    - src/Hephaestus/Private/Get-HDTConsoleTreeMenuRow.ps1
    - src/Hephaestus/Private/New-HDTConsoleView.ps1
    - src/Hephaestus/UI/Console/HDTConsole.xaml
    - src/Hephaestus/Strings/en-us.psd1
    - docs/DESIGN.md (6.2.3)
    - docs/ROADMAP.md (M7)
    - tests/unit/ConsoleCategoryIcon.Tests.ps1
    - tests/unit/ConsoleTreeNode.Tests.ps1
    - tests/unit/ConsoleTreeMenu.Tests.ps1
    - tests/unit/ConsoleTreeMenuWiring.Tests.ps1
    - tests/contract/StringTable.Contract.Tests.ps1
decisions:
  - A briefcase, not an optical disc - OperatingSystem already wears the disc
  - Media sits between Selection Profiles and Monitoring, not among the content categories
  - New Media and Remove Media are deliberately off the menu in this phase
  - The category is disabled with its reason when the share has several media, hidden when it has none
metrics:
  tasks: 3
  commits: 3
  duration: ~2h45m
  completed: 2026-09-03
---

# Phase 07 Plan 03: Media in the console Summary

MDT's Media node put on screen: a `Media (n)` category with its rows, and
**Update Media Content** running `Update-HDTMediaContent` through the progress
window the boot image build already uses.

## What was built

**`Get-HDTConsoleMediaNode`** — its own file, modelled on
`Get-HDTConsoleMonitorNode`. It returns the category with its rows already in
`.Children`, and `Get-HDTConsoleShareNode` adds both to the flat reading and to
the parent's `Children` in one pass, which is the rule that file writes down
about itself.

**The row answers the three questions somebody opens the branch to ask** —
which selection profile, where the ISO goes, and when it was last built — plus
the id, whether it is enabled, the document and the command to run. `Last build`
shows `(never built)` in words when there is no manifest beside the document,
which is precisely the state in which the action on the row is the one wanted.

**`Get-HDTConsoleWorkspace` reads the media through the injected
`IFileSystem`.** `Get-HDTMedia` defaults that parameter to the real adapter, so
leaving it off would have been silent: the console would read this laptop's disk
while a test seeded a fake, and every assertion about the branch would have been
about `C:\` rather than about the fixture.

**`Update Media Content` is four lines of dispatch and no new machinery.**
`Show-HDTBuildProgressWindow` already takes a command NAME and a plain
hashtable — both deliberately, because they cross a runspace boundary — so this
plan wrote no runspace code at all.

## The pictures

Taken against the real lab share with a real STA probe under Windows PowerShell
5.1, `RenderOptions.ProcessRenderMode = 'SoftwareOnly'`, the tree handed its
roots (`Depth -eq 0`) and not the flat list.

| Picture | What it shows |
|---|---|
| `07-03-media-tree.png` | `Media (2)` between Selection Profiles and Monitoring, wearing a briefcase no other category wears |
| `07-03-media-detail.png` | a built media selected: profile `hydration`, the ISO path, `2026-09-01 19:42:08 UTC (6.0 GB)` |
| `07-03-media-never-built.png` | the other one: `Last build` reads `(never built)`, not a blank and not a zero date |
| `07-03-media-menu.png` | the right-click menu open on a media row with one enabled item on it, spelled **Update Media Content** |

The third one **cannot be `PrintWindow`**. A `ContextMenu` is a `Popup` in its
own top-level window, so `PrintWindow` on the console captures the tree with no
menu on it — which is exactly what a broken menu looks like. That one is read off
the screen instead, which is the only capture that includes a popup.

## Decisions

**1. A briefcase, and deliberately not a disc.** The obvious picture for a node
that burns an ISO is an optical disc, and `OperatingSystem` already has it. Two
rows under one share wearing the same picture is the defect that table was
rewritten to remove, and an operating system and a disc built *from* one are the
two rows most worth telling apart. A briefcase says what the node is for:
standalone media is the share **packed to travel**, carried to a site with no
network.

**2. Media sits beside the selection profiles, not among the content
categories.** A media definition **is** a selection profile pointed at a disc —
MDT puts both under Advanced Configuration — so it goes after Selection Profiles
and before Monitoring, which stays last because it is the share in use rather
than another thing to build. It takes the profiles' violet for the same reason:
the palette says where a thing came from, and both are authored here.

**3. Both media rows offer the action**, which is the boot image rows' rule. The
category resolves to the **only** media when there is exactly one. With several
it is **shown disabled with the reason on its tooltip** — naming an ambiguous
target is the one thing this console does not do — and with none it is not shown
at all, since there is then nothing it could ever name. That last case is where
the plan's own wording pulled two ways (design note 2 said "disabled otherwise",
the test list said "does not offer it"); the split above satisfies both readings
and is the one that matches the update store's rule that an item which can only
answer no is worse than no item.

**4. New Media and Remove Media are NOT on the menu.** They are `New-HDTMedia`
and `Remove-HDTMedia` at a prompt in this phase. **This is a deferral, not an
oversight** — recorded here, in `Get-HDTConsoleTreeMenuRow`'s comment and in the
markup, because an unexplained gap between the command set and the menu reads as
a half-feature.

## Deviations from Plan

**1. [Rule 3 - Blocking] The handler went into `New-HDTConsoleView.ps1`, not
`New-HDTConsoleHost.ps1`.**
The plan's file list and task 2 both name `New-HDTConsoleHost.ps1`. Every tree
context-menu handler in this console actually lives in `New-HDTConsoleView.ps1`
— `New-HDTConsoleHost` holds the generic `ShowBuildProgress` method, which needed
no change at all because it already takes a command name. Putting the handler
where the plan said would have been a second place for menu wiring to live.
`tests/contract/ConsoleSurface.Contract.Tests.ps1` is green either way; it sweeps
the view.

**2. [Rule 2 - Missing critical] Three ValidateSets the plan did not name.**
`New-HDTConsoleNode -Kind` and `Get-HDTConsoleIconColor -Kind` each carry their
own closed copy of the kind set, and a `Media` row could not be built or coloured
without both. The plan named only `Get-HDTConsoleIcon`. A new set-driven test
now walks the icon ValidateSet by reflection and asserts **every** kind returns a
non-empty glyph *and* a non-empty colour, so the next kind added fails on the
table it was left out of rather than drawing a blank row that looks like a theme
problem.

**3. [Rule 1 - Bug] Two of my own wiring tests passed before the
implementation.**
"Offers Update Media Content on a media row" and the same on the category both
went green on the first run. Every item on that menu stays `Visible` until the
guard collapses it — the file's own opening note records exactly that trap for
an earlier feature — so "Visible here" alone is satisfied by the bug. Each now
asserts the **pair**: Visible on a media row, Collapsed on a non-media row, in
one `It`. Both then failed for the right reason.

**4. [Rule 1 - Bug] The click-wiring test used an API that does not exist.**
`[System.Windows.EventManager]::GetRoutedEventHandlers` is not a method. It was
rewritten to the file's own idiom — press the item for real on the one row where
it answers **without building anything** (the category of a share with two media,
which the handler refuses in words and returns from before opening any window)
and assert the command box changed. Nothing wired leaves it empty.

**5. My test fixture's manifest had an invented shape.** The first draft used
flat `isoPath`/`isoSizeBytes` keys; `New-HDTMediaManifest` writes
`artifacts.iso.{path,sha256,sizeBytes}`. Corrected against the writer — a fixture
that proves the console reads a shape nothing produces is worse than no fixture.
The lab share's manifest was likewise written **by the real command**, not typed
by hand.

**6. Counts in three existing tests moved**, and every one of them was a
set-driven guard doing its job rather than a test that needed loosening:
`ConsoleCategoryIcon` (8 → 9 categories), `ConsoleTreeNode` (8 → 9, 6 → 7 empty
rows, 16 → 18 across two shares), and `ConsoleTreeMenu`'s `$script:categoryName`.
The menu guard's "accounts for `<Kind>` — it offers a menu, or it says why it does
not" failed for `Media` the moment the node builder emitted one, which is exactly
what its comment says it is for.

## What the lab's own share needed

`C:\HDTLab\Share` carried an **empty** `Media\` folder and no definitions, so
nothing there could have exercised this. Spliced in, never replaced:

- `New-HDTMedia -Id 'HYDRATION-USB'` naming the existing `hydration` profile,
  with a `media.manifest.json` beside it written by `New-HDTMediaManifest` so one
  row reads as built;
- `New-HDTMedia -Id 'WIN11-FIELD'` naming `everything`, never built.

No ISO was burned. Both are definitions only.

## Verification

| Gate | Result |
|---|---|
| `./build.ps1 test` (Windows PowerShell 5.1) | **13917 passed, 0 failed, 268 skipped** |
| `./build.ps1 lint` (own process) | **0 diagnostics across 1143 files** |

Run under Windows PowerShell 5.1 only, in separate processes, as the gate
requires. The new `ConsoleMediaNode` file contributes 24 tests; `ConsoleTreeMenu`
went 47 → 53 and `ConsoleTreeMenuWiring` 24 → 34.

Each task was RED first and checked for the right reason — 25 failures for task
1 (`Media` absent from the workspace object and the icon set), 6 for the menu
row, 8 for the wiring.

## What this phase does NOT close

**ROADMAP M7's "Exit — media" is still NOT MET, and no screenshot can meet it.**
It is met by a **networkless VM deploying end to end from an ISO that
`Update-HDTMediaContent` actually built** — a real disc, real gigabytes, a real
boot. That run is the orchestrator's, not this phase's. Everything phase 07 built
is the machinery for it: 07-01 the document, 07-02 the build, 07-03 the way an
administrator reaches it without typing a command.

## Self-Check: PASSED

Every file the frontmatter claims was created exists on disk; both task commits
(`5ac565d`, `9ff9ac5`) are in the history; and each `key_link` the plan named is
present in the file it names — `Get-HDTConsoleMediaNode` in
`Get-HDTConsoleShareNode.ps1`, `Update-HDTMediaContent` and
`HDTUpdateMediaMenuItem` in `New-HDTConsoleView.ps1`, `HDTUpdateMediaMenuItem` in
both the markup and the string table, and `Media` in
`Get-HDTConsoleTreeMenuRow.ps1`'s `$offers`. All four pictures are in the phase
folder.
