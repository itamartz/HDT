# tests/e2e

Where HDT stops being asserted and starts being demonstrated.

```powershell
# elevated
./build.ps1 -Task e2e
```

Two files, and the first one exists to make the second one's failures legible.

| File | Runs | Proves |
|---|---|---|
| `WinPeSmoke.E2E.Tests.ps1` | ~4 min | the engine loads and works **inside WinPE** — PowerShell 5.1, `powershell-yaml`, `Get-HDTMachineFact`, and the real `DEMO-M3` sequence parsing |
| `Deployment.E2E.Tests.ps1` | ~35 min | **ROADMAP M3's exit criterion**: a Generation 2 VM partitioned, imaged, unattended and boot-configured by a sequence run through `Invoke-HDTTaskSequence`, booting into Windows 11 |

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

The boot image's `startnet.cmd` predates the engine, so the harness types one
line at the WinPE prompt with `Send-HDTLabVmText` (SPIKES S4's `Msvm_Keyboard`,
filtered on the VM's **GUID**, not its friendly name). Wiring the engine into
`startnet.cmd` is M4's `Update-HDTBootImage`.

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
| `C:\HDTLab\scratch\e2e\deploy-0*.png` | the deployment, from the WinPE prompt to the Windows desktop |

## Preconditions

Elevation, the Hyper-V module, `C:\HDTLab\scratch\pe\HDTPE_x64_uefi.iso`, the
staged Windows 11 media, and about 30 GB free. `build.ps1 -Task e2e` throws a
sentence naming whichever one is missing rather than failing obscurely inside a
test.
