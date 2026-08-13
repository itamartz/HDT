# tests/e2e

Where HDT stops being asserted and starts being demonstrated.

```powershell
# elevated
./build.ps1 -Task e2e
```

Three files. The first makes the others' failures legible; the last is the
current exit criterion.

| File | Runs | Proves |
|---|---|---|
| `WinPeSmoke.E2E.Tests.ps1` | ~4 min | the engine loads and works **inside WinPE** — PowerShell 5.1, `powershell-yaml`, `Get-HDTMachineFact`, and the real `DEMO-M3` sequence parsing |
| `Deployment.E2E.Tests.ps1` | ~35 min | **ROADMAP M3's exit criterion**: a Generation 2 VM partitioned, imaged, unattended and boot-configured by a sequence run through `Invoke-HDTTaskSequence`, booting into Windows 11 |
| `UnattendedDeployment.E2E.Tests.ps1` | ~30 min | **ROADMAP M4's exit criterion, and the current one**: the same deployment, on a boot image **HDT built**, started by that image's own `startnet.cmd` — **with zero keystrokes sent to the machine** |

## The difference between the two deployment files

They deploy the same `DEMO-M3`/`DEMO-M4` steps in the same order to the same kind
of VM. Everything that distinguishes them is in **how the run starts**:

| | `Deployment.E2E` (M3) | `UnattendedDeployment.E2E` (M4) |
|---|---|---|
| Boot image | `C:\HDTLab\scratch\pe\HDTPE_x64_uefi.iso` — SPIKES S1/S3's **hand-built** artifact | built in the test by `Update-HDTBootImage`, matched against its own manifest by hash |
| How the engine starts | the harness types one line with `Send-HDTLabVmText` (SPIKES S4's `Msvm_Keyboard`) | **nothing types.** `startnet.cmd` runs `wpeinit` and then `X:\HDT\Start-HDTDeployment.ps1` |
| Who says it started itself | nobody can | the guest: `RESULT.json`'s `launchedBy` is `startnet`, set by `set HDT_LAUNCHED_BY=startnet` in the image |
| Deploy root | typed into the launcher line, which scans `C D E F G` | **discovered**: `Resolve-HDTDeployRoot` picks the volume carrying `rules.yaml`, and `RESULT.json` reports `deployRootSource` as `Discovered` |

**`Deployment.E2E.Tests.ps1` is kept, not superseded.** It is the record of what
M3 proved and it still passes; a milestone that deleted the evidence for the
previous one would leave nothing to compare against.

## Why "zero keystrokes" is provable and not merely asserted

Three independent proofs, because one would not be enough:

1. **The test file sends nothing**, and that is checked in the *fast* suite.
   `tests/unit/UnattendedDeploymentE2E.Tests.ps1` parses the E2E and asserts,
   over the comment-free token stream, that it names no `Send-HDTLabVmText`, no
   `TypeText`, no `TypeKey` and no `Msvm_Keyboard` — four assertions with four
   messages, so a failure says which one crept back in. A claim a suite makes
   about itself must be checkable without running it, or it is only true on the
   days somebody remembered to look.
2. **The guest says who started it.** `launchedBy` is set by the image's own
   `startnet.cmd` and by nothing else. A hand-typed launch leaves it empty.
3. **A run that did not start itself cannot look like success.** Nothing types,
   so if `startnet.cmd` failed to launch the payload the VM sits at a WinPE
   prompt and `Wait-HDTLabVmState -State Off` times out. That is the same
   discriminator SPIKES S3 used when it proved the no-prompt ISO by giving the
   VM nothing else to boot from.

## The gap M4 ships with, stated rather than implied

**No VM in this phase deploys over SMB.** `PROJECT.md` rule 2 keeps test VMs on
the isolated `HDT Lab` switch, and SPIKES S6 records that a VM there cannot reach
a share on the host. So the M4 image declares `provider: Local` and a
**volume-relative** `deployRoot` of `\Share`. The `Smb` provider's evidence is
05-02's unit refusals and its loopback integration run — not a lab deployment.

**Do not move a test VM to `HDT External` or `Default Switch` to close that
gap.** It would put the VM on a segment where `CM01`'s PXE responder can answer
it, which is what rule 3 exists to prevent.

## ⚠ Lab safety

**This host runs the user's live lab.** `CM01` is a Configuration Manager server
with a PXE responder; `DC01` is the domain controller. Damaging either is worse
than failing a test.

Every rule in `PROJECT.md`'s "Hyper-V lab safety rules" is enforced **in code,
before any Hyper-V call**, by the helpers in `tests/helpers/HDTTestTools`:

1. Every Hyper-V command is written `Hyper-V\Get-VM` — PowerCLI shadows `Get-VM`
   on this host (SPIKES S8).
2. `Assert-HDTLabVmName` refuses a wildcard, `CM01`, `DC01`, and anything not
   named `HDT-*`, and it runs before the first Hyper-V call in every VM helper.
3. No pipeline is ever unfiltered.
4. `HDT Lab` switch only, Generation 2 only, files under `C:\HDTLab\vms` only.
5. Memory: 4 GB per test VM, and the total assigned to running `HDT-*` VMs is
   checked against the 12 GB lab budget before one is started.
6. `CM01` and `DC01` are recorded **before** the run and asserted identical
   **after**, in an `AfterAll` that runs even when the test failed.
7. The VM is powered off and removed in that same `AfterAll`, unless
   `$env:HDT_KEEP_LAB_VM -eq '1'`.

## Why the content is on a disk and not a share

`PROJECT.md` requires the isolated `HDT Lab` switch. SPIKES S6 records that a VM
on an isolated switch **cannot reach a share on the host** — S6 used an External
switch to get around it, which the lab rules do not allow for a routine test.

A locally attached content disk removes SMB, DHCP and the host firewall from the
exit criterion entirely, so **a failure means the imaging code failed**. It is
also DESIGN 6.2's `Local` provider shape, one milestone early.

```
Disk 0  HDT-M3-Deploy-osdisk.vhdx    64 GB dynamic   the deployment target
Disk 1  HDT-M3-Deploy-content.vhdx    8 GB dynamic   the workspace and the engine
DVD     C:\HDTLab\scratch\pe\HDTPE_x64_uefi.iso      SPIKES S1/S3's image
```

`DEMO-M3` declares `minDiskGB: 60`, so the content disk is excluded from
candidacy **by size** and the target is unambiguous — the automatic selection
path, not the `diskNumber` override. `DiskPartition` *also* protects the content
disk **by drive letter**, so two independent rules stand between the engine and
the workspace it is reading its own instructions from.

## The launcher may not do any deployment work

`payload/Start-HDTLabDeployment.ps1` wires the real adapters and calls
`Invoke-HDTTaskSequence` **once**. `tests/unit/StartHDTLabDeploymentPayload.Tests.ps1`
parses it and fails if it names a Storage cmdlet, a DISM cmdlet, `bcdboot`,
`bcdedit`, `reagentc` or `diskpart`, or if it invokes a step function directly.

Without that test the exit criterion could be met by a launcher that partitioned
the disk itself — and nobody would notice, because the VM would still boot.

## How the run is started and how it is judged

**In `UnattendedDeployment.E2E.Tests.ps1` (M4) nothing starts it but the image.**
`Update-HDTBootImage` writes a `startnet.cmd` that runs `wpeinit` and then
`X:\HDT\Start-HDTDeployment.ps1`; the harness starts the VM and then only waits.

**In `Deployment.E2E.Tests.ps1` and `WinPeSmoke.E2E.Tests.ps1` (M3) the harness
types one line** at the WinPE prompt with `Send-HDTLabVmText` (SPIKES S4's
`Msvm_Keyboard`, filtered on the VM's **GUID**, not its friendly name), because
those two boot SPIKES S1/S3's hand-built image, whose `startnet.cmd` predates the
engine and drops to a shell. Both files say so.

The launcher shuts the machine down when the sequence ends, whatever the
outcome, so `Wait-HDTLabVmState -State Off` is how the harness knows the run
finished rather than guessing at a duration.

**That the machine reached full Windows is asserted from the
integration-services heartbeat, not from a screenshot.** WinPE carries no
integration services and never reports one; full Windows does. Screenshots are
saved under `C:\HDTLab\scratch\e2e\` for a human to look at — diagnosis, not
assertion.

## The assertion that must not be softened

The VM is started a second time **with the ISO still in the DVD drive and the
boot order untouched**. SPIKES S6's fourth finding is that a machine whose
firmware still prefers the boot media simply reboots into WinPE and the
deployment appears to loop; `ConfigureBoot`'s `SetBootOrderFirst` is what ends
it, and this is the only place it has ever run.

**If that assertion fails, do not fix it by ejecting the ISO from the host.**
Record what happened in `SPIKES.md`, use `Hyper-V\Set-VMFirmware` once as a
diagnostic to learn whether the machine boots when the media is demoted, and
report it as a gap in `ConfigureBoot` with the evidence. A phase that quietly
removed the DVD would ship a toolkit that loops back into WinPE on every real
deployment.

## Artifacts

| Path | What |
|---|---|
| `C:\HDTLab\scratch\e2e\smoke-*.png` | WinPE console during the smoke check |
| `C:\HDTLab\scratch\e2e\PROBE.json` | what the engine found inside WinPE — copied off the content disk **before** the VM is destroyed |
| `C:\HDTLab\scratch\e2e\deploy-0*.png` | the M3 deployment, from the WinPE prompt to the Windows desktop |
| `C:\HDTLab\scratch\e2e-m4\m4-0*.png` | the M4 deployment. **`m4-01-winpe.png` is the one to open**: it must show the engine already running, never a bare `X:\Windows\System32>` prompt |
| `C:\HDTLab\scratch\e2e-m4\RESULT.json` | the M4 run's own account of itself — `launchedBy`, `deployRootSource`, `resolvedDeployRoot`, `endedWith` — copied off the content disk **before** the VM is destroyed |
| `C:\HDTLab\scratch\e2e-m4\HDT.jsonl`, `state.json`, `LAUNCHER.log` | the evidence every M4 assertion rests on, persisted because the `AfterAll` destroys the disk it came from |
| `C:\HDTLab\scratch\e2e-bootimage\Share\Boot\` | the boot image the M4 run built and booted |

## Preconditions

Elevation, the Hyper-V module, the staged Windows 11 media, and about 30 GB free.
For a boot vehicle, **either** the Windows ADK with the Windows PE add-on — so
`UnattendedDeployment.E2E.Tests.ps1` can build its own with
`Update-HDTBootImage` — **or** a prebuilt
`C:\HDTLab\scratch\pe\HDTPE_x64_uefi.iso` for the two M3 files.
`build.ps1 -Task e2e` throws a sentence naming whichever one is missing rather
than failing obscurely inside a test.

Set `HDT_REUSE_BOOT_IMAGE=1` to let the M4 file reuse an existing build **when
its manifest's hashes still match the artifacts on disk** — never on age alone.
Set `HDT_KEEP_LAB_VM=1` to leave the VM in place, powered off, for inspection.
