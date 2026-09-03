---
phase: 07-media-command
plan: 02
subsystem: console
tags: [console, media, wpf, context-menu, destructive-confirmation]
requires:
  - Remove-HDTMedia (07-01)
  - Get-HDTConsoleRemoval, the Remove Application shape (pre-existing)
  - HDTNewMediaMenuItem, Media (n) category and item rows (07-03, 07-04-01)
provides:
  - Get-HDTConsoleRemoval -Kind 'Media'
  - HDTRemoveMediaMenuItem, on a media item only
  - the amended DESIGN.md/ROADMAP.md/source-comment record that New Media and Remove Media are on the menu
affects:
  - none - closes the console-menu half of M7's media work; the still-open exit criterion is a booted VM, which is the orchestrator's, not this plan's
tech-stack:
  added: []
  patterns:
    - Get-HDTConsoleRemoval's per-kind $shape hashtable, extended with a fourth removable kind
    - the ISO-left-behind consequence composed in the click handler, not taught to the generic composer
    - amend-in-place documentation correction, matching ROADMAP's own "UN-DEFERRED on 2026-09-03" register
key-files:
  created: []
  modified:
    - src/Hephaestus/Private/Get-HDTConsoleRemoval.ps1
    - src/Hephaestus/Private/New-HDTConsoleView.ps1
    - src/Hephaestus/UI/Console/HDTConsole.xaml
    - src/Hephaestus/Strings/en-us.psd1
    - tests/unit/ConsoleRemoval.Tests.ps1
    - tests/unit/ConsoleTreeMenuWiring.Tests.ps1
    - docs/DESIGN.md
    - docs/ROADMAP.md
    - src/Hephaestus/Private/Get-HDTConsoleTreeMenuRow.ps1
    - src/Hephaestus/Private/Get-HDTConsoleMediaNode.ps1
decisions:
  - Remove Media is on the item, never the category - the opposite asymmetry from Update Media Content, which both rows offer
  - The ISO-left-behind warning is composed in the click handler, not added as a fourth Get-HDTConsoleRemoval shape
  - Documentation correction is amend-in-place with a dated note, never a silent rewrite
metrics:
  tasks: 3
  commits: 2
  duration: ~2h
  completed: 2026-09-03
---

# Phase 07 Plan 04-02: Remove Media Summary

**Remove Media on a media item's right-click menu, composed by `Get-HDTConsoleRemoval -Kind 'Media'` through the same confirmation shape Remove Application uses - and the four places that called this a deferral now say it shipped.**

## What was built

**`Get-HDTConsoleRemoval -Kind 'Media'`** joins `TaskSequence`/`OperatingSystem`/`Application`/`DriverFolder`/`MonitorRun`/`WindowsUpdate` in the `-Kind` `ValidateSet`, with its own `$shape`: title `Remove Media`, command `Remove-HDTMedia`, parameter `WorkspaceRoot`, and `Goes` naming `media.yaml and the ISO beside it, when the ISO is inside the folder`. `UsedFormat` stays empty - a media item is a leaf projected from the share, never referenced by anything else on it, so it has no `UsedBy`/`RequiredBy` consequence to report. The existing "row does not name a share and an id" refusal path required no special case: `Media`'s article (`'a'`) and noun (`'media definition'`) already read correctly through the generic `$article`/`$what` logic every other kind uses.

**`HDTRemoveMediaMenuItem`** on `HDTConsole.xaml`, beside `HDTNewMediaMenuItem`, with `'Remove Media'` in `en-us.psd1`. `New-HDTConsoleView.ps1`'s `ContextMenuOpening` guard shows it only when `$chosen.Kind -eq 'Media'` - never on the category, which is the opposite asymmetry from Update Media Content's "both rows" rule: removing the category would have to mean removing every media definition on the share at once, not the one press somebody makes by right-clicking a branch. No markup gate applies - Remove Media composes a `MessageBox`, not a window of its own, so it is offered whether or not `-NewMediaXaml` was given.

**`removeMedia.Add_Click`** is `removeApplication.Add_Click`'s own skeleton: refuse-first via `Get-HDTConsoleRemoval -Kind 'Media'`, preflight with `Remove-HDTMedia -WorkspaceRoot ... -WhatIf` to learn `IsoLeftBehind`, build `$ask` again, append the ISO warning to `$ask.Question` when `IsoLeftBehind` is non-empty, show the `MessageBox` (`YesNo`/`Warning`/default-`No`), run `Remove-HDTMedia -Confirm:$false` on `Yes`, and `& $rebuildTree` unconditionally - the same shape every other destructive press in this console follows.

