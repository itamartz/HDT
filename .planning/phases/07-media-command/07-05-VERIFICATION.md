---
phase: 07-05-media-details-pane
verified: 2026-09-05T21:00:00Z
status: gaps_found
score: 9/11 must-haves verified
verifier_ran:
  gate_51: "14090 passed, 0 failed, 268 skipped - BUILD SUCCEEDED (test) on PowerShell 5.1.26100.8655"
  lint: "0 diagnostics across 1152 file(s) - BUILD SUCCEEDED (lint) on PowerShell 5.1.26100.8655"
  gate_pwsh7: "14291 passed, 8 failed, 59 skipped - all 8 pre-existing and unrelated to this phase; pwsh 7 is not the gate"
  round_trip: "Independent, outside Pester: Set-HDTMedia -Enabled false wrote a bare boolean, Get-HDTMedia read it back as System.Boolean, both comment lines survived"
  hyperv: "2 VMs enumerated before and after, byte-identical JSON diff. Both HDT-*, both already running. No non-HDT VM exists on this host, so the protected set is empty - reported, not passed over"
gaps:
  - truth: "DESIGN 6.2.3 says which rows of the media details pane write, and with which control."
    status: failed
    reason: "Task 4 of 07-05-03 was never executed. It sits behind a blocking checkpoint:human-verify (task 3) that has not been approved, and the executor said so plainly. docs/DESIGN.md is not in the phase's diff at all."
    artifacts:
      - path: "docs/DESIGN.md"
        issue: "Section 6.2.3 (line 1900) still ends at the 07-04 New Media / Remove Media paragraph. It never says that description and output are boxes, selectionProfile and enabled are lists, or that the enabled list is a deliberate deviation from the house tick box."
    missing:
      - "The paragraph 07-05-03 task 4 specifies, naming the four writable rows, their three controls, and the recorded tick-box deviation"
  - truth: "The phase records what it did, as its two siblings do."
    status: failed
    reason: "07-05-01-SUMMARY.md and 07-05-02-SUMMARY.md exist; 07-05-03-SUMMARY.md does not. The plan's own closing tasks list it as outstanding."
    artifacts:
      - path: ".planning/phases/07-media-command/07-05-03-SUMMARY.md"
        issue: "Missing"
    missing:
      - "07-05-03-SUMMARY.md, written after the checkpoint is approved and task 4 is done"
human_verification:
  - test: "Look at the four committed screenshots and say approved, or say which is wrong"
    expected: "07-05-media-profile-list.png, 07-05-media-enabled-list.png, 07-05-media-output-browse.png, 07-05-media-iso-picker.png"
    why_human: "07-05-03 task 3 is an explicit checkpoint:human-verify with a blocking gate. Task 4 cannot correctly run before it. The verifier confirmed the pictures show what they claim; the approval itself is the user's."
---

# Phase 07-05: Media details pane Verification Report

**Phase Goal:** Fix three things in the console's media details pane - selection
profile becomes a drop-down over the share's profile ids, enabled becomes a
drop-down of true/false with its explanation moved to the hint, and output gets
a file Browse button.

**Verified:** 2026-09-05
**Status:** gaps_found - the three functional goals are all achieved and proven;
the phase's own documentation task is not done.
**Re-verification:** No - initial verification.

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|---|---|---|
| 1 | Selection profile is a list of this share's profile ids, not a box | VERIFIED | Get-HDTConsoleMediaNode.ps1 passes -Choice with the share ids. Photographed open over the share's four real ids in 07-05-media-profile-list.png |
| 2 | The list is fed from outside, not read a second time | VERIFIED | Get-HDTConsoleShareNode.ps1:914-916 passes -SelectionProfile from the same collection the Selection Profiles category walks. The .Id mapping happens once inside Get-HDTConsoleMediaNode |
| 3 | A media naming a profile the share dropped shows it first on its own list | VERIFIED | The prepend branch, covered by the Context "a media naming a profile the share no longer offers" - Success in the XML |
| 4 | Enabled is a list of true and false and nothing else | VERIFIED | -Choice of exactly two words. Photographed open in 07-05-media-enabled-list.png showing exactly two entries |
| 5 | The explanation moved to -Hint, never inside the value | VERIFIED | The value is the bare word; the sentence is the hint. NOTE: the English sentence the phase brief describes was already gone at 07-05's start - at commit 1ddfd58 the value was yes/no, not a sentence. The brief's premise was stale by one phase, and 07-05-01's objective says so rather than working around it |
| 6 | Picking false writes a real boolean that round-trips | VERIFIED, and re-proved independently | Run outside Pester against the real module: media.yaml carried a bare enabled false, Get-HDTMedia returned System.Boolean / False, and both comment lines survived the splice |
| 7 | The refusal path survives the two deleted text-box contexts | VERIFIED | The deleted Its drove HDTDetailBox, which HasChoice collapses rather than removes, so both would have stayed green about a control nobody can reach. Replaced by a stale-profile pick that is refused, reverts the combo and leaves the file untouched. Net It count in that file rose 24 to 52 |
| 8 | Output has a Browse button; no other row grows one | VERIFIED | -Browse IsoFile on the Output row only. Two screenshots show the ellipsis on Output and on nothing else |
| 9 | Browse opens a SaveFileDialog filtered to .iso, seeded from the row, and cancel writes nothing | VERIFIED | Get-HDTConsoleFieldBrowse -Kind IsoFile returns Dialog=Save with the ISO filter and a seeded FileName/Directory - run directly by the verifier. 07-05-media-iso-picker.png is the real native dialog with that title and filter. The handler returns before the box is touched when ShowDialog is not true |
| 10 | DESIGN 6.2.3 says which rows write and with which control | **FAILED** | Section 6.2.3 (docs/DESIGN.md:1900) still ends at the 07-04 paragraph. docs/DESIGN.md does not appear in the phase's diff |
| 11 | The phase records what it did | **FAILED** | No 07-05-03-SUMMARY.md |

