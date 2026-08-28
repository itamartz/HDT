# NOTICE

The Hephaestus Deployment Toolkit contains code derived from third-party
projects. Their notices are reproduced below, as their licences require.

HDT itself depends on, installs and ships **no Microsoft Deployment Toolkit
component** — that constraint is the reason HDT exists, and it is enforced by
`tests/contract/NoMdtDependency.Contract.Tests.ps1`. The attribution below is to
a separately licensed open-source project, not to MDT.

---

## PSD — PowerShell Deployment Extension Kit (friendsOfMDT)

<https://github.com/FriendsOfMDT/PSD>

PSD is MIT licensed, so reuse is permitted with attribution. HDT mines it for
*mechanism* — which CIM property actually yields which fact, which registry
value Winlogon really reads, which DISM argument works on real hardware — and
not for structure: PSD is procedural and calls hardware directly, while HDT
takes injected services so the engine can run under test with no machine
attached.

### Files in this repository containing derived logic

| File | Derived from | What was derived |
|---|---|---|
| `src/Hephaestus/Public/Get-HDTMachineFact.ps1` | `Scripts/PSDGather.psm1`, function `Get-PSDLocalInfo` | The chassis-type classification tables (laptop 8, 9, 10, 11, 12, 14, 18, 21; desktop 3, 4, 5, 6, 7, 15, 16; server 23), the virtual-machine manufacturer list, and the `PROCESSOR_ARCHITEW6432` over `PROCESSOR_ARCHITECTURE` precedence |
| `src/Hephaestus/Public/New-HDTWizardHost.ps1` | `Scripts/PSDWizard.psm1` and `Scripts/PSDWizardNew.psm1` | The technique for showing a WPF window inside WinPE: `Add-Type -AssemblyName PresentationFramework` followed by `XamlReader::Load` over an `XmlNodeReader`, with markup that carries no `x:Class` and handlers attached by `FindName` afterwards. PSD is the proof that this works in WinPE at all; the window, its contents and every decision about what a click means are HDT's own |
| `src/Hephaestus/UI/HDTWizardShell.xaml` | `Scripts/PSDWizardNew/Themes/Classic/PSDWizard_Template_Classic_en-US.xaml` | The LiteTouch wizard's *layout*: a coloured rail down the left listing the pages, the current page's content to the right of it, and Back / Next / Cancel along the bottom. An MDT admin already knows this shape, which is the whole reason it is copied. Not copied: PSD's template declares an `x:Class` and merges six `ResourceDictionary` files by `Source=`; neither survives WinPE, so this shell declares no code-behind class and names no other file at all |
| `src/Hephaestus/UI/HDTFailure.xaml` | `Scripts/PSDWizardNew.psm1` (line 760, and again at 2995) and `Scripts/PSDStartLoader.psm1` (lines 2352 and 2780) | The rule that a WinPE window must not outrank the command prompt a technician opens from it. PSD assigns `Topmost = $False` on the line before *every* `ShowDialog()` — its own comment reads "always force windows on bottom" — binds Esc to lower the window (`PSDWizardNew.psm1:2764-2767`), and treats topmost as a runtime flag (`$syncHash.TopMost`) rather than as markup. HDT reached the same finding on a bench, where "Open CMD" opened the prompt *behind* the failure screen, and the fix here is to take the `Topmost="True"` attribute out rather than to clear it at runtime. The lesson was derived; no code was |
| `tests/contract/WinPeWindowReach.Contract.Tests.ps1` | the same PSD lines as `HDTFailure.xaml` above | That same lesson, generalised from one file into a contract over every window under `src/Hephaestus/UI` (CLAUDE.md rule 8): no window sets `Topmost` in markup and no host sets `.Topmost = $true` at runtime, save one allow-listed board that outlives WinPE. PSD supplied the observation and the reason for it; the glob, the allow-list and the drag-banner half of the file are HDT's own |
| `src/Hephaestus/Templates/unattend.xml` | `Templates/Unattend_x64.xml`, lines 124-131 | The `offlineServicing` placement of `Microsoft-Windows-PnpCustomizationsNonWinPE`, and the `DriverPaths` / `PathAndCredentials` shape with `wcm:keyValue="1" wcm:action="add"` and a `Path` of `\Drivers` — image-root-relative, so it resolves to the folder `ApplyDrivers` stages to. The same block appears in MDT's own template (below); PSD is the MIT-licensed copy of it |
| `src/Hephaestus/Public/New-HDTImageService.ps1`, `ApplyUnattend` | `Scripts/PSDConfigure.ps1`, line 151 | That the staged answer file must be **applied to the offline image** for its `offlineServicing` pass to run at all, and that DISM needs an explicit scratch directory off the WinPE RAM disk. PSD spells it `Use-WindowsUnattend -UnattendPath … -Path "<OSVolume>:\" -ScratchDirectory …`; HDT shells `dism.exe` instead, because `dism.exe` is in WinPE as shipped while the DISM cmdlets need the `WinPE-DismCmdlets` optional component |

