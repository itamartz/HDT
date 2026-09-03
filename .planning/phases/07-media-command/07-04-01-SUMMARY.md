---
phase: 07-media-command
plan: 01
subsystem: console
tags: [console, media, wpf, wizard, context-menu]
requires:
  - New-HDTMedia (07-01)
  - Get-HDTConsoleMediaNode, the Media category and HDTUpdateMediaMenuItem (07-03)
provides:
  - Get-HDTConsoleNewMedia / Test-HDTConsoleNewMedia / Get-HDTConsoleNewMediaCommand
  - HDTNewMedia.xaml - id, name, selection profile, output
  - New-HDTConsoleHost.ShowNewMedia
  - HDTNewMediaMenuItem, on the Media category only
affects:
  - 07-04-02 - Remove Media, and the DESIGN/ROADMAP deferral notes to amend
tech-stack:
  added: []
  patterns:
    - the three-command trio (Get/Test/Get...Command) New Task Sequence already established
    - SaveFileDialog for a path that does not exist yet, vs OpenFileDialog for one that does
key-files:
  created:
    - src/Hephaestus/UI/Console/HDTNewMedia.xaml
    - src/Hephaestus/Private/Get-HDTConsoleNewMedia.ps1
    - src/Hephaestus/Private/Test-HDTConsoleNewMedia.ps1
    - src/Hephaestus/Private/Get-HDTConsoleNewMediaCommand.ps1
    - tests/unit/Get-HDTConsoleNewMedia.Tests.ps1
  modified:
    - src/Hephaestus/Public/New-HDTConsoleHost.ps1
    - src/Hephaestus/Private/New-HDTConsoleView.ps1
    - src/Hephaestus/Public/Show-HDTConsole.ps1
    - src/Hephaestus/UI/Console/HDTConsole.xaml
    - src/Hephaestus/Strings/en-us.psd1
    - tests/unit/ConsoleTreeMenuWiring.Tests.ps1
decisions:
  - One dialog, four fields, no Description - a fifth optional field was not this plan's scope
  - The selection profile is chosen from a ComboBox, never typed
  - Output pairs a TextBox with a Browse button using SaveFileDialog, not OpenFileDialog, since the ISO does not exist yet
  - New Media is offered on the Media category only, never on a media item - "new" names nothing that already exists
metrics:
  tasks: 2
  commits: 2
  duration: ~1h10m
  completed: 2026-09-03
---

# Phase 07 Plan 04-01: New Media Summary

**New Media on the console's right-click menu - id, name, selection profile,
output - backed by `New-HDTMedia`, the way New Task Sequence is off
`TaskSequences`.**

## What was built

**`Get-HDTConsoleNewMedia` / `Test-HDTConsoleNewMedia` /
`Get-HDTConsoleNewMediaCommand`** - the same three-command shape the New Task
Sequence wizard already uses, one test file. `Get-HDTConsoleNewMedia` lists
this share's selection profiles (built-ins included) through
`Get-HDTSelectionProfile`, forwarding `-FileSystem` rather than falling
through to the real adapter - the exact defect 07-03's own plan named finding
in itself. `Test-HDTConsoleNewMedia` makes every refusal `New-HDTMedia` would
make - empty id, illegal id (`New-HDTMedia`'s own
`^[A-Za-z0-9][A-Za-z0-9_.-]*$` pattern, copied rather than reinvented), empty
name, a duplicate `media.yaml` - on the page rather than on the last press.
`Get-HDTConsoleNewMediaCommand` composes the exact `New-HDTMedia` line
Create is about to run, omitting `-Output` when the box was left empty so the
line still matches what the command would actually do with nothing in it.

**`HDTNewMedia.xaml`** copies `HDTNewSequence.xaml`'s shell verbatim -
banner, `HDTHelpDot`/`HDTHelpGlyph` styles, command-preview strip, Create/
Cancel footer - with four rows: Media ID, Media name, a Selection profile
`ComboBox` (`DisplayMemberPath="Name"` `SelectedValuePath="Id"`), and Output
(`TextBox` + Browse). The Browse button opens a `SaveFileDialog` filtered to
`*.iso` rather than `HDTBootImageBackgroundBrowseButton`'s `OpenFileDialog` -
the one is choosing a file that exists, this one is naming one that does not
yet.

