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

## S7 — Autologon: LSA secret and AutoLogonCount coexist ✅ (partially)

Answers the question DESIGN §4.5.2 flagged as unverified. Deployed Windows 11
LTSC with an unattend containing `<AutoLogon><LogonCount>3</LogonCount>`, and
read the Winlogon state at first logon:

```
Logged on as      : Administrator
ComputerName      : HDT-TEST-01
AutoAdminLogon    : 1
DefaultUserName   : Administrator
DefaultDomainName :
AutoLogonCount    : 3
DefaultPassword   : absent          <- NOT in the registry
Leg number        : 1
```

### What this proves

- **Windows stores the autologon password as an LSA secret, not registry
  cleartext, when autologon comes from unattend `<AutoLogon>`.** `DefaultPassword`
  is absent from
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` while autologon
  is demonstrably working.
- **`AutoLogonCount` lives in the registry at the same time.** So the
  LSA-secret + count combination that DESIGN §4.5.2 worried might be mutually
  exclusive is exactly what Windows Setup does natively. HDT's design is the
  supported path, not a workaround — no fallback to registry storage is needed.
- The unattend also proved out: `ComputerName` applied from the `specialize`
  pass, OOBE fully skipped, built-in Administrator enabled, and
  `FirstLogonCommands` executed. That is phase 04's `ApplyUnattend` step
  validated.

### What this does NOT prove — do not claim it does

**The decrement-to-zero teardown was not observed.** The spike drove itself from
`FirstLogonCommands`, which by design runs **once**, at first logon only — so
legs 2 and 3 never executed and the count was never seen going 3 → 2 → 1 → gone.
At leg 1 it still read `3`.

Two consequences:

1. **Method note for phase 03:** to observe or drive behaviour across multiple
   logons, use a `RunOnce` entry or a scheduled task re-registered each leg.
   `FirstLogonCommands` cannot do it. This is also why HDT's own resume uses
   `RunOnce` re-registered per leg (DESIGN §4.5.1) rather than unattend.
2. **Risk is contained regardless.** `AutoLogonCount` is the *third* backstop in
   DESIGN §4.5.2, behind teardown in `finally` and the boot-time reconcile in
   `Start-HDTResume.ps1`. Even if Windows did not decrement it, an abandoned
   deployment is still disarmed by the reconcile on next boot. Phase 03 should
   confirm the decrement empirically and record the result, but it is not
   load-bearing on its own.

## S8 — `AutoLogonCount` decrements to zero and Windows disarms itself ✅

Answers the question S7 left open and DESIGN §4.5.2 flagged as *not yet
observed*: does Windows actually decrement `AutoLogonCount` across legs, and
does autologon keep working from an LSA secret alone?

Date: 2026-08-13 · throwaway VM `HDT-AutoLogon-Spike`, Generation 2, Secure
Boot on, 4 GB, isolated `HDT Lab` switch, built on a **copy** of S7's disk.

### Method

S7 could not answer this because it drove itself from `FirstLogonCommands`,
which runs once by design. S8 uses the mechanism DESIGN §4.5.1 actually
specifies: a `RunOnce` entry **re-registered by the observer each leg**. The
observer appends one line per boot recording the Winlogon state, whether
`DefaultPassword` exists in the registry, whether the `DefaultPassword` LSA
secret exists (via `LsaOpenPolicy`/`LsaRetrievePrivateData` — its *length* only,
never its value), and who is logged on. It then reboots.

A startup scheduled task registered on leg 1, delayed four minutes, is the
watchdog: on a boot where no autologon happens the logon observer never runs, so
the watchdog records that fact and powers the VM off instead of leaving it
sitting at a logon screen. That is what produced leg 4 below, and it is the
single most informative line in the log.

Arming was done entirely in the VM's **offline** `SOFTWARE` hive
(`reg load HKLM\HDTSPIKE`, unloaded in a `finally`) — `AutoAdminLogon=1`,
`DefaultUserName=Administrator`, `AutoLogonCount=3` (DWord) and the `RunOnce`
entry. **`DefaultPassword` was deliberately not written to the registry**: the
LSA secret Setup left on that disk in S7 was the only password store, so an
autologon happening at all is itself the proof that LSA storage works.

### What was observed

```
leg=1 mode=Logon    AutoAdminLogon=1 AutoLogonCount=2 RegistryDefaultPassword=absent LsaDefaultPassword=present-length-18 user=HDT-TEST-01\Administrator
leg=2 mode=Logon    AutoAdminLogon=1 AutoLogonCount=1 RegistryDefaultPassword=absent LsaDefaultPassword=present-length-18 user=HDT-TEST-01\Administrator
leg=3 mode=Logon    AutoAdminLogon=1 AutoLogonCount=0 RegistryDefaultPassword=absent LsaDefaultPassword=present-length-18 user=HDT-TEST-01\Administrator
leg=4 mode=Watchdog AutoAdminLogon=0 AutoLogonCount=<absent> RegistryDefaultPassword=absent LsaDefaultPassword=present-length-0 RunOnce=present user=WORKGROUP\HDT-TEST-01$
watchdog: no autologon happened on this boot - powering off
```

Corroboration, read offline before anything was armed: S7's disk had been left
with `AutoLogonCount=2`, not the `3` S7 reported reading in-session. Windows had
already decremented it at that first logon; S7 simply read the value before —
or from a context ahead of — the write.

### What this proves

1. **The count decrements, one per autologon, and it decrements *before* the
   session starts.** Armed at 3, the three autologged sessions read 2, 1 and 0.
   So `AutoLogonCount = n` buys exactly *n* autologons and DESIGN §4.5.2's
   "exactly the number of legs remaining" is literal — there is no off-by-one,
   and `Set-HDTAutoLogon -RemainingLeg` means "how many more autologons".
2. **Windows disarms itself when the count is spent.** On the fourth boot
   `AutoAdminLogon` had been set to `0` by Windows, `AutoLogonCount` was gone
   entirely, and — the part worth knowing — the `DefaultPassword` **LSA secret
   had been blanked to zero length**. The third backstop is real.
3. **Autologon works from the LSA secret with no registry `DefaultPassword`.**
   Three autologons happened with `RegistryDefaultPassword=absent` throughout.
   ROADMAP M2's registry-storage fallback is **not needed**; DESIGN §4.5.2 keeps
   LSA storage, and `Set-HDTAutoLogon` has no `-PasswordStorage` parameter.
4. **`RunOnce` is consumed per leg, as DESIGN §4.5.1 assumes.** Every leg found
   `RunOnce=absent` (its own entry already consumed by the time it ran) and had
   to re-register for the next one. On leg 4 the entry was still *present* —
   re-registered by leg 3, never consumed, because there was no logon.

### What it does not prove

The teardown Windows performs is not a substitute for HDT's own. It only fires
after the legs are spent, so an abandoned run still autologs on up to *n* more
times. `finally` teardown and the boot-time reconcile remain the first two
backstops; this is the third.

### Lab safety

Every Hyper-V call was name-filtered to `HDT-AutoLogon-Spike` and
module-qualified (`Hyper-V\Get-VM` — PowerCLI shadows `Get-VM` on this host).
`CM01` and `DC01` were never touched and are still `Off`. S7's disk
`C:\HDTLab\vms\HDT-PE-Test-osdisk.vhdx` survived; the spike ran on a copy, which
was deleted with the VM. **The host's own Winlogon key was read before and after
and is byte-identical — no autologon value exists on it.** `HKLM\HDTSPIKE` is
unloaded. Total elapsed: 6.1 minutes.

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

---

## S9 — the engine inside WinPE, and what a real disk and a real apply exposed ✅⚠

Date: 2026-08-13 · phase 04 plan 04. **This is the first time any of phase 04's
code ran against real hardware.** Everything before it is asserted against
hand-written fakes, which is what makes those suites take seconds; this is where
the fakes were checked against the world, and four of them were wrong.

### S9.1 — powershell-yaml loads in WinPE, first try ✅

The plan called this "the single most likely way this plan discovers a problem",
and wrote a three-rung fix ladder for it. **No rung was needed.**

`tests/e2e/WinPeSmoke.E2E.Tests.ps1` builds a 2 GB content disk, boots
`HDT-M3-Smoke` (Gen2, Secure Boot, 2 GB, isolated `HDT Lab` switch) from
S1/S3's ISO, types one line at the prompt, and reads `PROBE.json` back off the
disk. Verbatim:

```json
"psVersion":    "5.1.26100.1",     "psEdition":  "Desktop",
"yamlLoaded":   true,              "yamlVersion": "0.4.12",
"yamlBase":     "C:\\HDT\\Modules\\powershell-yaml",
"engineLoaded": true,              "engineVersion": "0.1.0",
"factCount":    18,
"sequenceId":   "DEMO-M3",         "sequenceStep": 5,
"ruleCount":    4,                 "osCatalogId": "Win11-LTSC-2024"
```

- **powershell-yaml 0.4.12 imports inside WinPE from a STAGED copy** on a plain
  data disk — not installed, not on the standard module path — and its `net47`
  flavour loads against `WinPE-NetFx`. `ConvertFrom-HDTYaml` goes through it, so
  this is the dependency the whole engine rests on in WinPE.
- **Importing it is not the same as parsing.** The probe therefore also imports
  the real `DEMO-M3` sequence (5 steps), the real `rules.yaml` (4 rules) and the
  real `os.yaml` — all three came back.
- **WinPE assigned the content disk `C:`.** The RAM disk is `X:`. Nothing may
  assume a letter; the launcher and the probe both scan `C D E F G H` for what
  they need, and the harness types a `for %d in (...)` line for the same reason.

### S9.2 — `Get-HDTMachineFact` in its actual home ✅

Phase 02's gatherer, run for the first time where it will live. 18 facts, from
the real CIM provider, registry and environment inside WinPE:

```
HDTMake  Microsoft Corporation      HDTModel  Virtual Machine
HDTIsVM  True                       HDTIsUEFI True     HDTSecureBootEnabled True
HDTArchitecture x64                 HDTMemory 2046     HDTIsDesktop True
HDTUUID  78F6E5D7-...               HDTSerialNumber 1884-9397-...
HDTMacAddress 00:15:5D:86:01:05     HDTIPAddress 169.254.165.242,fe80::...
HDTSystemSKU None                   HDTTPMVersion <empty>   HDTDefaultGateway <empty>
```

Three things worth keeping:

- **`HDTMemory` is 2046 on a 2 GB VM**, so `DEMO-M3`'s `minRamMB: 2048` against
  a 4 GB machine is right to be 2048 and not 4096 — the firmware keeps some.
- **`HDTTPMVersion` and `HDTSystemSKU` are empty / `None` on a VM**, which is the
  PSD-derived warning phase 02 carried, confirmed rather than assumed.
- **The isolated switch gives an APIPA address** (`169.254.*`). Nothing in the
  WinPE leg needs the network, which is the point of the content-disk topology.

### S9.3 — `Clear-Disk` refuses a RAW disk, and that was a real defect ⚠

**The most valuable finding of the phase.** Verified twice, by isolated probe
and by the integration suite:

```
Clear-Disk -Number N -RemoveData -RemoveOEM
-> The disk has not been initialized.
```

A brand-new VHDX is RAW. **So is the disk in a machine that has never been
deployed — which is every machine `DiskPartition` exists for.**
`Invoke-HDTDiskPartitionStep` called `ClearDisk` unconditionally, and the fake
shrugged at it, so the entire unit suite was green for code that could not
partition a factory-fresh disk.

S6's "the working recipe is `Clear-Disk -RemoveData -RemoveOEM` then
`Initialize-Disk`" is correct **for a disk that has a partition table**. The
full recipe is:

```
if (style -ne RAW) { Clear-Disk -RemoveData -RemoveOEM }   # nothing to clear otherwise
Initialize-Disk -PartitionStyle GPT                        # this creates the MSR
ESP / Windows / Recovery                                   # and no MSR by hand
```

Fixed in the step, which is where a decision belongs; the fake now refuses the
same call for the same reason, so the two implementations fail alike.

### S9.4 — the MSR is 16 759 808 bytes at offset 17 408 ✅

Not a round 16 MB, and the two numbers together are **exactly** 16 777 216 —
which is the `ReservedSizeByte` allowance `Get-HDTDiskLayout` carries. That
allowance is right to the byte rather than lucky. Captured:

```
PartitionNumber     Size Type     GptType                                Offset
              1 16759808 Reserved {e3c9e316-0b5c-4db8-817d-f92df00215ae}  17408