The derived facts are also recorded on the derived thing itself — a `.NOTES`
block on a function, a comment header on markup or on a contract test — so a
reader of the code finds the attribution without opening this file.

---

## Microsoft Deployment Toolkit — facts read, nothing carried across

MDT is a Microsoft product, not an open-source one, and it is **not** licensed
for reuse the way PSD is. Nothing here is copied from it. What is recorded below
is *what its scripts were observed to do* — an argument order, a pass name, a
registry location — read off an installed copy in the same way its documentation
would be read, and then implemented independently in PowerShell.

This changes nothing about CLAUDE.md rule 4 and PROJECT constraint 4. HDT
**requires no MDT component at any point**: not to build, not to test, not to
run a deployment. No `MicrosoftDeploymentToolkit` module, `MDTProvider` drive,
`Microsoft.BDD.*` assembly, `ZTI*`/`LTI*` script, `ts.xml` or MDT `Control\`
layout is imported, invoked, shipped or depended on, and
`tests/contract/NoMdtDependency.Contract.Tests.ps1` enforces exactly that. The
paths below are where the observation was made on one developer's machine; they
are not paths any code here resolves.

| File in this repository | Observed in | The fact |
|---|---|---|
| `src/Hephaestus/Templates/unattend.xml` | `Templates\Unattend_x64.xml`, lines 168-175 | That `Microsoft-Windows-PnpCustomizationsNonWinPE` belongs in the **`offlineServicing`** pass, and that its `Path` is the driveless, image-root-relative `\Drivers`. MDT and PSD agree line for line, which is what settled the pass after it had been shipped in `specialize` and refused by Windows Setup |
| `src/Hephaestus/Public/New-HDTImageService.ps1`, `ApplyUnattend` | `Scripts\LTIApply.wsf`, function `ApplyUnattend`, lines 1021-1043 | That the answer file is copied into `Windows\Panther` **and then applied to the still-offline OS**, with the argument shape `dism.exe /Image:<volume>\ /Apply-Unattend:<file> /ScratchDir:<scratch>`; that the document applied is the staged one, so the answer file's relative `\Drivers` resolves against the image root; and that the scratch folder is created deliberately because WinPE's RAM disk has no room for servicing. MDT's own comment on the line — "This takes care of driver injection and servicing" — is what identifies this call as the mechanism that installs staged drivers |
| `src/Hephaestus/Public/Steps/Invoke-HDTApplyUnattendStep.ps1` | the same lines | That staging and applying are two operations and a deployment does both |
| `docs/DESIGN.md` §drivers | `Scripts\ZTIDrivers.wsf`, lines 446 and 527 | That MDT *also* writes `DevicePath` into the offline `SOFTWARE` hive (`:527`), while its sibling `UpdateOEMPath` (`:446`) writes `OemPnPDriversPath` into a `sysprep.inf` and is therefore downlevel only. Recorded as the road **not** taken: HDT installs drivers through the answer file alone |

### MIT License

```
MIT License

Copyright (c) 2020

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
