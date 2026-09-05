---
phase: 07-media-command
plan: "05-03"
subsystem: console
tags: [console, media, details-pane, probe, screenshot, design-doc, share-splice]

requires:
  - The two lists (07-05-01) and the Browse button (07-05-02), both already green
  - New-HDTConsoleHost and the STA probe technique (CLAUDE.md, "Looking at a window on it")
provides:
  - "The photographs: four PNGs of the real window, not a description of it"
  - "The no-splice finding, checked three ways rather than assumed"
  - "DESIGN 6.2.3's paragraph on the four writable rows and the three controls that draw them"
affects:
  - docs/DESIGN.md

tech-stack:
  added: []
  patterns:
    - "A live probe is the test for a control that Pester cannot reach - the modal dialog is proven by photograph or not at all"

key-files:
  created:
    - .planning/phases/07-media-command/07-05-media-profile-list.png
    - .planning/phases/07-media-command/07-05-media-enabled-list.png
    - .planning/phases/07-media-command/07-05-media-output-browse.png
    - .planning/phases/07-media-command/07-05-media-iso-picker.png
    - .planning/phases/07-media-command/07-05-03-SUMMARY.md
  modified:
    - docs/DESIGN.md
---

# 07-05-03 — the pictures, the share check, and the paragraph in DESIGN

**Written 2026-09-06, after the phase's own verification.** Plans 07-05-01 and
07-05-02 closed on their own summaries; this one did not, because its task 3 is
a `checkpoint:human-verify` with `gate="blocking"` and the executor correctly
stopped at it rather than approving its own work. The verification report
recorded that honestly — "the work is genuinely unfinished, not skipped" — and
this file closes it.

## What the pictures show

Four PNGs, all from the real console driven by an STA probe against
`C:\HDTLab\Share`, not from a mock and not from a description:

| Picture | What it proves |
|---|---|
| `07-05-media-profile-list.png` | the profile row open over this share's **four real profile ids** — the collection the Selection Profiles category walks, not a second read of `selection-profiles.yaml` |
| `07-05-media-enabled-list.png` | the Enabled row open showing **exactly two** entries, `true` and `false` — the words `media.yaml` holds, with the explanation in the hint rather than in the value |
| `07-05-media-output-browse.png` | the Output row carrying a Browse button, **and no other row carrying one** |
| `07-05-media-iso-picker.png` | the native `SaveFileDialog` it opens, titled "Choose where the ISO is written", filtered to `ISO image (*.iso)` |

The last one is the one that matters most, because it is the one Pester cannot
reach: a modal dialog has no handle the unit harness can take, so its title, its
filter and its cancel behaviour are proven by photograph or not at all. That gap
is stated in 07-05-02's plan rather than left to look like an oversight.

## The share needed no splice, and here is why that is a finding and not an assumption

CLAUDE.md rule 8's corollary is that a change which `C:\HDTLab\Share` does not
have is a change nobody here can test — so "no splice needed" has to be
*checked*, because the failure mode is silent. Three checks, all run:

1. **The phase diff touches nothing the share copies.**
   `git diff --name-only 1ddfd58..HEAD` matches no path under `Templates/`,
   `Payload/` or `schemas/`.
2. **The share carries no console markup at all.** `HDTConsole.xaml`,
   `New-HDTConsoleField` and `Get-HDTConsoleFieldBrowse` all live in the module
   and are loaded from wherever the module is imported. `Scripts\UI` on the
   share is the **WinPE wizard**, a different surface entirely, and this phase
   did not touch it.
3. **No command, template or schema changed.** `Set-HDTMedia` and
   `Get-HDTMedia` are as 07-01 left them; the pane writes through them rather
   than around them.

So the console picks up this work by importing the module, which is what an
administrator running `Show-HDTConsole` already does. **This is the rare phase
where the share genuinely does not need touching** — recorded in that shape so
the next reader can tell it from a phase where somebody forgot.

## DESIGN 6.2.3

The paragraph the plan asked for is added: the four writable rows
(`description`, `selectionProfile`, `output`, `enabled`), the three controls
that draw them and why each row gets the one it does, where the profile list is
fed from and why it is fed rather than re-read, why `-Browse` is a **kind** and
not a switch, and why the dialog is a `SaveFileDialog` rather than an open
dialog — the file the box names is one `Update-HDTMediaContent` is going to
create, and an open dialog refuses every path that does not exist yet.

**And the tick-box deviation is written down there rather than only in a plan.**
Every other yes/no in this console is `New-HDTConsoleField -Check`. `enabled` is
a list at the user's explicit instruction of 2026-09-05. It is in the
authoritative document because the next consistency sweep would otherwise
"fix" it back to a tick box and be right to, on the evidence available to it.

## What this phase did NOT do

- **It did not make any other path row browsable.** 07-05-02 reported the other
  `-Property` path fields it found; changing them was deliberately left out,
  because a browse kind is a decision per row and a sweep would have made four
  of them silently.
- **It did not close the modal-dialog test gap.** A regression in the dialog's
  filter or its cancel behaviour would not be caught by the gate. The contract
  walks the browse *kinds* and `Get-HDTConsoleFieldBrowse` is pure and fully
  tested; what is unreachable is the dialog itself.
