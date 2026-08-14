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

## W2, expanded — the Welcome screen, and MDT's Skip properties

Added by the user on 2026-08-14, and it is MDT's LiteTouch Welcome screen
rebuilt rather than a new invention:

> "the WINPE should have the Welcome screen that give us the ability to add a
> static ip\subnet\dg\DNS and the ability to add the Share and the creds with
> all of this as a Hide parameter like we have in MDT"

### The three things the Welcome screen offers

| Pane | Fields | MDT equivalent |
|---|---|---|
| **Static IP** | IP address, subnet mask, default gateway, DNS servers | LiteTouch's "Configure with Static IP Address" |
| **Deployment share** | DeployRoot | `Bootstrap.ini` `DeployRoot` |
| **Credentials** | UserID, UserDomain, UserPassword | `Bootstrap.ini` `UserID`/`UserDomain`/`UserPassword` |

### Every pane is hideable, exactly as MDT hides them

MDT's `Skip*` properties are the mechanism, and HDT keeps the names under its
own prefix so an MDT admin recognises them instantly:

| HDT rule | Hides |
|---|---|
| `HDTSkipWelcome` | the Welcome screen entirely |
| `HDTSkipStaticIp` | the static IP pane; DHCP is used |
| `HDTSkipDeployRoot` | the share box; `bootstrap.json`'s value is used |
| `HDTSkipCredential` | the credential pane; the embedded credential is used |

They resolve through the ordinary rules engine like any other variable, so a
site can set them in `rules.yaml` once and never see the wizard again - which
is precisely how MDT is used in practice.

#### ⚠ Correction: the Welcome screen's Skip rules cannot come from `rules.yaml`

**Found 2026-08-14 while implementing W2. The paragraph above is wrong, and
this is what replaces it.**

`rules.yaml` lives **on the deployment share**. The Welcome screen runs
**before the share is reachable** - configuring the network and collecting the
credential is *how* it becomes reachable. So a `HDTSkipWelcome` in `rules.yaml`
is a rule the machine cannot read until after the screen it was meant to skip
has already been shown.

**MDT has exactly this split and it is not an accident:**

| MDT file | Where it lives | What it can configure |
|---|---|---|
| `Bootstrap.ini` | inside the boot image | `SkipBDDWelcome`, `DeployRoot`, `UserID` |
| `CustomSettings.ini` | on the share | everything after connecting |

`SkipBDDWelcome` is in `Bootstrap.ini` **because it has to be**, and every
other `Skip*` property is in `CustomSettings.ini` because it can be.

So the four Welcome rules resolve from **`bootstrap.json`**, the file already
in the boot image, which `Get-HDTBootstrapConfiguration` already reads:

| Rule | Read from | Because |
|---|---|---|
| `HDTSkipWelcome` | `bootstrap.json` | decided before any share exists |
| `HDTSkipStaticIp` | `bootstrap.json` | the network is what reaches the share |
| `HDTSkipDeployRoot` | `bootstrap.json` | it *is* the share |
| `HDTSkipCredential` | `bootstrap.json` | it is what opens the share |

Every **later** pane - task sequence (W3), computer name (W4), summary (W5) -
runs after connecting and does resolve through the ordinary rules engine, which
is what the paragraph above was describing and where it is correct.

**Not yet implemented.** `bootstrap.json` needs a `skip:` block, the schema
needs it, `Update-HDTBootImage` needs to write it, and `Get-HDTWizardField`
needs to return pane visibility alongside field text. Nothing in the code
currently pretends otherwise.

**THE UNATTENDED PATH IS THE DEFAULT, NOT THE EXCEPTION.** An image built with
an embedded credential and a resolved `HDTTaskSequenceID` must still deploy with
nobody present: the E2E suite proves zero-keystroke deployment and it must not
start needing a human. So a pane appears only when it has something to ask, or
when a rule explicitly asks for it.

### Static IP in WinPE is WMI, not NetTCPIP

SPIKES S14 recorded that `Get-NetIPAddress` does not exist in a WinPE image
built from the ADK - the NetTCPIP module is not there. So the static IP pane
configures the adapter through `Win32_NetworkAdapterConfiguration`, which
`WinPE-WMI` guarantees:

    EnableStatic(address, mask)      SetGateways(gateway)
    SetDNSServerSearchOrder(dns)

A pane that configured the network with cmdlets that do not exist on the one
machine that matters would fail exactly where nobody could see it.
