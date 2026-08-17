# tests/integration

The first place HDT's code touches a real disk.

Everything in `tests/unit` and `tests/contract` runs against hand-written fakes,
which is what makes those suites take seconds and run on any machine. This
directory is where the fakes are checked against the world: real `Get-Disk`,
real `Clear-Disk`, real `Initialize-Disk`, real `dism /Apply-Image`, real
`bcdboot`.

```powershell
# elevated
./build.ps1 -Task integration
```

## It is not part of `ci`, and it must not become part of it

`./build.ps1 -Task ci` runs `clean`, `build`, `lint`, `test`, `selfcheck` — the
five that need nothing but a clone. DESIGN 12.2.5 puts integration on pushes to
`main` and E2E nightly; wiring that up is M4's problem. A CI worker has no
elevated session, no 25 GB of scratch and no staged Windows media.

`tests/unit/BuildScript.Tests.ps1` asserts this by parsing `build.ps1`: `ci`
expands to the five canonical tasks and `Invoke-HDTTest`'s `Run.Path` names only
`tests/unit` and `tests/contract`. The first person to add `tests/integration`
to that list turns a two-second suite into a twenty-minute one.

## Preconditions

| Needed | Why | What happens without it |
|---|---|---|
| An **elevated** session | mounting VHDXs and WIMs, clearing and partitioning disks | `build.ps1` throws a sentence naming it |
| The **Hyper-V PowerShell module** | `New-VHD` creates the scratch VHDX | `build.ps1` throws a sentence naming it |
| `C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim` | the real image the apply tests apply | `build.ps1` **warns**; the files that apply an image skip themselves |
| The **Windows ADK** (Deployment Tools + WinPE add-on) | the real boot image build | `build.ps1` **warns**; `BootImage.Integration.Tests.ps1` skips itself |
| **`powershell-yaml`** installed | it is staged into the boot image | `BootImage.Integration.Tests.ps1` skips itself |
| About **25 GB free** on `C:` | a 40 GB dynamic VHDX with Windows 11 expanded into it | the apply fails partway |
| About **8 GB free** on `C:` | the boot image build's own scratch | `BootImage.Integration.Tests.ps1` skips itself |
| The drive letters **`S:`, `W:` and `R:` free** | see below | the file **skips itself** with a warning naming the letter that is in use |

### The fixed drive letters are a real constraint

`uefi-standard` names `S`, `W` and `R`, and `Invoke-HDTDiskPartitionStep` uses
the layout as written. There is no "pick a free letter" logic anywhere, by
design: the letters on the machine being *built* are fixed, and a deployment
that guessed would be a deployment that could not be reproduced.

On the host running the tests those three letters may be taken by something
else. So the `BeforeAll` of every file that partitions a disk checks them and
**skips the whole file with a warning naming the letter that is in use** — it
does not fail obscurely inside `SetPartitionDriveLetter`, and it certainly does
not format whatever is already there.

## No integration test writes to a disk it did not create

This is the rule the whole directory rests on.