**Score:** 9/11

### Required Artifacts

| Artifact | Expected | Status | Details |
|---|---|---|---|
| src/Hephaestus/Private/Get-HDTConsoleMediaNode.ps1 | -SelectionProfile, profile choice, enabled choice | VERIFIED | Parameter present and documented; ids mapped once, above the loop |
| src/Hephaestus/Private/Get-HDTConsoleShareNode.ps1 | Feeds the profiles it already read | VERIFIED | Lines 914-916 |
| src/Hephaestus/Private/Get-HDTConsoleFieldBrowse.ps1 | The one place a kind becomes a dialog | VERIFIED | Pure - no WPF type, no disk, System.IO.Path and never Split-Path. Throws by name on an unmapped kind rather than returning null |
| src/Hephaestus/Private/New-HDTConsoleField.ps1 | -Browse as a kind with a ValidateSet | VERIFIED | Emits Browse and HasBrowse; refuses a browse with no -Property and a browse alongside -Choice |
| src/Hephaestus/UI/Console/HDTConsole.xaml | HDTDetailBrowseButton and the HasBrowse trigger | VERIFIED | Button at line 799 with Tag bound by ElementName to its own row's box; trigger at line 863 |
| src/Hephaestus/Private/New-HDTConsoleView.ps1 | Routed click handler ending in the same write path | VERIFIED | ButtonBase ClickEvent handler; casts OriginalSource to Button and not ButtonBase, so a ComboBox arrow's bubbled click is dropped; ends in Test-HDTConsoleRowCommit and the same writeRow a typed path uses - no second save path |
| tests/unit/ConsoleFieldBrowse.Tests.ps1 | The browse kind under test | VERIFIED | Present, Success |
| tests/contract/ConsoleSurface.Contract.Tests.ps1 | A sweep over the SET | VERIFIED | AST sweep of every New-HDTConsoleField call under src/, asserted against Get-HDTConsoleFieldBrowse and against the parameter's own ValidateSet. Names neither IsoFile, Output nor Media. Guards against a vacuous pass by requiring the declared count to be greater than zero |
| docs/DESIGN.md | A 6.2.3 paragraph on the writable rows | **MISSING** | Not touched by the phase |
| .planning/phases/07-media-command/07-05-03-SUMMARY.md | The plan's record | **MISSING** | - |
| Four screenshots | Profile list, enabled list, browse button, ISO picker | VERIFIED | All four committed in ef13072; the verifier opened all four and they show what they claim |

### Key Link Verification

| From | To | Via | Status |
|---|---|---|---|
| Get-HDTConsoleShareNode.ps1 | Get-HDTConsoleMediaNode | -SelectionProfile, the collection the Selection Profiles category already walks | WIRED |
| HDTConsole.xaml | media rows | the existing HasChoice DataTrigger - no markup change by 07-05-01 | WIRED |
| HDTConsole.xaml | HDTDetailBox | Tag bound by ElementName on the browse button | WIRED |
| New-HDTConsoleView.ps1 | Get-HDTConsoleFieldBrowse and Microsoft.Win32.SaveFileDialog | routed ButtonBase ClickEvent handler | WIRED |
| Get-HDTConsoleMediaEdit.ps1 | Set-HDTMedia -Enabled | the true/false branch that still reads yes/no/1/0 | WIRED - verified by running it: Property enabled, Text false returns Parameter=Enabled, Value=False, Text=$false |
| docs/DESIGN.md | the pane as it now draws | an added 6.2.3 paragraph | **NOT WIRED** |

