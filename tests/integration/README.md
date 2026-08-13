# tests/integration

The first place HDT's code touches a real disk.

Everything in `tests/unit` and `tests/contract` runs against hand-written fakes,
which is what makes those suites take seconds and run on any machine. This
directory is where the fakes are checked against the world: real `Get-Disk`,
real `Clear-Disk`, real `Initialize-Disk`, real `Expand-WindowsImage`, real
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
| An **elevated** session | mounting VHDXs, clearing and partitioning disks | `build.ps1` throws a sentence naming it |
| The **Hyper-V PowerShell module** | `New-VHD` creates the scratch VHDX | `build.ps1` throws a sentence naming it |
| `C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim` | the real image the apply tests apply | `build.ps1` throws a sentence naming it |
| About **25 GB free** on `C:` | a 40 GB dynamic VHDX with Windows 11 expanded into it | the apply fails partway |
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

## What is deliberately not here

`SetBootOrderFirst` edits the **firmware boot order of the machine it runs on**,
and that machine is the developer's. It is exercised for the first time inside
the VM in `tests/e2e`, not here. That is a gap in this directory's coverage and
it is named rather than papered over.