```

### S9.5 — `Set-Partition -GptType` after `Format-Volume` works ✅

04-02 recorded the ESP recipe as **unverified**: create the ESP as *basic data*
so it can take a drive letter to format through, format it FAT32, then retype it
to the EFI System type. It works. The partition ends up
`{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}`, 272 629 760 bytes, FAT32.

### S9.6 — FAT32 has no lower case in a volume label ⚠

The layout asks for `System` on the ESP; `Get-Volume` reports **`SYSTEM`**. NTFS
preserves the case it was given (`Windows`, `Windows RE tools`). **Nothing
downstream may match a volume label case-sensitively.**

### S9.7 — `reagentc /setreimage` reports success and registers nothing ⚠

Against an **offline** applied image, from an elevated host session:

```
REAGENTC.EXE: Operation Successful.        <- exit code 0

reagentc /info /target W:\Windows
    Windows RE status:         Disabled
    Windows RE location:
    Recovery image location:
    Recovery image index:      0
```

It does **not refuse**. It exits 0, prints success, and `/info` on the same
target shows nothing registered. So `SetRecoveryImage` cannot be judged by its
exit code — and an exit code is exactly what the adapter checks.

**What this means for HDT:** the recovery registration `ConfigureBoot` performs
is *not* what makes WinRE work on the deployed machine. Windows Setup enables
WinRE itself during specialize/oobe from the `Winre.wim` the apply leaves in
`Windows\System32\Recovery`. That is why 04-03 wrote that leg to warn and
continue, and it is why **a green integration run does not prove WinRE was
configured**. Recorded as an assertion in
`tests/integration/ImageService.Integration.Tests.ps1` so that the day this
changes, somebody is told.

### S9.8 — timings, beside S6's hand-run numbers

| What | S6, by hand | S9, by code |
|---|---|---|
| Apply Windows 11 index 1 (4 GB WIM) | **95 s** over SMB, over Wi-Fi | **132–134 s** from a local disk into a dynamic VHDX |
| Applied size on the Windows volume | not recorded | **10 047 967 232 bytes** (9.36 GiB) |

**The network was never the slow part.** A local apply into a *dynamic* VHDX is
slower than S6's network apply, because growing the VHDX is the cost. M4 should
not treat SMB as the thing to optimise.

### S9.9 — two traps in the test harness itself ⚠

- **A `throw` inside a `ScriptMethod` is wrapped twice** —
  `MethodInvocationException` over `RuntimeException` over the real exception,
  because the adapter sets `$ErrorActionPreference = 'Stop'`. An assertion on
  the exception type must use `GetBaseException()`; `.InnerException` reaches
  only the middle one.
- **`Mock` cannot intercept a module-qualified call.** `Hyper-V\New-VM` resolves
  straight into the module and never consults the function table Pester injects
  into, so a mock asserting "no Hyper-V command was called" would never be
  consulted and would always pass. The lab helpers' guards are proven by AST
  instead: every Hyper-V command is module-qualified, and `Assert-HDTLabVmName`
  is called before the first one.

### S9.10 — `Initialize-Disk` creates no MSR **inside WinPE** ⚠

The deployed machine's disk carries **three** partitions, not four:

```
GptType                                  what
{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}   EFI System, 260 MB FAT32
{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}   Windows
{de94bba4-06d1-4d40-a16a-bfd50179d6ac}   Windows Recovery
```

There is **no Microsoft Reserved partition**. On the *host*, the same
`Initialize-Disk -PartitionStyle GPT` call demonstrably creates one — S9.4
measures it at 16 759 808 bytes and offset 17 408. Inside WinPE it does not.

**S6's own hand-run log said so and nobody noticed:**

```
00:09:26  Partitions:  #1 S 260MB   #2 W 64250MB   #3 1024MB
```

Three partitions. The "Initialize-Disk silently creates its own MSR" finding in
S6 came from a *host-side* spike, and was generalised to WinPE without evidence.

**It changes nothing about correctness**, and that is worth stating plainly:

- HDT never creates an MSR, so there can be no duplicate either way.
- `ReservedSizeByte` is an *allowance*, subtracted from what Windows may have.
  When no MSR appears the 16 MB is simply not used.
- The recovery partition carries `UseMaximumSize`, so the unused allowance lands
  in recovery rather than being left unallocated at the end of the disk.

`New-HDTFakeDiskService` continues to model the host behaviour — it creates the
MSR on `InitializeDisk` — **deliberately**. The fake exists to make the
duplicate-MSR bug visible, and it can only do that if an MSR is there to
duplicate. The divergence is noted in `tests/unit/Imaging.EndToEnd.Tests.ps1`.

### S9.11 — Windows Setup silently discards a ComputerName over 15 characters ⚠

**The most dangerous finding of the phase, because the deployment succeeded.**

The first full deployment run reported `Succeeded`, completed all five steps,
wrote no `step.fail`, and produced a machine named **`WIN-N91191NN153`** —
Setup's own generated name. Nothing in any log mentioned it.

The chain:

1. `samples/workspace/rules.yaml`'s fallback rule sets
   `HDTComputerName: "PC-%HDTSerialNumber%"`.
2. DESIGN 3.1's precedence puts **rules above a sequence's own defaults**, so
   `DEMO-M3`'s `HDTComputerName: HDT-M3-01` loses. That is correct behaviour.
3. A Hyper-V VM's serial number is 32 characters
   (`1884-9397-3639-6194-7223-8141-25`), so the resolved name was 35 characters.
4. `ApplyUnattend` staged an unattend carrying it, `<ComputerName>` and all.
5. **Setup ignored it without complaint** and named the machine itself.

Two changes, and both were needed:

- **`Invoke-HDTApplyUnattendStep` now refuses** a `%HDTComputerName%` over 15
  characters (the NetBIOS limit) or holding anything but letters, digits and
  hyphens. It does **not truncate** — a silently shortened name is the same
  failure with a different spelling. The run stops with
  `HDTConfigurationError` naming the offending value.
- **The E2E stages a per-machine override**, DESIGN 3.1's second source, keyed
  on the VM's UUID: `Share\Control\machines\<UUID>.yaml` setting
  `HDTComputerName: HDT-M3-01`. That is the mechanism HDT already has for making
  one machine an exception without editing rules, and this is the first time it
  has been exercised end to end.

**The sample `rules.yaml` was left alone.** It is DESIGN 3.3's documented
example and its behaviour is correct; `PC-<serial>` is a perfectly good name on
hardware whose serial is seven characters, which is most of it. What was missing
was HDT noticing when it is not.

### S9.12 — the machine booted into Windows with the media still attached ✅

**ROADMAP M3's exit criterion.** After the WinPE leg the VM was started again
with the WinPE ISO still in its DVD drive and the firmware boot order
**untouched**, and it reached full Windows: a settled integration-services
heartbeat, which WinPE never reports.

So `ConfigureBoot`'s `SetBootOrderFirst` —
`bcdedit /set {fwbootmgr} displayorder {bootmgr} /addfirst`, S6's fourth finding
as an API — **works**, and it had never run anywhere before this: it edits the
firmware boot order of the machine it runs on, so it cannot be tested on the
developer's.

Timings for the whole demonstration:

| Leg | Time |
|---|---|
| Content disk staged (module, parser, workspace, 4 GB WIM) | 12 s |
| WinPE boot + the engine's whole five-step run + shutdown | 273 s wall, of which the engine reported **100 s** |
| First Windows boot to a settled heartbeat (specialize + oobe) | 265 s |

### S9.13 — the lab damage, reported rather than tidied away ⚠

**`C:\HDTLab\vms` was emptied during 04-04.** Lost: the `HDT-PE-Test` VM,
`HDT-PE-Test-osdisk.vhdx` (the Windows 11 disk S7 deployed and S8 ran its
autologon legs against, ~12.6 GB, which sat **loose at the root** of that
folder), and the leftover `HDT-AutoLogon-Spike` folder.

**`CM01` and `DC01` were never at risk and are untouched.** They are refused by
name by `Assert-HDTLabVmName`, they are not under `C:\HDTLab\vms`, and both were
`Off` before and after every run — asserted in `AfterAll` blocks that run on
failure too. The WinPE media and ISO under `C:\HDTLab\scratch\pe\` survive, so
the boot vehicle S1/S3 built is intact; what is gone is S7's deployed disk.

**The cause was never established, and it is not honest to claim one.** The
Hyper-V VMMS log puts the `HDT-PE-Test` deletion at 17:24:06, alongside a
`build.ps1 -Task e2e` run that failed instantly with every test reporting
"a setup in some parent block failed" — an error that was not captured before
the evidence was gone. No lab helper names anything but the exact VM it is
given; the developer was also working in the same lab in that window.

**What was fixed regardless.** The delete was not narrow enough to make the
accident *impossible*, and that is a defect in the one piece of code whose whole
job is to make it impossible. `Assert-HDTLabVmPath` now stands in front of every
delete a lab helper performs and refuses:

- the VM root itself — `Join-Path 'C:\HDTLab\vms' ''` yields the root, and
  `Remove-Item -Recurse -Force` on it empties the lab;
- anything outside the VM root;
- anything **inside** it that is not this VM's own folder — another VM's folder,
  or a file sitting loose beside them. `HDT-PE-Test-osdisk.vhdx` was exactly
  that, and it matched the old `-like 'C:\HDTLab\vms\*'` test.

Seven unit tests, written failing first. A lab that has already lost something
is the wrong time to argue about whether a guard was necessary.

### S9.14 — the lab-safety assertion was comparing nothing ⚠

`Get-VM` returns an object with **`MemoryStartup`**. `New-VM` takes a parameter
called **`-MemoryStartupBytes`**. The E2E's "CM01 and DC01 are exactly as I found
them" snapshot read `$_.MemoryStartupBytes` — the parameter name — off the
object.

**Without `Set-StrictMode` a missing property is `$null`, `[long] $null` is `0`,
and the comparison held `0` against `0`.** The assertion that protects the
user's live lab was green while comparing nothing at all. It is helpers
README 12's "an assertion that passes for the wrong reason", in the one place it
matters most.

**It surfaced only under `./build.ps1 -Task e2e`**, which sets
`Set-StrictMode -Version Latest` at script scope; a bare `Invoke-Pester` does
not, and every earlier run of these files had been a bare `Invoke-Pester`. Under
StrictMode the same line throws `PropertyNotFoundException` in `BeforeAll`, which
is how it was found.

**Method note, and it is the general lesson of this plan: run an E2E or
integration suite through `build.ps1`, not through `Invoke-Pester` directly.**
The build script's `StrictMode` and `$ErrorActionPreference` are part of the
environment the tests are meant to run in, and a suite that only ever runs
without them is a suite with a different meaning.

Properties `Get-VM` actually exposes, for whoever writes the next one:

```
MemoryAssigned  MemoryDemand  MemoryStatus  MemoryMaximum  MemoryMinimum  MemoryStartup
```

`MemoryAssigned` is what the 12 GB lab budget check uses, and it is correct —
it reads 0 for a VM that is `Off`, which is what makes the budget about *running*
machines.

### S9.15 — a BeforeDiscovery variable is not readable from BeforeAll

Found by the same StrictMode run as S9.14, and it hid the same way.

Pester's discovery and run phases do not share a scope. `$script:skipDeployment`
set in `BeforeDiscovery` is what the `-Skip:` on each `Describe` reads at
discovery; reading it inside `BeforeAll` throws
`The variable cannot be retrieved because it has not been set` under StrictMode.

**Without StrictMode it evaluated to `$null`, and `if (-not $null)` is TRUE** —
so the expensive body ran on a machine that was supposed to be skipping it. A
guard that means the opposite of what it says when its input is missing is worse
than no guard.

Both E2E files now recompute the condition inside `BeforeAll`, which is the
pattern the integration files already used for the drive-letter check.


### Lab safety

Every Hyper-V call name-filtered and module-qualified. `CM01` and `DC01` were
recorded before each run and asserted identical after, in `AfterAll` blocks that
run on failure too — both `Off` and untouched throughout. `HDT-PE-Test` was never
started - and it was LOST, which S9.13 records rather than tidies away. This host's disk 0 was GPT / `IsBoot` True / `IsSystem` True with the
same partitions before and after every run; every destructive call in the
integration suite was asserted to name the scratch disk number and no other.
