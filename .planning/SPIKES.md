# Verified environment findings

Empirical results from spikes run on this machine. **These are verified by
execution, not assumed.** Where one contradicts an assumption in `docs/DESIGN.md`,
the design has been corrected.

Date: 2026-08-12 · Host: LAP-AMMSO01 · ADK 10.1.26100.2454

---

## S1 — PowerShell runs in WinPE, and so does CIM ✅

**The single most important premise of HDT, now proven.** Built a WinPE image
with the standard OC set, booted it in a Gen2 Secure Boot VM, and ran:

```
X:\Windows\System32>powershell -NoProfile -C "$PSVersionTable.PSVersion.ToString(); (Get-CimInstance Win32_ComputerSystem).Model; 'HDT-PS-OK'"
5.1.26100.1
Virtual Machine
HDT-PS-OK
```

Confirmed:

- **PowerShell 5.1.26100.1** starts and runs in WinPE.
- **`Get-CimInstance` works in WinPE** — phase 02's entire fact-gathering
  (`ICimProvider`, `Win32_ComputerSystem`, etc.) is viable as designed.
- Boot to prompt took well under 100 s on 2 vCPU / 4 GB.

**OC install order used, all succeeded, each with its `en-us` language pack:**

```
WinPE-WMI -> WinPE-NetFx -> WinPE-Scripting -> WinPE-PowerShell
  -> WinPE-StorageWMI -> WinPE-DismCmdlets -> WinPE-SecureStartup
  -> WinPE-EnhancedStorage -> WinPE-WDS-Tools
```

Notes:
- The cab is `WinPE-NetFx.cab` (lowercase `x`), not `WinPE-NetFX.cab`.
- Every OC above has an `en-us` counterpart at `WinPE_OCs\en-us\<name>_en-us.cab`.
  Some other OCs (e.g. `WinPE-FMAPI`) have none — do not assume one exists.
- Resulting `boot.wim` **480 MB**, ISO **533 MB**.

---

## S2 — `oscdimg -bootdata:` cannot take quoted paths ⚠

**This will bite phase 05.** The ADK lives under `C:\Program Files (x86)\…
\Assessment and Deployment Kit\…`, which contains spaces. Passing quoted paths
inside `-bootdata:` from PowerShell produces doubled quotes and fails:

```
ERROR: Could not open boot sector file ""C:\Program Files (x86)\...\etfsboot.com""
Error 123: The filename, directory name, or volume label syntax is incorrect.
```

**Verified fix:** stage the boot bits to a space-free directory first, then build
the `-bootdata:` argument with unquoted paths.

```powershell
$bits = 'C:\HDTLab\scratch\bootbits'          # any path without spaces
Copy-Item "$osc\etfsboot.com","$osc\efisys_noprompt.bin" $bits -Force

# UEFI only, no keypress  (the HDT default)
& oscdimg.exe -m -o -u2 -udfver102 `
  "-bootdata:1#pEF,e,b$bits\efisys_noprompt.bin" $media $iso

# Dual BIOS + UEFI, no keypress on the UEFI leg only
& oscdimg.exe -m -o -u2 -udfver102 `
  "-bootdata:2#p0,e,b$bits\etfsboot.com#pEF,e,b$bits\efisys_noprompt.bin" $media $iso
```

Both verified working (100% complete, 533 MB output).

`New-HDTBootIso` must do this staging internally — it cannot assume a
space-free ADK path.

---

## S3 — `-NoPromptForKey` verified end to end ✅

A VM booted the `efisys_noprompt.bin` ISO **straight into WinPE with no
keypress**, on Generation 2 with Secure Boot **On** (`MicrosoftWindows`
template). Confirms both the no-prompt mechanism and that the image is Secure
Boot compatible.

Discriminator for the test: the VM had no VHD, so boot order was DVD → Network.
Had the ISO prompted, it would have timed out to network boot and failed with no
boot device. Reaching a WinPE prompt proves the DVD auto-booted.