Every destructive test creates its own VHDX under
`C:\HDTLab\scratch\integration\` with `New-HDTLabScratchDisk`, asserts the disk
number it was handed is neither `IsBoot` nor `IsSystem`
(`Assert-HDTLabScratchDisk`, unit-tested against this host's own captured disk
row), and destroys it in an `AfterAll` that **runs even when the tests failed**.

`C:\HDTLab\scratch\integration` is empty when the suite finishes. If it is not,
a run was interrupted; `Remove-HDTLabScratchDisk` on the leftover path
dismounts and deletes it.

The one test that runs against **this machine's** real disks is a *refusal*:
`Select-HDTTargetDisk` is asked for a target on a host whose only disk is the
one it booted from, and must answer `HDTNoTargetDiskError`. It is safe precisely
because the assertion is that nothing happens.

## What is here

| File | Proves |
|---|---|
| `DiskService.Integration.Tests.ps1` | the destructive half of `IDiskService` against a scratch VHDX — including `Initialize-Disk` creating the MSR nobody asked for (SPIKES S6) |
| `DiskPartition.Integration.Tests.ps1` | `Invoke-HDTDiskPartitionStep` end to end with real services, and that `-WhatIf` writes nothing |
| `ImageService.Integration.Tests.ps1` | a real Windows 11 apply, `bcdboot`, `reagentc`, and the unattend Setup will read. Tagged `Slow` — the apply alone takes minutes |
| `SmbContentProvider.Integration.Tests.ps1` | a real SMB mapping over loopback, and the identity the provider reads back off it |
| `BootImage.Integration.Tests.ps1` | a real boot image: nine cabs into a real WIM, a real `oscdimg` ISO, and the DESIGN 6.1.1 equivalence hash |
| `PxePayload.Integration.Tests.ps1` | `New-HDTPxePayload` staging the real ADK media tree and the real boot WIM, hash-verified file by file — **staging completeness, not bootability** |
| `WinPeContent.Integration.Tests.ps1` | **what WinPE ships and what it does not**: `wpeutil.exe` present and `shutdown.exe` ABSENT, read out of the real ADK `winpe.wim` and out of HDT's own built image. It is the fact `Get-HDTPowerCommand` rests on, and it asserts a known-present file in the same mount so the absence can never be an artefact of looking in the wrong place |

**Run this suite under `powershell.exe` as well as `pwsh`.** It is not the same
run: 5.1 turns a native tool's stderr into terminating errors when
`$ErrorActionPreference` is `Stop`, and the first 5.1 run of this suite — in
05-06, long after the code shipped — died on **oscdimg's progress meter**
(SPIKES S13.5). `-Task test` had always been run under both engines, but `test`
is not the suite that shells out.

## The boot image build, and what it costs

`BootImage.Integration.Tests.ps1` is the only file here that needs the **ADK**
rather than a disk. It builds **twice** into two scratch workspaces under
`C:\HDTLab\scratch\bootimage\` — once fully, once with `-SkipIso` — then
**re-mounts the WIM it produced, read-only**, and asserts from the files inside
it rather than from the build's own claims.

Measured on this host (ADK 10.1.26100.2454, nine optional components):

| | Time | Result |
|---|---|---|
| Full build (WIM + ISO) | **123 s** | `HDTPE_x64.wim` **495 340 358 B**, `HDTPE_x64.iso` **550 916 096 B** |
| `-SkipIso` build | **120 s** | WIM only, manifest records `iso.skipped: true` |
| **Whole file, both builds plus the read-only re-mount** | **291 s** | 24 tests |

**The ISO leg costs about two seconds**, not the "slow half of the build" DESIGN
5.1 used to claim — corrected there in 05-04. The time goes on the mount, the
eighteen cabs and `Export-WindowsImage -CompressionType Max`.

The second build is a **full second build**, not a reuse of the first: the
implementation exports from its own scratch WIM, and pretending otherwise would
mean asserting that `-SkipIso` skipped work it never did. Two minutes is the
honest price of proving `-SkipIso` skips exactly one thing.

The two central assertions are worth naming, because they are what the file
exists for:

- **`startnet.cmd` is read back out of the mounted image** and compared, line by
  line, with `Get-HDTStartnetScript`'s output. The unit suite asserts what the
  builder *wrote*; this asserts what is *in the image*.
- **The WIM inside the ISO hashes identical to the standalone WIM** (DESIGN
  6.1.1, named explicitly in ROADMAP M4). Asserted three ways — the file on
  disk, `sources\boot.wim` inside the mounted ISO, and the manifest's
  `isoBootWimSha256` — because a manifest that agreed with itself but not with
  the disk would be worse than none.

Set `HDT_KEEP_BOOT_IMAGE=1` to keep the scratch mount and work directories for
inspection; the artifacts under `…\Share\Boot\` are left in place either way.

## What is deliberately not here

`SetBootOrderFirst` edits the **firmware boot order of the machine it runs on**,
and that machine is the developer's. It is exercised for the first time inside
the VM in `tests/e2e`, not here. That is a gap in this directory's coverage and
it is named rather than papered over.