## The verifier's own runs

Nothing below is quoted from a SUMMARY. Each was run in this session.

### 1. The gate - Windows PowerShell 5.1

```
test: 495 file(s) across 8 worker(s) of C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
test: 14090 passed, 0 failed, 268 skipped
BUILD SUCCEEDED (test) on PowerShell 5.1.26100.8655
```

Launched from Bash so the child computes its own PSModulePath. Read out of the
Pester NUnit XML, these suites all report Success: Naming.Contract.Tests.ps1,
NoMdtDependency.Contract.Tests.ps1, PowerShell51Compatibility.Contract.Tests.ps1,
ConsoleSurface.Contract.Tests.ps1, ConsoleFieldBrowse.Tests.ps1,
ConsoleMediaNode.Tests.ps1, ConsoleFieldEdit.Tests.ps1 and
Get-HDTConsoleMediaEdit.Tests.ps1.

So the Verb-HDTNoun naming contract and the no-MDT-dependency contract are met
by a test that exists AND passes, not by inspection.

### 2. PSScriptAnalyzer - a separate process, as the project requires

```
lint: 0 diagnostics across 1152 file(s)
BUILD SUCCEEDED (lint) on PowerShell 5.1.26100.8655
```

### 3. pwsh 7 - run because it was asked for, reported with its caveat

```
test: 14291 passed, 8 failed, 59 skipped
BUILD FAILED: 8 test test(s) failed.
```

Run AFTER the 5.1 pass finished, never beside it - the two collide over real
DISM artefacts. **pwsh 7 is deliberately not the gate** (CLAUDE.md; the engine
ships into WinPE, which has no pwsh). All eight failures are pre-existing and
none is in code this phase touched:

| Failing test | Why it is not this phase |
|---|---|
| state.json schema contract, six rows - the three "validates" and the three "agrees with Assert-HDTRunStateDocument" | pwsh 7's Test-Json rejects the false schema at /deploymentPassword differently from 5.1. No media, no console, untouched by 07-05 |
| Export-HDTDeviceInventory, "formats the timestamp as a string" | A pwsh 7 JSON serialisation difference - the expected and the actual are the same characters. Untouched by 07-05 |
| "a description typed into the details pane of an imported update / and the name is renamed after it / does not throw out of the handler" | Windows Updates, not media. The Context exists verbatim in the PRE-phase file at commit 1ddfd58 (Describe at line 209, Context at 334), and commit 8909b3f had already skipped it on GitHub's runner for the same environment sensitivity. Green under 5.1 |

### 4. The round trip, proved outside Pester

Import-Module the real manifest, real New-HDTWorkspace and New-HDTMedia in
C:\HDTLab\scratch, then the two writes the pane makes:

```
--- after create ---
[selectionProfile: everything]
[output: Media\VERIFY\HDT_VERIFY.iso]
[enabled: true]
--- after set ---
[selectionProfile: everything]
[output: D:\Builds\field kit.iso]
[enabled: false]
Enabled type=System.Boolean value=False
OutputPath=D:\Builds\field kit.iso
comment lines kept: 2
```

The enabled value is bare, not quoted; Get-HDTMedia gives back a real bool; the
comments survived, so the YAML was spliced and not re-serialised. The scratch
workspace was removed by the same code that created it. The output path chosen
carries a space on purpose.

### 5. Hyper-V

Enumerated before and after; the JSON diff is empty.

| Name | State | Memory | Gen | Switch |
|---|---|---|---|---|
| HDT-WDS-01 | Running (3d17h uptime at first read) | 4 GB | 2 | HDT External |
| HDT-WSUS-01 | Running (1d00h uptime at first read) | 8 GB | 2 | HDT External |

Two VMs, so the snapshot is **not** empty and this is not an empty-equals-empty
pass. Both were already up before verification began - neither was started here,
and nothing was started or stopped by it. **Reported rather than glossed: there
is no VM on this host outside the HDT-* prefix**, so the protected set is empty.
The "every VM not named HDT-* is exactly as it was found" check is therefore
vacuously true, and the assertion that can actually fail is the one that was
made: the enumerated set is identical field for field, name, state, memory,
generation, processor count and switch.

### 6. The share needs no splice - verified, not assumed