**`ShowNewMedia`**, a `ScriptMethod` on `New-HDTConsoleHost` modelled on
`ShowNewSequence`: loads the markup, seeds the profile box (defaulting to
`'everything'` if present, matching `New-HDTMedia`'s own default), wires
every box to a `$check` closure that calls `Test-HDTConsoleNewMedia` and
`Get-HDTConsoleNewMediaCommand` through `Get-HDTHandlerCall`, and on
`Create.Add_Click` calls `New-HDTMedia`, catching a refusal onto the page's
message text rather than a message box over an already-closed dialog.

**The menu wiring** - `-NewMediaXaml` on `New-HDTConsoleView`, gated the
identical "no markup, no item" way `-NewSequenceXaml` and
`-ImportWindowsUpdateXaml` already are; a `$isMediaCategory` check in the
`ContextMenuOpening` guard (category only, collapsed unconditionally on a
media item row - unlike Update Media Content, which both rows offer); a
`Show-HDTConsole -NewMediaXamlPath` parameter defaulting to the shipped file
and forwarded the same way every other dialog's markup travels, through
`New-HDTConsoleHost.Show`'s own parameter list.

## The picture

Rendered offscreen with `RenderTargetBitmap` under Windows PowerShell 5.1,
`RenderOptions.ProcessRenderMode = 'SoftwareOnly'`, the real shipped
`HDTNewMedia.xaml` through the real string table and theme:

`07-04-01-new-media-dialog.png` - the banner naming the share, `Media ID` /
`Media name` / `Selection profile` / `Output` each with its `?` help dot, the
Output row's Browse button, the command-preview strip showing the exact
`New-HDTMedia` line, and Create/Cancel in the footer.

## Deviations from Plan

**1. [Rule 1 - Bug] `PSUseSingularNouns` on both new private commands.**
- **Found during:** Task 2's `./build.ps1 lint` run.
- **Issue:** `Get-HDTConsoleNewMedia` and `Test-HDTConsoleNewMedia` both read
  as the Latin plural of "medium" to the analyzer - the exact reading
  `New-HDTMedia` itself already carries a suppression for (DESIGN 6.2: Media
  is a mass noun and the singular name of one object). The plan's evidence
  named the pattern to copy but not this suppression.
- **Fix:** The identical `SuppressMessageAttribute('PSUseSingularNouns', ...)`
  `New-HDTMedia` uses, added to both commands with the same justification.
- **Files modified:** `src/Hephaestus/Private/Get-HDTConsoleNewMedia.ps1`,
  `src/Hephaestus/Private/Test-HDTConsoleNewMedia.ps1`.
- **Verification:** `./build.ps1 lint` - 0 diagnostics across 1148 files.
- **Committed in:** `31f2a65` (Task 2 commit).

**2. [Rule 1 - Bug] `$profile` shadowed PowerShell's automatic variable.**
- **Found during:** Task 2's `./build.ps1 lint` run.
- **Issue:** `Get-HDTConsoleNewMedia.ps1` assigned the selection-profile list
  to `$profile`, which is a PowerShell automatic variable (`PSAvoidAssignmentToAutomaticVariable`).
- **Fix:** Renamed to `$available`.
- **Files modified:** `src/Hephaestus/Private/Get-HDTConsoleNewMedia.ps1`.
- **Verification:** `./build.ps1 lint` - 0 diagnostics across 1148 files;
  `./build.ps1 test` rerun green after the rename (13956 passed, 0 failed).
- **Committed in:** `31f2a65` (Task 2 commit).

---

**Total deviations:** 2 auto-fixed (both Rule 1 - bugs the plan's template did
not carry over, caught by the lint gate rather than by a test).
**Impact on plan:** Both fixes are cosmetic/analyzer-only - no behaviour
changed, no test needed rewriting. No scope creep.

## Verification

| Gate | Result |
|---|---|
| `./build.ps1 test` (Windows PowerShell 5.1) | **13956 passed, 0 failed, 268 skipped** |
| `./build.ps1 lint` (own process) | **0 diagnostics across 1148 file(s)** |

Both run under Windows PowerShell 5.1.26100.8655 only, in separate processes,
`PSModulePath` unset, as the gate requires. `tests/unit/Get-HDTConsoleNewMedia.Tests.ps1`
contributes 16 tests; `ConsoleTreeMenuWiring` gained a fifth `Describe` block
("right-clicking the media rows to create one") with 5 tests.
`tests/contract/StringTable.Contract.Tests.ps1` and
`tests/contract/ConsoleSurface.Contract.Tests.ps1` (155 tests combined,
including the "declares the door in every scope" and "no markup, no item"
sweeps) ran unchanged and stayed green.

Each task was RED first and checked for the right reason - `CommandNotFoundException`
naming the three missing commands for task 1 (16 failures); `ParameterBindingException`
naming the missing `-NewMediaXaml` parameter for task 2 (39 failures, the
whole file, since `New-HDTTestMenuWindow`'s signature changed).

## Self-Check: PASSED

Every file the frontmatter claims was created exists on disk; both task
commits (`84eba51`, `31f2a65`) are in the history; and each `key_link` the
plan named is present in the file it names - `ShowNewMedia` in
`New-HDTConsoleHost.ps1`, `New-HDTMedia` inside it, `NewMediaXamlPath` in
`Show-HDTConsole.ps1`. The dialog was rendered offscreen and photographed;
the picture is in the phase folder.

## Next Phase Readiness

07-04-02 (Remove Media, and the DESIGN.md/ROADMAP.md deferral-note
amendments) can proceed without reopening any file this plan finished -
`HDTNewMedia.xaml`, `ShowNewMedia`, the three private helpers and the menu
wiring are all done and green.
