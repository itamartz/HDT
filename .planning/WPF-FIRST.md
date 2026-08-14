# The WPF-first direction

**Decided 2026-08-14 by the user, and it REPLACES the phase order in ROADMAP.md
from here on.** M6/M8 are not "later" any more; the UI leads and the engine
follows it.

> "I want the WPF come alive and each step we will add something to the WPF
> (with PS command in the backend) and then we test it as Unit and on a VM and
> we move forwards step by step."

## Why this replaces the previous order

The previous order built the whole engine first and left both UIs to the end.
That is how the project ended up with 4,900 tests, a working deployment, and
nothing a technician could look at - and it is why the direction kept drifting:
there was no visible increment to check the work against.

Every increment below ends with **something on a screen**, so progress is
observable without reading a test report.

## The rule for every increment

Each one is a complete slice, in this order, and nothing moves on until all
four are done:

1. **XAML + a `Verb-HDTNoun` backend command.** The command holds the logic and
   is callable without the window; the XAML holds no logic worth testing.
2. **Unit tests** against the backend command, with fakes. XAML rendering is not
   unit tested - the separation is what makes that acceptable.
3. **On a VM**, in real WinPE, launched by `startnet.cmd` through the boot
   image's `entryCommand`. A screenshot is the evidence.
4. **One commit**, and the increment is named in the commit subject.

## Increments - the technician wizard (MDT's LiteTouch equivalent)

| # | What appears on screen | Backend | Proves |
|---|---|---|---|
| **W1** | a window, a title, Next/Cancel | `Show-HDTWizard` | WPF renders in WinPE at all, and `startnet.cmd` can launch it |
| **W2** | deployment share + credentials: **UserID, UserPassword, UserDomain** | `Get-HDTWizardCredential` | MDT's Bootstrap.ini quartet, prefilled from `bootstrap.json`, validated by actually connecting |
| **W3** | task sequence picker | `Get-HDTWizardSequence` | reads `TaskSequences\` off the share and sets `HDTTaskSequenceID` |
| **W4** | computer name | `Get-HDTWizardComputerName` | prefilled from the rules, with the 15-character NetBIOS refusal visible |
| **W5** | summary, and a Deploy button | `Start-HDTWizardDeployment` | the wizard hands the engine a resolved variable set |
| **W6** | progress: current step, N of M, elapsed | `Write-HDTStatus` -> the window | replaces console output during the sequence |

W1 is deliberately almost nothing. Its whole job is to fail fast if WPF does not
render in this WinPE build, before any wizard logic exists to throw away.

## What stays true

- **Windows PowerShell 5.1** in everything that runs in WinPE. WPF is loaded
  through `Add-Type -AssemblyName PresentationFramework` and `XamlReader`, which
  is what PSD does (`Scripts/PSDWizard.xaml`, `PSDWizardNew.psm1`) - the proof
  that this works inside WinPE at all.
- **`WinPE-NetFx` is what makes it possible** and is already in the required
  component set, so no boot image change is needed for W1.
- **TDD.** The backend command has a failing test before it exists. The XAML
  does not.
- **The wizard is skippable.** MDT's `SkipBDDWelcome=YES` equivalent: an image
  built with an embedded credential and a resolved `HDTTaskSequenceID` must
  still deploy with nobody present, because that is what the E2E suite proves
  and it must not start needing a human.
