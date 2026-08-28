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

## Nothing in this folder types into a virtual machine

**Every file here boots an image built by `Update-HDTBootImage`**, whose
`startnet.cmd` launches the payload named by `workspace.yaml`'s `entryCommand`.
No file sends keyboard input, and `tests/contract/NoKeystroke.Contract.Tests.ps1`
is what keeps that true.

It used to be true of `UnattendedDeployment.E2E` alone. The other two booted
SPIKES S1/S3's hand-built ISO, whose `startnet.cmd` launched nothing, so each
sent a `for %d in (C D E F G) do @if exist ...` line at the WinPE prompt — a
scan, because a payload on a data disk has no guaranteed letter. Both halves are
gone: the payload is staged INSIDE the image by `extraContent`, so it lives
under `X:`, the RAM disk, whose letter is fixed.

## The difference between the two deployment files

They deploy the same `DEMO-M3`/`DEMO-M4` steps in the same order to the same kind
of VM, and neither types. What still distinguishes them is **where the engine
comes from**:

| | `Deployment.E2E` (M3) | `UnattendedDeployment.E2E` (M4) |
|---|---|---|
| Boot image | built in the test, `entryCommand` pointing at this file's own launcher | built in the test, matched against its own manifest by hash |
| Where the engine loads from | the **content disk** — the thin-image topology, where the share carries the code | **inside the image**, staged by `Update-HDTBootImage` |
| The payload | `tests/e2e/payload/Start-HDTLabDeployment.ps1`, staged into the image by `extraContent` | `src/Hephaestus/Payload/Start-HDTDeployment.ps1`, the product's own |
| Deploy root | the launcher scans for the disk carrying `HDT\Modules\Hephaestus` | **discovered**: `Resolve-HDTDeployRoot` picks the volume carrying `rules.yaml`, and `RESULT.json` reports `deployRootSource` as `Discovered` |

**`Deployment.E2E.Tests.ps1` is kept, not superseded.** It is the record of what
M3 proved and it still passes; a milestone that deleted the evidence for the
previous one would leave nothing to compare against.

## Why "zero keystrokes" is provable and not merely asserted

Three independent proofs, because one would not be enough:

1. **No file here sends anything**, and that is checked in the *fast* suite.
   `tests/contract/NoKeystroke.Contract.Tests.ps1` scans every `.ps1` in this
   folder over both the comment-free token stream and the raw text, and it names
   the lab typing helper FIRST. That order is the finding of SPIKES S9.16: this
   project once answered "zero typing calls" after searching only for the two
   underlying WMI keyboard methods, while two files typed on every run through a
   helper that wraps them. A search for what an implementation eventually calls
   cannot find the callers of the thing that wraps it. The names themselves are
   spelled only in the contract file, so a plain `Select-String` over this folder
   still comes back empty. The contract also carries
   anti-vacuity floors, and was watched failing against a planted violation
   before being trusted green. A claim a suite makes about itself must be
   checkable without running it, or it is only true on the days somebody
   remembered to look.
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
gap.** `Default Switch` is Hyper-V's own shared NAT switch, not the deployment
subnet, and changing the segment under a phase that was verified on the isolated
one invalidates the verification rather than extending it.

## ⚠ Lab safety

**This host is the user's own machine**, and it carries VMs this repository did
not create. Damaging one is worse than failing a test. The protected set is
**everything not named `HDT-*`** — a prefix, not a list of names. This file used
to name two VMs; they were retired on 2026-08-29 and the named checks had been
protecting nothing for a while before anyone noticed.

Every rule in `PROJECT.md`'s "Hyper-V lab safety rules" is enforced **in code,
before any Hyper-V call**, by the helpers in `tests/helpers/HDTTestTools`:

1. Every Hyper-V command is written `Hyper-V\Get-VM` — PowerCLI shadows `Get-VM`
   on this host (SPIKES S8).
2. `Assert-HDTLabVmName` refuses a wildcard and anything not named `HDT-*`, and
   it runs before the first Hyper-V call in every VM helper.
3. No pipeline is ever unfiltered.
4. `HDT Lab` switch only, Generation 2 only, files under `C:\HDTLab\vms` only.
5. Memory: 4 GB per test VM, and the total assigned to running `HDT-*` VMs is
   checked against the 12 GB lab budget before one is started.
6. Every VM **not** named `HDT-*` is enumerated **before** the run and asserted
   identical **after**, in an `AfterAll` that runs even when the test failed.
   The count is asserted separately, so an empty host reads as "there was
   nothing to protect" rather than as "nothing was harmed".
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
DVD     the ISO this file builds with Update-HDTBootImage
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

**In `Deployment.E2E.Tests.ps1` and `WinPeSmoke.E2E.Tests.ps1` nothing starts it
but the image either.** Each builds its own, with `workspace.yaml`'s
`entryCommand` pointing `startnet.cmd` at its own payload — the M3 launcher and
the WinPE probe respectively — and `extraContent` staging that payload under
`X:\HDT` inside the image. Both then start the VM and only wait.

Each payload records `HDT_LAUNCHED_BY`, which the image's `startnet.cmd` sets and
nothing else does, and each file asserts it is `startnet`. So "nothing typed" is
answered by the guest rather than by the harness's own source.

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
the Windows ADK with the WinPE add-on, since every file here builds the image it boots.
`build.ps1 -Task e2e` throws a sentence naming whichever one is missing rather
than failing obscurely inside a test.

Set `HDT_REUSE_BOOT_IMAGE=1` to let the M4 file reuse an existing build **when
its manifest's hashes still match the artifacts on disk** — never on age alone.
Set `HDT_KEEP_LAB_VM=1` to leave the VM in place, powered off, for inspection.