**Four documents and comments corrected**, amended in place rather than rewritten: `DESIGN.md` 6.2.3's `**New Media and Remove Media are deliberately NOT on the menu**` paragraph now names both commands, the dialogs/confirmation that run them, and the one asymmetry worth a reader tripping on; `ROADMAP.md`'s M7 media block now records phase 07-04 and the date, matching the register `**UN-DEFERRED on 2026-09-03**` already uses two paragraphs above it; `Get-HDTConsoleTreeMenuRow.ps1`'s comment above `$isMediaCategory` explains that `IsMediaRow` still gates Update Media Content alone, with New/Remove Media gated in `New-HDTConsoleView.ps1` directly; `Get-HDTConsoleMediaNode.ps1`'s `(none)` row comment now says the row is the *other* door (for someone reading `Get-HDTMedia`'s own output) rather than the only one.

`docs/command-reference.html` and `docs/command-categories.psd1` were checked and confirmed to need no change - the category file already lists all five `*-HDTMedia` commands, and the reference is generated from comment-based help on a version bump, never hand-edited, and never named a console-reachability claim to correct.

## The pictures

Driven against the real `C:\HDTLab\Share` with a real STA probe under Windows PowerShell 5.1, `RenderOptions.ProcessRenderMode = 'SoftwareOnly'`, the console shown for real (not offscreen) so both `PrintWindow` and a screen capture of the open `ContextMenu` `Popup` could be taken. A media item named `CONSOLE-PROBE` was created through the real dialog and `New-HDTMedia`, photographed, then removed through the real `Remove Media` confirmation and `Remove-HDTMedia` - the share ends exactly as it started, with only `HYDRATION-USB`, `WIN11-FIELD` and `HYDRA` (pre-existing, from 07-03 and the M7 exit verification) left under `Media\`.

| Picture | What it shows |
|---|---|
| `07-04-02-media-category-menu.png` | the `Media (3)` category's menu, open: **Update Media Content** and **New Media** both visible |
| `07-04-02-new-media-dialog.png` | the New Media dialog: Id `CONSOLE-PROBE`, Name `Console probe verification media`, Selection profile `Everything` chosen from the ComboBox, and the exact `New-HDTMedia` command-preview line |
| `07-04-02-tree-after-create.png` | the tree after Create: `Media (4)`, the new row selected, Details reading `Last build (never built)` - reached without reopening the share |
| `07-04-02-remove-media-menu.png` | the same item's menu: **Remove Media** visible and enabled, **Update Media Content** above it |
| `07-04-02-remove-media-confirm.png` | the `Remove Media` `MessageBox`: "Remove the media definition 'CONSOLE-PROBE' from C:\HDTLab\Share? Its folder goes with it - media.yaml and the ISO beside it, when the ISO is inside the folder. This cannot be undone from here." |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `EventManager.RegisterClassHandler` on `Window.Loaded` silently killed the probe process**
- **Found during:** Task 3, first attempt at driving the live New Media dialog through the real menu click
- **Issue:** A global class handler is the wrong place to invoke a PowerShell delegate - the process exited with no managed exception and no crash record at all, mid-way through opening the dialog.
- **Fix:** Abandoned the global hook. The New Media dialog is now built directly in the probe - the same real XAML, theme and `Get-HDTConsoleNewMedia`/`Get-HDTConsoleNewMediaCommand` private helpers `ShowNewMedia` itself calls - shown with `.Show()` instead of a nested `.ShowDialog()`, so nothing blocks the one thread already in control. `New-HDTMedia` still runs for real against the real share; only the literal `ShowNewMedia` wrapper call is bypassed, and that wrapper's own wiring is already proven by `ConsoleTreeMenuWiring.Tests.ps1`'s "wires the click" assertion.
- **Files modified:** none (probe-only, not shipped code)
- **Verification:** the dialog rendered correctly on the next run and `New-HDTMedia` created `CONSOLE-PROBE` on the real share.

**2. [Rule 3 - Blocking] A same-thread `DispatcherTimer` did not reliably tick during a nested `ShowDialog` pump**
- **Found during:** Task 3, second attempt (polling for the New Media dialog's HWND from a `DispatcherTimer` on the same thread the modal dialog was blocking)
- **Issue:** The dialog opened and stayed open, correctly, for over 90 seconds with the timer never finding it - proven separately by an external `EnumWindows` check that found the window `visible=True` while the timer's own log line never appeared.
- **Fix:** For the `Remove Media` confirmation (a native `MessageBox`, unlike the WPF-rendered New Media dialog), the poll now runs on a genuinely separate runspace/thread (`[runspacefactory]::CreateRunspace()`, STA), which finds the dialog by title and drives it with plain `SendMessage`/`BM_CLICK` - the standard way an external tool talks to a modal dialog it does not own the thread of.
- **Files modified:** none (probe-only)
- **Verification:** the confirmation was found, photographed and dismissed (clicking Yes for real) within 300ms on every subsequent run.

**3. [Rule 1 - Bug] The synthetic `ContextMenuOpening` event did not actually open the popup, and its default placement followed the real mouse cursor**
- **Found during:** Task 3, photographing the category's right-click menu
- **Issue:** Raising `ContextMenuEventArgs` only runs the guard that decides what the menu offers; it does not make WPF's `ContextMenuService` show the `Popup`, and once `IsOpen` was forced to `$true` by hand, the popup's default `Placement` (`MousePoint`) put it wherever the real system cursor happened to be on this ultrawide monitor - across an unrelated application window on one run.
- **Fix:** `PlacementTarget = $tree` and `Placement = [PlacementMode]::Bottom`, so the popup anchors under the tree control regardless of where the mouse physically is.
- **Files modified:** none (probe-only)
- **Verification:** every screenshot after the fix cropped to the console's own bounds, no unrelated window visible.

---

**Total deviations:** 3 auto-fixed, all Rule 3/Rule 1 - all in the verification probe itself, not in shipped code. `src/` and `tests/` changed exactly as planned in Task 1 and Task 2; nothing here altered the implementation.
**Impact on plan:** None on the shipped feature. The probe's fragility is a property of driving nested modal WPF dialogs from reflection, not of the console.

## Verification

| Gate | Result |
|---|---|
| `Invoke-Pester tests/unit/ConsoleRemoval.Tests.ps1, tests/unit/ConsoleTreeMenuWiring.Tests.ps1` | **81 passed, 0 failed** (9 new: 6 in `ConsoleRemoval`, 3 in `ConsoleTreeMenuWiring`) |
| `Invoke-Pester tests/contract/StringTable.Contract.Tests.ps1, tests/contract/ConsoleSurface.Contract.Tests.ps1` | **155 passed, 0 failed** |
| `Invoke-Pester tests/unit/ConsoleTreeMenu.Tests.ps1, tests/unit/ConsoleMediaNode.Tests.ps1, tests/unit/MonitorRunRemoval.Tests.ps1` (Task 2's blast radius) | **103 passed, 0 failed** |
| `grep` for every deferral phrase, across `docs/` and the two source comments | **no matches** |
| `./build.ps1 test` (whole suite, Windows PowerShell 5.1) | **13965 passed, 0 failed, 268 skipped** |
| `./build.ps1 lint` (own process) | **0 diagnostics across 1148 files** |
| Live STA probe against `C:\HDTLab\Share` | **all 5 pictures captured; share left exactly as found** |

Both `test` and `lint` were run under Windows PowerShell 5.1.26100.8655 only, in separate processes, `PSModulePath` unset, as the gate requires.

## Self-Check

Verified on disk and in history before writing this section:

- `src/Hephaestus/Private/Get-HDTConsoleRemoval.ps1` contains `'Media'` in the `-Kind` `ValidateSet` and its own `case` - **FOUND**
- `Remove-HDTMedia` appears in `src/Hephaestus/Private/New-HDTConsoleView.ps1` - **FOUND**
- Commit `ca176e0` (Task 1) is in `git log` - **FOUND**
- Commit `890bb52` (Task 2) is in `git log` - **FOUND**
- All five pictures exist under `.planning/phases/07-media-command/` - **FOUND**
- `grep -rn "deliberately not on the menu" docs/ src/Hephaestus/Private/Get-HDTConsoleTreeMenuRow.ps1 src/Hephaestus/Private/Get-HDTConsoleMediaNode.ps1` - **returns nothing**

## Next Phase Readiness

The console-menu half of M7's media work is complete: an administrator can create and remove a standalone media definition without typing either command, and every document/comment that called this incomplete now agrees it is not. The still-open ROADMAP M7 "Exit - media" criterion - a networkless VM deploying from an `Update-HDTMediaContent`-built ISO - was already met separately (2026-09-03, per ROADMAP's own record) and is not this plan's or 07-04-01's to re-run.

---
*Phase: 07-media-command*
*Completed: 2026-09-03*