`efisys_noprompt.bin` lives in `Deployment Tools\<arch>\Oscdimg\`, **not** the
WinPE `Media\EFI\` tree. `DESIGN.md` §5.2 corrected.

---

## S4 — E2E harness technique: drive and observe a VM headlessly ✅

Phases 04–08 need to verify VM state without a human at the console. Both halves
work via the Hyper-V WMI namespace `root\virtualization\v2`:

**Screenshot** — `Msvm_VirtualSystemManagementService.GetVirtualSystemThumbnailImage`,
passing the VM's `Msvm_VirtualSystemSettingData`. Returns raw 16-bit pixels
(2 bytes/pixel, `ReturnValue 0`, 960004 bytes at 800×600).

⚠ **Byte order caveat:** decoding as little-endian RGB565 rendered the image with
colours wrong (black background came out saturated). Text was legible either way,
so verification worked, but a harness that asserts on colour must first calibrate
against a known frame — try big-endian (`($d[$i] -shl 8) -bor $d[$i+1]`) before
trusting the channel mapping.

**Keyboard input** — `Msvm_Keyboard`, filtered by `SystemName = <VM GUID>`
(the `Name` property of `Msvm_ComputerSystem`, not its `ElementName`):

```powershell
Invoke-CimMethod -InputObject $kb -MethodName TypeText -Arguments @{asciiText='...'}
Invoke-CimMethod -InputObject $kb -MethodName TypeKey  -Arguments @{keyCode=[uint16]13}  # Enter
```

Both verified. This is how the E2E tests should assert on a deployment in
progress. Prefer having the engine write status to the share and asserting on
*that* where possible — screenshot-scraping is a last resort, not a first choice.

---

## S5 — Pester 6.0.0 is installed and shadows Pester 5 under PS 5.1 ⚠

Found by the phase 01 planner. A bare `Import-Module Pester` under
`powershell.exe` 5.1 resolves to **Pester 6.0.0**, not 5.7.1. Every import must
be pinned:

```powershell
Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99
```

Also: **PSScriptAnalyzer is not importable under 5.1** on this box. Therefore
`build.ps1 test` must not depend on `lint`, since the M0 exit criterion requires
`test` to pass under 5.1.

---

## S6 — The full network deployment flow, verified end to end ✅

**This is phase 04's exit criterion, achieved by hand.** The code must now
reproduce it. Sequence proven:

> boot WinPE ISO → DHCP lease → map the deployment share → select and partition
> the machine's own disk → **apply the WIM over SMB** → bcdboot → reboot →
> **Windows 11 reaches OOBE**

Actual log from inside WinPE:

```
00:09:15  PS 5.1.26100.1  Share: True
00:09:17  Disk candidates: 1
00:09:17      disk 0 64GB bus=SAS style=RAW
00:09:26  Partitions:  #1 S 260MB   #2 W 64250MB   #3 1024MB
00:09:26  Applying Z:\OperatingSystems\Win11-LTSC-2024\sources\install.wim (index 1) to W:\
00:11:01  Apply completed in 95s
00:11:02  bcdboot exit: 0
00:11:02  ntoskrnl: True     bootmgfw: True
00:11:02  === HDT-DEPLOY-OK ===
```

**Apply of a 4 GB WIM over SMB took 95 s** (over Wi-Fi). Network apply is not a
performance concern at this scale.

### Findings that phase 04 must encode

- **`Initialize-Disk -PartitionStyle GPT` silently creates its own MSR.** An
  earlier host-side spike created a second one explicitly and ended up with a
  duplicate 16 MB partition. The working recipe is
  `Clear-Disk -RemoveData -RemoveOEM` then `Initialize-Disk`, and **do not**
  create an MSR by hand. Verified: the clean run produced exactly
  ESP / Windows / Recovery.
- **Disk selection**: in a Gen2 VM the virtual disk reports `BusType = SAS`,
  not `SCSI` or `Virtual`. Do not filter on bus type expecting a VM-specific
  value. Filter on "not USB, over minimum size" and then **assert exactly one
  candidate**, refusing to proceed otherwise (DESIGN §9.1).
- **Log encoding**: `Tee-Object` defaults to UTF-16 on 5.1, producing logs that
  are unreadable in half the tooling. The log writer must set UTF-8 explicitly
  (DESIGN §4.4.2).
- **Boot order**: after apply, the DVD must be removed or demoted or the machine
  simply boots WinPE again. `ConfigureBoot` owns this.
- The deployment account (`svc-hdt-deploy`) was **read-only on the share with
  write only to `Logs\`**, and the whole flow worked — confirming the
  least-privilege model in DESIGN §6.3 is practical, not just aspirational.

### Networking reality in this lab

- The **host's Hyper-V "Default Switch"** carries a `192.168.25.0/24` lab
  network (CM01, DC01) but the host's own vNIC there is `172.24.144.1/20` —
  **no route between VM and host**. A VM on Default Switch cannot reach a share
  on the host.
- Working arrangement: an **External** switch (`HDT External`) bound to Wi-Fi.
  The VM then gets a lease from the real LAN DHCP (`192.168.2.0/24`) and reaches
  the host share at `192.168.2.108`.
- The host's internet egress is **Ethernet (192.168.1.219)**, so binding an
  External switch to Wi-Fi does not interrupt host connectivity. Check this
  before creating an External switch on any adapter.
- Inbound SMB was **blocked by default** — zero File and Printer Sharing rules
  enabled. A scoped rule (TCP 445 from the lab subnet only) was required. Any
  "cannot reach the share" report should check the firewall before the network.

## Reusable spike artifacts

| Artifact | Path |
|---|---|
| Built WinPE media tree | `C:\HDTLab\scratch\pe\media\` |
| `boot.wim` with PowerShell (480 MB) | `C:\HDTLab\scratch\pe\media\sources\boot.wim` |
| No-prompt UEFI ISO (533 MB) | `C:\HDTLab\scratch\pe\HDTPE_x64_uefi.iso` |
| No-prompt dual BIOS+UEFI ISO | `C:\HDTLab\scratch\pe\HDTPE_x64.iso` |
| Space-free boot bits | `C:\HDTLab\scratch\bootbits\` |
| Test VM (Gen2, Secure Boot, HDT Lab switch) | `HDT-PE-Test` |

Phase 05 may use these to compare against, but must still build its own image
through `Update-HDTBootImage` — the point of the phase is that the *code* does
this, not that it was done once by hand.
