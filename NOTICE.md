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
| `src/Hephaestus/Payload/Remove-HDTAgentTree.ps1` and `src/Hephaestus/Private/Start-HDTAgentRemoval.ps1` | `Scripts/PSDStart.ps1` lines 1005 and 1033, and `Scripts/PSDFinal.ps1` lines 30, 53-62 and 71-84 | The mechanism for deleting the folder the deployment is running out of. A process cannot delete its own staging root: HDT prepends `C:\HDT\Modules` to `PSModulePath`, powershell-yaml `LoadFile()`s `YamlDotNet.dll` from there, and Windows PowerShell 5.1 cannot unload an assembly for the life of the process - so a recursive delete from inside throws part way and leaves a half-deleted tree. PSD's answer, derived here in full: copy the finishing script **out** of the doomed tree into `%TEMP%` (`PSDStart.ps1:1005`), start it detached with the parent's process id (`:1033`), and have it stop that parent **first** (`PSDFinal.ps1:30`) before removing the tree (`:53-62`). The consequence is derived too - because the parent is dead by then, the **finish action has to move into the deleter** (`PSDFinal.ps1:71-84`), or the machine restarts before the delete lands. MDT does the same shape in VBScript (`LiteTouch.wsf:1257-1259` launches `LTICleanup.wsf` as a separate process); its self-delete works only because a `.wsf` is not held open, and HDT's is. Not derived: the refusal that guards the target, the injected script blocks that make the order testable, and the in-process destruction of the share credential before the handoff |
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
| `src/Hephaestus/Public/New-HDTProcessService.ps1`, `Start`; `src/Hephaestus/Public/New-HDTImageService.ps1`, `ApplyUnattend` | `Scripts\ZTIUtility.vbs`, function `RunCommandLog`, lines 2173-2261 | The **poll-scrape-tick** shape for running an external tool that can occupy a deployment for minutes: launch with `WshShell.Exec` and spin on `oExec.Status` with `SafeSleep 100` rather than blocking on `oShell.Run(cmd, 0, True)`; scrape the tool's own percentage out of stdout as it goes (`StandardConsoleProcessing`, the DISM meter pattern `([01]?[0-9]?[0-9])\.[0-9]\%` at `:2261`); and write a **timed heartbeat of the loop's own** for the case where the tool says nothing. HDT does all three. PSD took the other road — `Start-Process -Wait` throughout, `PSDUtility.psm1:1170` — and has exactly the freeze this closes |
| `src/Hephaestus/Private/New-HDTStepHeartbeat.ps1` | `Scripts\ZTIUtility.vbs`, function `Heartbeat`, lines 2229-2237 | That the periodic record is written by the WAIT LOOP and rationed by a clock rather than by how often the loop spins, so a command that returns quickly writes nothing. MDT's interval is five minutes and event 41003; HDT's is fifteen seconds, because MDT's bar is repainted from scraped stdout about once a second anyway and HDT's heartbeat is the only thing moving during a silent pass |
| `src/Hephaestus/Public/New-HDTImageService.ps1`, `ApplyUnattend` progress | `Scripts\LTIApply.wsf`, line 1042 | Recorded as **confirmation of an absence**: MDT reports a flat `99` immediately before shelling `dism.exe /Apply-Unattend` rather than driving a bar from the tool's output, which is the same conclusion HDT reached by measurement — dism prints no percentage meter for that verb |
| `src/Hephaestus/Public/Steps/Invoke-HDTSysprepStep.ps1` | `Scripts\LTISysprep.wsf`, line 257 and lines 272-278 | The **command line and the check that follows it**. The switches are `/quiet /generalize /oobe /quit` — never `/shutdown` — with `/unattend:%SystemRoot%\system32\sysprep\unattend.xml` appended only when an answer file has been staged there, and that file deleted afterwards so it does not travel inside the captured image. And then the fact that matters more than the switches: MDT does **not** trust sysprep's exit code. It reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State\ImageState` and refuses unless it reads `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`, because sysprep can return 0 having declined to generalize. Also observed: the refusal of a domain member by `Win32_ComputerSystem.DomainRole`, and the once-only sentinel that stops a machine with queued file renames rebooting for ever. Not carried across: MDT's Office 2010/2013/2016 rearm triple and its `DoCapture=PREPARE` branch |
| `src/Hephaestus/Public/Steps/Invoke-HDTCaptureImageStep.ps1`, `src/Hephaestus/Templates/Capture/wimscript.ini` | `Scripts\ZTIBackup.wsf`, line 427 | That **every** capture is handed an exclusion list — MDT resolves `<DeployRoot>\Tools\<Architecture>\wimscript.ini` and quotes it into both its `/Capture-Image` and `/Append-Image` branches — because without `/ConfigFile:` a capture swallows `pagefile.sys`, `hiberfil.sys`, `System Volume Information` and the deployment's own scratch folders into the reference image, and DISM reports that as success. HDT ships its list inside the module so it travels into every boot image with the rest of `Templates\`; a share may override it with `Control\wimscript.ini`. Not carried across: MDT's `\MININT` and `\_SMSTaskSequence` entries, which are replaced by HDT's own `\HDT` (rule 4) |
| `src/Hephaestus/Private/Get-HDTBcdCommand.ps1`, `src/Hephaestus/Private/Get-HDTLocalWinPePlan.ps1`, `src/Hephaestus/Public/Steps/Invoke-HDTBootToWinPEStep.ps1`, `New-HDTImageService.AddRamdiskBootEntry` / `SetBootSequenceOnce` / `RemoveBootEntry` | `Scripts\ZTIBCDUtility.vbs`, lines 85-99 (`CreateRamDiskEntryEx`), 108-160 (`CreateNewBCDEntryEx`) and 163-172 (`AdjustBCDDefaults`); `Scripts\LTIApply.wsf`, `InstallPE` lines 159-410; `Scripts\LTICleanup.wsf` lines 119-121; `Templates\Client.xml` lines 463 and 472 | The **whole FullOS -> WinPE transport**, which has no PowerShell prior art at all - PSD's is an explicit stub (`PSDTBA.ps1 /capture`). Carried across: staging a real boot image to the local disk; the `{ramdiskoptions}` object with `ramdisksdidevice` / `ramdisksdipath`; the OSLOADER entry with `device` and `osdevice` set to `ramdisk=[<drive>]<path>,{ramdiskoptions}`, plus `path`, `systemroot`, `detecthal yes` and `winpe yes`; a FIXED entry GUID so a later leg can name it; the explicit `bcdedit /delete <id> /cleanup` teardown; and MDT's split of the work into a stage half and a BCD half around `LTISysprep.wsf`. **Three deliberate divergences, each measured or reasoned rather than inherited.** (1) `AdjustBCDDefaults` sets `/bootsequence` AND `/default` AND `/displayorder /addfirst` AND `/timeout 0`, so MDT's is not a one-shot and a machine that never reaches `LTICleanup` boots WinPE for ever; HDT sets `/bootsequence` alone, leaving `{default}` naming Windows, so the same machine degrades to booting Windows. (2) `InstallPE` (:295-308) robocopies the ADK's `efi\` and `Boot\` trees over the boot drive and renames `bootx64.efi` to `BootMgFW.efi` - replacing the machine's boot manager with the ADK's copy, which SPIKES S20 measured at SVN 3.0 against an enforced Secure Boot floor of 7.0. HDT copies no loader at all and lets the existing boot manager load the ramdisk entry as an OSLOADER application, so the Secure Boot chain gains nothing new. (3) MDT arms AFTER sysprep; HDT arms before, because a machine sealed by sysprep that cannot reach WinPE is stranded. Not carried across: MDT's `bootsect.exe /nt60` downlevel branch, its multicast WIM transfer, and its `C:\MININT` script copy (rule 4) |
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