- The phase's full diff, git diff --name-only from 1ddfd58 to HEAD, touches
  src/Hephaestus/Private/, src/Hephaestus/UI/Console/HDTConsole.xaml, tests/ and
  .planning/. **Nothing under Templates/, Payload/ or schemas/.**
- C:\HDTLab\Share has no Console directory - listed it.

## TDD

Checked against git log --name-status, not against a claim.

| Commit | Kind | Verdict |
|---|---|---|
| eb39f43 | test only - ConsoleMediaNode.Tests.ps1 +216, Get-HDTConsoleMediaEdit.Tests.ps1 +32 | RED first |
| cfa588f | feat - the three src/ files those tests cover | after its test |
| 88556d4 | test - the real-window round trip | after the feat it exercises. It proves wiring that already existed (the SelectionChanged handler predates the phase), so it is a proof-of-integration rather than a test-after for new logic. The weakest link in the chain, and worth naming |
| 3e8a75f | fix plus its tests in one commit | alongside |
| 53e79d2 | test only - ConsoleFieldBrowse.Tests.ps1 created | RED first |
| a882012 | feat - Get-HDTConsoleFieldBrowse.ps1 created | after its test |
| 76659de | feat plus ConsoleFieldEdit.Tests.ps1 in the same commit | alongside |
| dd92b74 | test - the contract sweep over the set | after 76659de. A contract over the SET, added once the set had a member; acceptable, and named here rather than smoothed over |

**Verdict: TDD followed.** Both waves open with a test-only commit that names the
parameter and the behaviour that does not exist yet, and the executors recorded
the RED reasons (parameter Browse not found, HasBrowse not found,
Get-HDTConsoleFieldBrowse is not recognized). Two commits add tests after the
implementation they cover; both are integration or contract proofs over
already-covered logic, not first coverage.

## Engine / injected-service rule

No new direct hardware, registry, CIM or filesystem call in engine code.
Get-HDTConsoleFieldBrowse is pure and never touches the disk - deliberately,
with the reason written above it (the folder a path names may not exist yet).
Get-HDTConsoleMediaNode reaches the filesystem only through
Get-HDTWorkspacePath, which is IO.Path Combine and not Join-Path.
Microsoft.Win32.SaveFileDialog in New-HDTConsoleView.ps1 is UI-layer, is
PresentationFramework rather than System.Windows.Forms (which the WinPE UI stack
contract bans outright), and sits beside the existing Shell.BrowseForFolder
precedent in the same file. InjectedServiceDefault.Contract.Tests.ps1 passed in
the gate.

## Anti-patterns

None found in the phase's files. No TODO, FIXME, placeholder, empty handler or
log-only implementation. Every early return in the click handler is a documented
guard against a bubbled routed event, not an unimplemented branch. The new code
is clear of the PS 7-only syntax list.

The one honest omission, and it is written into the test file rather than left
implicit: **the SaveFileDialog itself is exercised by no Pester test** - it is
modal and a Pester run has no desktop. What is covered is the wiring on both
sides of it. 07-05-media-iso-picker.png is the only evidence the dialog opens,
and it is a photograph of the real one.

## Gaps Summary

**The three things the phase set out to fix are all fixed, and all three were
proved by something other than an assertion about themselves** - two photographs
of open drop-downs, a photograph of the native save dialog, and a round trip to
media.yaml and back that the verifier ran independently.

What is missing is the phase's own paperwork, and it is missing for a legitimate
reason: 07-05-03 task 3 is a checkpoint:human-verify with a blocking gate, and
task 4 - the DESIGN.md paragraph - comes after it. The executor stopped where it
was told to stop. So the two gaps are:

1. **docs/DESIGN.md 6.2.3 does not describe the pane it now has.** Four rows
   write, with three different controls, and one of those controls is a
   deliberate deviation from this console's own house pattern. That deviation is
   recorded in 07-05-01-PLAN.md, in 07-05-01-SUMMARY.md and in a comment in
   Get-HDTConsoleMediaNode.ps1 - but not in the authoritative design document,
   which is where a later consistency sweep would look before "fixing" it back
   to a tick box.
2. **No 07-05-03-SUMMARY.md.**

Neither blocks the milestone: M7's two exits were met on 2026-08-31 and
2026-09-03, and this phase changes no command, no template and no schema. Both
should close in the same sitting, once the four pictures are approved.

One further note, not a gap: 07-05-01-PLAN.md and 07-05-02-PLAN.md are modified
in the working tree and uncommitted. Those are another session's edits on this
same tree - the executor said it deliberately left them alone, and the diff is
additive (extra must_haves truths and extra evidence sections), so nothing was
removed.

---

_Verified: 2026-09-05_
_Verifier: Claude (gsd-verifier)_
