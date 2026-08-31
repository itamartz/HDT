# Verified environment findings

Empirical results from spikes run on this machine. **These are verified by
execution, not assumed.** Where one contradicts an assumption in `docs/DESIGN.md`,
the design has been corrected.

Date: 2026-08-12 · Host: LAP-AMMSO01 · ADK 10.1.26100.2454

> **2026-08-29 — `CM01` and `DC01` were retired.** They are gone from this host;
> `Get-VM` returns only `HDT-*`. Findings below that record "CM01 and DC01 were
> untouched" were true of the run that produced them and are **left as written**
> — this file is a record of what was executed, not a description of the lab as
> it stands. Everywhere else the protected set is now the `HDT-*` prefix rather
> than a list of names, because a list of names is what failed: the lab-safety
> snapshot went on comparing two VMs that no longer existed, which is an empty
> array against an empty array. Do not restore those names from here.

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

⚠ **Byte order — THIS ENTRY WAS WRONG, and was corrected on 2026-08-18.** It said
little-endian rendered the colours wrong and to prefer big-endian. It is the other
way round: the frames are **little-endian RGB565**, `($d[$i+1] -shl 8) -bor $d[$i]`,
and the big-endian reading is what turned a dark WinPE background into saturated
magenta. Text was legible either way, which is why the mistake survived — the
screenshots were used to read words, and nobody who saw the colours believed them
enough to check.

Proven against a frame whose true colours were known (the WinPE background image
decodes correctly one way and only one). The decode now lives in
`ConvertFrom-HDTThumbnailImage` with a test that pins black, white and each
saturated channel, because arithmetic inside a TDD-exempt adapter is exactly how
this happened. `Save-HDTLabVmScreen` calls it and holds no maths of its own.

Two other things the frames do here: the call returns **four bytes more** than
`width × height × 2` — not pixels, and a decoder reading to the end of the buffer
walks off the last row — and `SetPixel` per pixel cost ~10 s a frame at 1024×768,
which is long enough for a capture loop to miss what it was watching. `LockBits`
makes it under four.

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
  The VM then gets a lease from the real LAN DHCP — the lab subnet, which was
  `192.168.2.0/24` when this was measured and is `192.168.1.0/24` since
  2026-08-28 — and reaches the host share on that subnet. **The host's own
  octet is a lease, not a finding**: read it with `Get-NetIPAddress
  -InterfaceAlias 'vEthernet (HDT External)'` before you build a boot image,
  because it gets baked into what you build.
- The host's internet egress is a **separate Ethernet adapter on its own
  subnet**, so binding an External switch to Wi-Fi does not interrupt host
  connectivity. Check this before creating an External switch on any adapter.
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

#### S9.15b — the same trap defeats an anti-vacuity guard, silently

A third instance, in `tests/contract/ProtectedPath.Contract.Tests.ps1`: the file
list was built in `BeforeDiscovery` and read from an `It` body. The file carried
the standard anti-vacuity guard —

```powershell
@($script:scanFile).Count | Should -BeGreaterThan 0 -Because 'a contract that scans nothing proves nothing'
```

— and **it passed while scanning zero files**, because `@($null).Count` is `1`.
So the guard written specifically to prove the contract was not decoration was
itself satisfied by nothing at all, and the contract reported green having
examined no files.

Two lessons, and the second is the one that cost the time:

1. `@($null).Count -gt 0` is **not** an emptiness check. Assert on something that
   cannot be fabricated by coercion — a count against a known floor
   (`-BeGreaterThan 200` for a repo-wide scan), or the presence of a file you
   know is in the set.
2. It was "verified" with a bare `Invoke-Pester`, which has no StrictMode, so
   the throw never happened and 4/4 green looked like proof. **S9.14 already
   said to run through `./build.ps1`.** Written down, then not applied — twice
   now. If a test is a safety guard, the only run that counts is the one through
   the real entry point, and the only proof that counts is watching it fail on a
   planted violation.

Corrected version: file list in `BeforeAll`, 287 files scanned, and a planted
`Remove-Item -Path "C:\HDTLab\media" -Recurse` in `src/` turns it red.


### Lab safety

Every Hyper-V call name-filtered and module-qualified. `CM01` and `DC01` were
recorded before each run and asserted identical after, in `AfterAll` blocks that
run on failure too — both `Off` and untouched throughout. `HDT-PE-Test` was never
started - and it was LOST, which S9.13 records rather than tidies away. This host's disk 0 was GPT / `IsBoot` True / `IsSystem` True with the
same partitions before and after every run; every destructive call in the
integration suite was asserted to name the scratch disk number and no other.

---

## S10 — `C:\HDTLab\media` is gone, and `-Task e2e` cannot run until it is back ⚠

Date: 2026-08-13, found during phase 05 plan 03 while running
`./build.ps1 -Task e2e`.

```
BUILD FAILED: The 'e2e' task needs the staged Windows 11 media at
'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
(PROJECT.md, 'Test media - already staged locally').
```

**`C:\HDTLab\media` does not exist.** Both staged source trees —
`Win11-LTSC-2024` and `WS2025-Std`, ~11 GB between them, listed in PROJECT.md as
"already staged, do not re-extract" and in CLAUDE.md's "never deleted" table —
are gone. `C:\HDTLab\vms` is empty again as well.

Surviving: `C:\HDTLab\Share`, `C:\HDTLab\reference\PSD`, and
`C:\HDTLab\scratch\pe\` — so S1/S3's WinPE media tree, `boot.wim` and the
no-prompt ISO are intact and phase 05 still has a boot vehicle to compare
against.

**`CM01` and `DC01` are untouched and both `Off`**, read back name-filtered and
module-qualified after the discovery. There are zero `HDT-*` VMs.

**The cause was not established, and inventing one would be worse than saying
so** — which is the position S9.13 took the first time this happened. What is
known: `C:\HDTLab`'s mtime is 20:28 on 2026-08-13, 05-03's session began at
about 23:15, and nothing in 05-03 deletes anything at all — no `Remove-Item`, no
`-Recurse`, no Hyper-V call, no VHDX, no mount. The `e2e` guard in `build.ps1`
throws before a single test runs, so no test code executed either.

**Consequences, in order of who they hit:**

1. **05-04 and 05-05 cannot meet ROADMAP M4's exit criterion until the media is
   restored.** Re-extract from
   `C:\Users\Itamartz\Dropbox\System\_FORWORK\SCCM\HydrationKitWS2025\ISO\` to
   `C:\HDTLab\media\Win11-LTSC-2024\` and `...\WS2025-Std\`.
2. **`build.ps1 -Task e2e` is a hard fail, not a skip**, and that is correct: a
   silently skipped end-to-end suite is S9.15's defect in another costume.
3. Nothing proven *against fakes* is affected. 05-03 adds no e2e test.

**The guard that would have caught a code cause already exists and is green.**
`tests/contract/ProtectedPath.Contract.Tests.ps1` scans every `.ps1`/`.psm1`/
`.psd1` outside fixtures for a delete naming a protected path, and S9.15b records
it being proven to bite on a planted
`Remove-Item -Path "C:\HDTLab\media" -Recurse`. It found nothing this time, which
narrows the possibilities without closing them.

---

## S11 — HDT builds its own boot image, and four things the fakes had wrong ✅⚠

Date: 2026-08-14 · phase 05 plan 04. **The first time any of phase 05's code
touched DISM or oscdimg.** Everything before this ran against hand-written fakes;
this is where they were checked against the world.

Numbered S11 rather than S10: S10 is the media-loss entry 05-03 recorded, and
renumbering a finding somebody may already have cited would be worse than a gap
in the plan's wording.

### S11.1 — the build worked first try, and it is not slow ✅

`Update-HDTBootImage -WorkspaceRoot <scratch>\Share` against the real ADK
10.1.26100.2454, nine optional components, on this host:

| | Value |
|---|---|
| `Boot\HDTPE_x64.wim` | **495 340 358 bytes** |
| `Boot\HDTPE_x64.iso` | **550 916 096 bytes** |
| WIM SHA256 | `30FF0972FE4E8D416EE150FFD6A4EEE48F93599B9CF6245AE76F20DFEE5A90E5` |
| Full build (WIM + ISO) | **123 s** |
| Same build with `-SkipIso` | **120 s** |
| Whole integration file, both builds + a read-only re-mount, 24 tests | **291 s** |

**The plan budgeted 15–25 minutes. It took two.** Nothing in the mount / apply /
export cycle is slow on an NVMe host, and the numbers above are the ones to plan
against.

**`oscdimg` is NOT the slow half, and DESIGN 5.1 said it was.** 123 s against
120 s: writing a 550 MB ISO from an already-staged media tree costs about **two
seconds**. DESIGN 5.1 has been corrected. `-SkipIso` is worth having for the
artifact it does not produce, not for time it does not save, and nothing should
be optimised on the assumption that the ISO is expensive.

**SPIKES S2's staging worked exactly as recorded.** The boot bits are copied out
of `C:\Program Files (x86)\...\Oscdimg` into `<scratch>\bootbits` and
`-bootdata:1#pEF,e,b<bits>\efisys_noprompt.bin` is passed unquoted. No Error 123,
first try. The refusals that keep it that way — a boot-bit path with a space, a
scratch path with a space — are asserted in the unit suite.

### S11.2 — DESIGN 6.1.1 holds, and it holds three ways ✅

**ROADMAP M4 names this test explicitly.** The WIM inside the ISO and the
standalone WIM:

```
WIM on disk          30FF0972FE4E8D416EE150FFD6A4EEE48F93599B9CF6245AE76F20DFEE5A90E5
sources\boot.wim
  inside the ISO     30FF0972FE4E8D416EE150FFD6A4EEE48F93599B9CF6245AE76F20DFEE5A90E5
manifest
  isoBootWimSha256   30FF0972FE4E8D416EE150FFD6A4EEE48F93599B9CF6245AE76F20DFEE5A90E5
```

Three ways on purpose: a manifest that agreed with itself but not with the disk
would be worse than none, because an operator would trust it. The mechanism is
that the exported WIM is **copied** into the media tree — one file, two homes —
rather than exported twice.

### S11.3 — `startnet.cmd`, read back out of a mounted image ✅

`Mount-WindowsImage -ReadOnly` on the WIM the build produced, verbatim:

```
@echo off
rem Written by Update-HDTBootImage. Do not edit inside the image; edit HDT.
set HDT_LAUNCHED_BY=startnet
wpeinit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTDeployment.ps1
```

First byte `0x40` (`@`), not `0xEF` — no BOM, which `cmd.exe` would read as a
command and fail on with no useful message. `X:\HDT\` carries `bootstrap.json`,
`Start-HDTDeployment.ps1`, `Start-HDTResume.ps1` and `Modules\`. The
`WinPE-PowerShell` cab put `powershell.exe` where that last line expects it.

**05-05 can now boot an image this repository built**, and assert
`HDT_LAUNCHED_BY=startnet` in `RESULT.json` to prove nobody typed the command.

### S11.4 — it is NOT byte-comparable to SPIKES S1's hand-built image, and could not be ⚠

Worth stating because the question is obvious and the answer is easy to get
wrong:

| | S1, by hand | S11, by code |
|---|---|---|
| `boot.wim` | 503 853 178 B, `2C70D1A2…` | 495 340 358 B, `30FF0972…` |
| UEFI no-prompt ISO | 559 429 632 B | 550 916 096 B |

**Different bytes, and that is correct.** HDT's image carries things S1's does
not — the engine module, `powershell-yaml`, both payload scripts,
`bootstrap.json`, and a `startnet.cmd` that launches the engine instead of
dropping to a prompt. It is *smaller* despite carrying more, because
`Export-WindowsImage -CompressionType Max` is doing work the hand build's export
did not. A byte-identical result would have meant the engine was not in there.

### S11.5 — four things the fakes or the plan had wrong ⚠

**1. `Get-WindowsImage`'s `ImageSize` is the UNCOMPRESSED size, not the file
size.** 05-04's `<verified_facts>` records `winpe.wim` as 340 134 390 bytes, and
that is the **file on disk**. DISM reports **2 009 251 937**. The contract test
asserted the file size against the DISM number and went red on the real row,
which is what the real row is for. Both numbers are now pinned, each labelled.
`IImageService.SizeBytes` has always been `ImageSize` too, so this is a
repository-wide clarification, not a boot-image one.

**2. `powershell-yaml` ships `lib\net47`, not `net47` at the module root.**
0.4.12 lays out `lib\net47\` and `lib\netstandard2.1\`. SPIKES S9.1 recorded
"its net47 flavour loads against WinPE-NetFx" and an assertion written from that
sentence looked in the wrong place. It was the one test the first real run of the
integration file turned red. The staging itself was correct — the whole tree is
copied — so this was a defect in the test, not in the build.

**3. Windows PowerShell 5.1's `ConvertTo-Json` puts TWO spaces after a colon;
pwsh 7 puts one.** `"builtUtc":  "..."` against `"builtUtc": "..."`. Both are
valid JSON and no consumer cares, but an assertion that pinned the formatting is
green on one engine and red on the other — which is what it was, first run. Use
`-Match '"key":\s*"value"'`, never `-BeLike '*"key": "value"*'`.

**4. A PowerShell class method refuses to compile a variable assigned only
inside a `try`.** `ParserError: Variable is not assigned in the method` — the
parser cannot see an assignment on every path and will not take the risk.
Declare it before the `try`. This bites in `HDTFakes.psm1` and nowhere else,
because the fakes are the only classes in the repository.

### S11.6 — the ACL check ran for real, and warned ✅

The scratch workspace's ACL does not mention `HDTLAB\svc-hdt-deploy`, so
`Test-HDTShareAcl` reported `Critical: cannot read the workspace root` and
`Update-HDTBootImage` **warned and built anyway**. DESIGN 6.3's "warn loudly, do
not refuse" is therefore exercised end to end rather than only against
hand-written rows: an administrator whose build died on an ACL check is an
administrator who turns the check off.

### Lab safety

**No Hyper-V call of any kind.** This plan creates no VM, and `CM01` and `DC01`
were never touched. Everything written lives under
`C:\HDTLab\scratch\bootimage\`, created by the test that uses it and removed by
the same code; the artifacts are left in place for inspection. This host's disk 0
was snapshotted before and asserted identical after (`GPT|True|True`), and
`git status --porcelain` is compared before and after so a build that scattered a
mount folder into the working tree would be caught. After the run
`Get-WindowsImage -Mounted` is empty and the ISO is not attached, checked by hand
as well as by the suite.

`C:\HDTLab\media` is **still missing** — S10 stands, and `-Task e2e` still cannot
run. It is not a precondition of anything in this plan.

---

## S12 — a machine started its own deployment, and two plans of unproven code came due ✅⚠

Date: 2026-08-14 · phase 05 plan 05. **ROADMAP M4's exit criterion, met.** A
Generation 2 VM booted an ISO this repository built and deployed Windows 11 to
completion **with zero keystrokes sent to it**.

### S12.0 — the staged media is back, and S10 is closed

`C:\HDTLab\media` was re-extracted from the Dropbox ISOs PROJECT.md names, with
`Mount-DiskImage -Access ReadOnly` and `robocopy /E` — a create-only operation
that deletes nothing:

```
C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim   4 313 252 141 B   6 s
C:\HDTLab\media\WS2025-Std\sources\install.wim        5 186 143 750 B   6 s
```

Six seconds each on this NVMe host. **The cause of the original loss was never
established and still is not** — S10 says so and that has not changed. What is
now known is that restoring it is cheap, which is worth writing down beside a
finding that stopped two plans from running `-Task e2e`.

### S12.1 — the run, and the one line that proves nobody typed ✅

`tests/e2e/UnattendedDeployment.E2E.Tests.ps1`. `Update-HDTBootImage` built the
image, `New-HDTLabVirtualMachine` created `HDT-M4-Deploy` on the isolated
`HDT Lab` switch, the VM was started, **and then nothing happened to it at all**.

`RESULT.json`, read off the content disk after the machine powered itself off:

```json
"status":             "Succeeded",   "launchedBy":   "startnet",
"provider":           "Local",       "sequenceId":   "DEMO-M4",
"deployRoot":         "\\Share",     "resolvedDeployRoot": "C:\\Share",
"deployRootSource":   "Discovered",  "computerName": "HDT-M4-01",
"yamlVersion":        "0.4.12",      "yamlBase":     "X:\\HDT\\Modules\\powershell-yaml",
"engineVersion":      "0.1.0",       "psVersion":    "5.1.26100.1",
"elapsedSecond":      105,           "endedWith":    "wpeutil shutdown",
"logPath":            "W:\\HDT\\Logs"
```

**`launchedBy` is `startnet`.** `startnet.cmd` inside the image runs
`set HDT_LAUNCHED_BY=startnet` before it launches anything (S11.3), and nothing
else sets it. A hand-typed launch leaves it empty.

**`yamlBase` is on `X:`.** The engine and the parser came out of the boot image,
not off the content disk — which is what let the M4 content disk drop the
`HDT\Modules\` tree the M3 one carried.

And the WinPE screenshot at t+150 s, `m4-01-winpe.png`, shows the engine already
running rather than a prompt — colours inverted exactly as S4's byte-order caveat
predicts, text legible:

```
powershell-yaml 0.4.12 loaded from X:\HDT\Modules\powershell-yaml
Hephaestus 0.1.0 loaded from X:\HDT\Modules\Hephaestus
...
machine override: C:\Share\Control\machines\351B53DB-...-6A5BA69610DC.yaml
sequence 'DEMO-M4': 5 step(s)
HDTComputerName resolved to 'HDT-M4-01'
running the task sequence
```

### S12.2 — SPIKES S9.1 confirmed a second time, on an image built by code ✅

```
03:12:38  deploy root 'C:\Share' (Discovered); the volumes considered were: C:\, X:\
```

**WinPE gave the content disk `C:` again**, on a boot image with a completely
different contents list from the one S9.1 measured. The RAM disk is `X:`. The
image carries the volume-relative `\Share` and `Resolve-HDTDeployRoot` found the
volume holding `rules.yaml`; the payload writes no drive letter of its own.

This is the failure mode the plan called the likeliest, and the reason it is
dangerous is worth restating: **a lettered `deployRoot` baked into the image
would have booted, found nothing, and powered the machine off — which from
outside is indistinguishable from success**, because the discriminator for the
whole demonstration is "the VM shut itself down". The assertion that
`deployRootSource` is `Discovered` is what makes the two distinguishable.

### S12.3 — the state document was frozen by its own relocation ⚠

**The most valuable finding of the plan, and BOTH E2E files found it in the same
run.** `Deployment.E2E.Tests.ps1` (M3) and `UnattendedDeployment.E2E.Tests.ps1`
(M4) each reported:

```
Expected @('Completed','Completed','Completed','Completed','Completed'),
but got  @('Completed','Completed','Pending','Pending','Pending')
```

on deployments that had **succeeded**, booted into Windows, and come up with the
right computer name.

The chain:

1. the state document lives **in the log directory** by default —
   `-StatePath` defaults to `<logRoot>\state.json`;
2. 05-03's relocation **mirrors the whole log tree** onto the target volume, so a
   copy of `state.json` arrives at `W:\HDT\Logs\state.json`;
3. the writes kept going to `X:\HDT\Logs\state.json`, because the loop
   deliberately did not repoint the primary — so the copy on the target volume
   was **frozen at the moment of the move**, which is the end of step 2;
4. `Copy-HDTLog` ships the **relocated** directory to the share. So the state
   document a technician reads off the deployment share reported three steps
   `Pending` on a run that finished.

**A stale state document is worse than an absent one, because it is believed.**

DESIGN 4.4.6's heartbeat was moved for exactly this reason, in exactly this
place, ten lines earlier — 05-03 wrote "one left behind on the RAM disk would put
a stale 'Running' in the copy a technician reads". The state document was not,
and 05-03's stated reason for that ("moving the primary would make the mirror the
only copy on a machine that has not rebooted yet") is wrong on its own terms:
after the move there are **two** copies on the target volume, and the one on the
RAM disk dies at the reboot regardless.

Fixed: a state path that was under the **old** log root is rebased onto the new
one. A caller who supplied `-StatePath`, or who put it outside the log directory,
is not overruled. The second `-Task e2e` run — with the fixed engine staged into
a freshly built boot image — is **93 passed, 0 failed**.

**It sat unproven for two plans.** 05-03 added the relocation; S10 then stopped
anybody running `-Task e2e`; 05-04 added no E2E. **The first `-Task e2e` run
after the media came back found it in both files at once** — which is the
argument for running the slow suites, made by the suites themselves.

### S12.4 — `GetVirtualSystemThumbnailImage` returns 32775 intermittently ⚠

Two of the four M4 screenshots and one of the M3 ones failed with
`ReturnValue 32775` from `Msvm_VirtualSystemManagementService`. The ones that
worked (`m4-01-winpe.png` at t+150 s, `m4-04-windows.png` after the Windows boot)
are the two a human is asked to look at, so the run lost nothing — but a harness
that **asserted** on a screenshot would have been red for a reason that has
nothing to do with the deployment.

SPIKES S4 already said screenshots are diagnosis and never assertion. This is the
first measured reason to keep it that way: the call itself is not reliable.
`Save-HDTLabVmScreen` warns and returns rather than throwing, which is why the
run continued.

### S12.5 — the timings, beside SPIKES S9.12's

| Leg | S9.12 (M3, 04-04) | S12 (M4) |
|---|---|---|
| Boot image built by `Update-HDTBootImage` | — (hand-built, S1/S3) | **134 s**, then **128 s** |
| Content disk staged | 12–14 s | **11 s** — and it no longer carries the engine |
| WinPE boot → five steps → shutdown | 273 s wall, engine reported 100 s | **248 s / 247 s wall, engine reported 105 s** |
| First Windows boot to a settled heartbeat | 265 s | **319 s**, both runs |
| Whole `-Task e2e` (three files, two full deployments) | — | **1561 s** |

Two runs because the first found S12.3 and the second proved the fix. Per file
on the green run: `Deployment.E2E` 640 s, `UnattendedDeployment.E2E` 730 s,
`WinPeSmoke.E2E` 190 s. **93 passed, 0 failed.**

**The M4 leg is 25 s FASTER end to end than the M3 one that was started by hand**,
which is not what anyone would have guessed: the machine starts deploying the
moment `wpeinit` returns, instead of after a harness slept 150 s and typed.
The engine's own 105 s against 100 s is the same work.

The build's 134 s is consistent with S11.1's 123 s on a workspace with one less
`extraContent` entry. **A full M4 demonstration from nothing is about 26
minutes**, of which 21 are the two deployments waiting for Windows.

### S12.6 — what this run did NOT prove

Stated here rather than left to be inferred:

- **No VM deployed over SMB.** PROJECT.md rule 2 keeps test VMs on the isolated
  `HDT Lab` switch and S6 records that a VM there cannot reach a host share, so
  the image declares `provider: Local`. The `Smb` provider's evidence is 05-02's
  unit refusals and its loopback integration run.
  **SUPERSEDED BY S14**, which deployed over SMB on `HDT External`. This entry
  records what *this* run did not prove and is left standing as that record.
- **No WDS import has ever executed.** This host is Windows 11 Pro;
  `Get-Module -ListAvailable WDS` and `Get-Command wdsutil.exe` both return
  nothing, and PROJECT.md rule 3 forbids standing one up beside CM01's PXE
  responder. `New-HDTWdsService` throws `HDTDependencyError` here, which is
  asserted, and the replace-in-place semantics are asserted against a fake.
- **The PXE payload has never been network-booted.** It is staged and
  hash-verified against the real ADK media and the real boot WIM; that is
  completeness, not bootability.
- **`New-HDTPowerService` still has never executed.** ROADMAP M2 asked whether
  WinPE needs `wpeutil reboot` rather than `shutdown.exe` and called it a phase
  05 question. `DEMO-M4` has no `Restart` step, so the only evidence this phase
  produces is the payload's own `endedWith: wpeutil shutdown` — **which is not
  the same thing** and must not be reported as if it were.

### Lab safety

Every Hyper-V call name-filtered and module-qualified. `CM01` and `DC01` were
recorded before each run and asserted identical after, in `AfterAll` blocks that
run on failure too — both `Off` and untouched throughout. Every VM was created
and removed through `New-`/`Remove-HDTLabVirtualMachine`; nothing touched
`Default Switch`, `HDT External` or `FSE Switch`. `C:\HDTLab\vms` was empty before
and after.

---

## S13 — `shutdown.exe` is not in WinPE, and a build was calling a run that never happened a success ⚠✅

Date: 2026-08-14 · phase 05 plan 06. **The question ROADMAP M2 deferred to phase
05, answered by execution rather than by argument** — and a second finding, in
the build script, that the answering of it turned up.

### S13.1 — the answer, and it is not a matter of style ⚠

`docs/ROADMAP.md` M2 asked "whether WinPE needs `wpeutil reboot` rather than
`shutdown.exe`" and named phase 05 as the owner. Five plans went by;
`05-VERIFICATION.md` recorded it `not_answered`; `New-HDTPowerService.ps1` and
`PowerService.Contract.Tests.ps1` both carried the comment *"UNVERIFIED,
RECORDED FOR PHASE 05"*.

A read-only mount of the boot image `Update-HDTBootImage` built in 05-04,
`Windows\System32`:

```
shutdown.exe     False
wpeutil.exe      True    32768
wpeinit.exe      True    61440
powershell.exe   False        <- it is under WindowsPowerShell\v1.0\, not System32
```

**`shutdown.exe` is not there.** The adapter defaulted to it, the engine's
`Restart` step calls `IPowerService.Restart()`, and in WinPE that call could only
ever have raised *"The term 'shutdown.exe' is not recognized"*.

**Why nothing caught it, which is the more useful half:**

- `DEMO-M3` and `DEMO-M4` both deliberately have **no `Restart` step** — the
  reboot ceremony arms autologon in a registry and an LSA secret that belong to
  the RAM disk in WinPE. So the one path that would have executed it never ran.
- The `IPowerService` contract's **real row is skipped permanently**, and
  correctly: a contract test may not reboot the machine running it, and there is
  no dry-run form of `shutdown.exe`.
- The fake shrugs. It records `Restart` and returns, which is the whole point of
  it — and it is exactly SPIKES S9.3's shape (`Clear-Disk` on a RAW disk), where
  a fake that accepts a call the world refuses keeps a suite green over code that
  cannot work.

Fixed the way the repository splits everything else: **the decision is pure and
the adapter is dumb.** `Get-HDTPowerCommand -Environment WinPE|FullOS -Operation
Restart|Stop -DelaySecond n` returns the command, the exact argument array, a
`SleepSecond` and a reason; 26 tests. `New-HDTPowerService -Environment` is
**mandatory and undefaulted** — a better default would have left every existing
caller inheriting the wrong answer in silence, which is what happened the first
time. The three callers (`Start-HDTDeployment.ps1`, `Start-HDTResume.ps1`, the
M3 lab launcher) all already know which world they are in; nothing detects
anything.

`wpeutil reboot` and `wpeutil shutdown` **take no delay argument**, so a
sequence's `delaySecond:` is honoured by sleeping first. The plan carries that as
`SleepSecond` and the adapter sleeps unconditionally — `Start-Sleep -Seconds 0`
is a no-op, and a guard would have been a branch.

### S13.2 — the adapter has now executed, in WinPE, and the proof is a file that is not there ✅

`New-HDTPowerService` had **never executed anywhere in this repository** across
three phases. `tests/e2e/WinPeSmoke.E2E.Tests.ps1` now ends its VM with it.

The discriminator matters more than the run. The smoke VM was always going to
power off — the probe used to call `wpeutil` itself — so "the VM ended" proves
nothing about the adapter. The probe therefore:

1. writes `PROBE.json` first, carrying `shutdownExe`, `wpeutilExe`,
   `powerEnvironment`, `powerCommand`, `powerArgument` and `powerError`;
2. calls `$power.Stop(0)`;
3. waits **120 s**, and only then writes **`FALLBACK.txt`** and calls `wpeutil`
   directly.

**The assertion is that `FALLBACK.txt` is ABSENT.** A fast, readable failure
instead of a fifteen-minute timeout, and a claim that cannot be satisfied by a
machine that was going to shut down regardless.

The probe also measures the same fact from **inside a running WinPE**, which is a
better witness than a mounted image: the integration file reads the WIM, the
probe reads the machine that WIM became.

### S13.3 — `./build.ps1` was reporting BUILD SUCCEEDED over a file that never ran ⚠

**Found by walking into SPIKES S9.15 for the fourth time, and the first time its
symptom was a MISSING result rather than a wrong one.**

The first draft of `tests/integration/WinPeContent.Integration.Tests.ps1` read a
`BeforeAll` variable from a `Context`'s `-Skip:`. Discovery and run do not share
a scope, so under the `Set-StrictMode -Version Latest` that `build.ps1` sets,
**discovery died**. Pester dropped three of the four contexts and reported:

```
Discovery in ...WinPeContent.Integration.Tests.ps1 failed with:
  The variable '$script:hasBuilt' cannot be retrieved because it has not been set.
Discovery found 4 tests in 2.11s.

Tests Passed: 4, Failed: 0, Skipped: 0
```

Four passed out of a file with fourteen assertions in it. And the result object:

```
Result                Failed
FailedCount           0
FailedContainersCount 1
```

**`build.ps1` read `FailedCount` alone, in all three of its suites.** So a
discovery failure — the commonest failure mode this repository has, recorded
three times already — printed **BUILD SUCCEEDED**. That is the empty-dispatch
defect `tests/unit/BuildScript.Tests.ps1` was written for, in a new costume: a
build that ran nothing is not a build that succeeded.

`Assert-HDTPesterResult` now judges every suite, checks `FailedContainersCount`
**before** `FailedCount`, and names the file and the error. **Proven by planting
one**, which is the only proof S9.15b accepts:

```
test: 4893 passed, 0 failed, 42 skipped
BUILD FAILED: 1 test file(s) could not be run at all - a discovery or setup
  failure means their assertions never executed, and no test failing is not the
  same as every test passing.
  ...\ZZPlantedDiscoveryFailure.Tests.ps1: The variable '$script:plantedFlag'
  cannot be retrieved because it has not been set.
```

**Note what the first line says.** 4893 tests passed. Under the old condition
that was a green build.

### S13.4 — what this did NOT prove

- **No `Restart` step has executed in WinPE.** `IPowerService.Stop` has, through
  the real adapter, in WinPE. `Restart` differs only in the verb it takes from
  the same table, and the table is asserted — but "differs only in" is an
  argument, not a measurement, and it is written here as one.
- **`Start-HDTResume.ps1`'s `FullOS` leg is still unexecuted.** Nothing in this
  repository has ever run `shutdown.exe /r` through the service, because doing so
  would restart the developer's machine.
- **The delay is unmeasured.** Every run uses 0.

### S13.5 — the boot image build could not run under Windows PowerShell 5.1, and a progress meter was why ⚠

**Found by the guard S13.3 had just added, on its first real use.** The first
`./build.ps1 -Task integration` ever run under `powershell.exe` died in
`BootImage.Integration.Tests.ps1`'s setup:

```
Exception calling "NewIso" with "3" argument(s): "The running command stopped
because the preference variable "ErrorActionPreference" or common parameter is
set to Stop: 0% complete"
```

**`0% complete` is oscdimg's progress meter.** Every adapter in this repository
captures its tool's own words —

```powershell
$output = @(& $oscdimg @full 2>&1)
```

— because *"oscdimg failed"* without oscdimg's sentence is the log entry that
wastes an hour. Under **Windows PowerShell 5.1** that line wraps each stderr line
in an `ErrorRecord`, and the `$ErrorActionPreference = 'Stop'` that engine code
is required to set (CLAUDE.md rule 7) makes the **first** one terminating. So the
call died before `$LASTEXITCODE` was ever consulted, and a tool that had merely
been chatty was indistinguishable from one that had failed.

Reproduced in one line, both ways:

```
PS 5.1> $ErrorActionPreference='Stop';     & cmd /c 'echo oops 1>&2' 2>&1   ->  THREW: oops
PS 5.1> $ErrorActionPreference='Continue'; & cmd /c 'echo oops 1>&2' 2>&1   ->  oops
```

**pwsh 7 does not do this**, and every `-Task integration` run before 05-06 was
under pwsh. `-Task test` had always been run under both engines, as CLAUDE.md
requires — but *test* is not the suite that shells out. **Five adapters were
affected**: `oscdimg`, `dism /Set-ScratchSpace`, `bcdboot`, `reagentc` and
`bcdedit` — which is to say the ISO build and most of `ConfigureBoot`.

Fixed with one line per method, `$ErrorActionPreference = 'Continue'` local to
the method scope. It adds no branch, so the adapters keep rule 1's exemption from
TDD, and `tests/unit/NativeCommandStderr.Tests.ps1` is what keeps the next one
honest: it finds every `2>&1` in `src/` and requires the line. It deliberately
does **not** cover `*>&1`, which is `New-HDTScriptInvoker` merging the streams of
an administrator's own script — an error there SHOULD stop the step, and
disarming the preference would change behaviour rather than fix a trap.

**The general lesson, and it is not the one anybody would have guessed:** the
rule "green under both engines" was being honoured only for the suite that never
touches an external tool. The suites that do had only ever run under the engine
that is more forgiving than the one HDT actually ships on.

### S13.6 — a destructive adapter was trusting an ambient preference, and once it was not Stop the failure was silent ⚠

Found by the first `./build.ps1 -Task integration` run that got past S13.5. On
**both** engines:

```
The disk has not been initialized.
[-] IDiskService against a scratch VHDX.clear and initialise.refuses to clear a
    disk that has never been initialised
    Expected an exception with message like '*not been initialized*' to be
    thrown, but no exception was thrown.
```

Read those two lines together. **`Clear-Disk` failed — its own message is right
there — and `ClearDisk` returned as though it had not.** The disk was `RAW`,
asserted one line earlier in the same test. Had this been a deployment rather
than a test, `Invoke-HDTDiskPartitionStep` would have carried straight on to
partition a disk it believed it had cleared.

The mechanism is that `Clear-Disk` writes a **non-terminating** error, and every
Storage call in `New-HDTDiskService` was written without `-ErrorAction`. That is
correct-by-accident while `$ErrorActionPreference` is `Stop` — which the module
sets and which CLAUDE.md rule 7 requires — and means the opposite the moment it
is not.

**Why it was not `Stop` in that scope was NOT ESTABLISHED, and inventing a cause
would be worse than saying so** (the position S9.13 and S10 took). What is known:

- it reproduces **only** in the full seven-file `-Task integration` run, on both
  pwsh 7.5.8 and Windows PowerShell 5.1;
- it does **not** reproduce with the file alone (24/24), with
  `DiskPartition` + `DiskService` (43/43), with `BootImage` + `DiskService`
  (63/63, and the module's `$ErrorActionPreference` read back `Stop` afterwards),
  with all three (82/82), or with `DiskService` plus the four files that follow
  it (53/53) — the last three of those built through the same
  `New-HDTPesterConfiguration` the build uses;
- a `$ErrorActionPreference = 'Continue'` assigned inside a `ScriptMethod` does
  **not** leak to module scope, tested directly on both engines, so S13.5's fix
  is not the cause.

**The fix is not to find the caller. It is that the question should never have
been askable.** All seven destructive Storage calls now pass `-ErrorAction Stop`
explicitly (`New-Partition` in its splat, being the only splatted one), so the
behaviour is a property of the code rather than of whoever called it.
`tests/unit/DiskServiceErrorAction.Tests.ps1` keeps it that way — and asserts the
converse for `Get-Disk`, `Get-Partition` and `Get-Volume`, where an empty result
is a legitimate answer that DESIGN 9.1's refusal to guess a target is built on.

**The general form of this, worth more than the instance:** the whole engine
relies on ambient `$ErrorActionPreference` for a non-terminating error to be
noticed. Everywhere that matters — anything destructive — should say so itself.

### S13.7 — the numbers, and the file that is not there ✅

Everything through `./build.ps1`, and — for the first time in this repository —
the slow suites under **Windows PowerShell 5.1** as well as pwsh.

| Run | Engine | Result |
|---|---|---|
| `-Task test` | pwsh 7.5.8 | **4907 passed, 0 failed, 42 skipped** |
| `-Task test` | Windows PowerShell 5.1.26100.8655 | **4762 passed, 0 failed, 187 skipped** |
| `-Task lint` | pwsh 7.5.8 | 0 diagnostics across 344 files |
| `-Task integration` | **Windows PowerShell 5.1** | **138 passed, 0 failed, 0 skipped**, 607 s |
| `-Task e2e` | **Windows PowerShell 5.1** | **98 passed, 0 failed, 0 skipped**, 1566 s |

Integration by file (5.1): `BootImage` 325 s, `ImageService` 152 s,
`WinPeContent` 70 s, `DiskPartition` 26 s, `DiskService` 24 s, `PxePayload` 6 s,
`SmbContentProvider` 3 s. E2E by file: `UnattendedDeployment` 740 s,
`Deployment` 640 s, `WinPeSmoke` 186 s.

`PROBE.json`, written by the smoke VM from inside WinPE and read off its content
disk after it powered itself off:

```json
"psVersion":        "5.1.26100.1",
"shutdownExe":      false,
"wpeutilExe":       true,
"powerEnvironment": "WinPE",
"powerCommand":     "wpeutil.exe",
"powerArgument":    "shutdown",
"powerError":       ""
```

**`shutdownExe: false`, measured by the machine itself.** And the assertion that
matters is about a file that does not exist: `FALLBACK.txt` was **absent**, so
`New-HDTPowerService` — not the probe's own `wpeutil` line — is what ended that
machine. The file took 186 s, well inside the 120 s the fallback would have
added on top.

### Lab safety

**No VM was created by anything in 05-06 except the three the E2E suite already
creates and removes.** `CM01` and `DC01` were read back name-filtered and
module-qualified before and after every run — both `Off` and untouched
throughout. Zero `HDT-*` VMs and an empty `C:\HDTLab\vms` afterwards. Nothing
mounted: `Get-WindowsImage -Mounted` is empty. This host's disk 0 is
`GPT|True|True` before and after, and the only images this plan mounted were
mounted `-ReadOnly` and dismounted `-Discard` in a `finally`. The planted
discovery-failure file was removed in the same step that proved the guard.

### S9.16 — a "no keyboard input" search that looked at the wrong symbol ⚠

Asked whether anything still typed into WinPE, this project answered "zero
typing calls" after searching the E2E suite for `TypeText` and `TypeKey` — the
two `Msvm_Keyboard` methods SPIKES S4 recorded. The search came back empty and
the answer was wrong.

**The suite typed through a wrapper.** `tests/helpers` exposes a single lab
helper that wraps both WMI methods, and two E2E files called it — one line each,
sending the same `for %d in (C D E F G) do @if exist ...` scan at the WinPE
prompt. Searching for the methods the wrapper calls is a search that cannot find
the wrapper's callers, so it reported the property as held on a suite that
violated it twice.

**The shape of the mistake is general**: a "nothing does X" search must name the
symbol callers actually write, not the one the implementation eventually
reaches. Where a wrapper exists, the wrapper IS the symbol to search for, and
the underlying calls are the secondary check rather than the primary one.

**What replaced the search.** `tests/contract/NoKeystroke.Contract.Tests.ps1`
scans every `.ps1` under `tests/e2e` for the wrapper FIRST and the two methods
and the keyboard class after it, over both the comment-stripped token stream and
the raw text. It carries anti-vacuity floors on file count and total scanned
length (S9.15b: a "no file contains X" assertion is trivially true of no files),
and it was watched failing against a planted violation before being trusted
green — 13 passed / 2 failed with the offending path named in the message, then
15 passed once the plant was removed.

**The property is now asserted from inside the guest as well**, which is the
part a source scan cannot cover: `startnet.cmd` sets `HDT_LAUNCHED_BY=startnet`
and nothing else does, both lab payloads record it, and each E2E asserts it. A
harness that went back to typing would leave that field empty.

## S14 — the first deployment over SMB, through the product ✅

**The gap every verification report had led with, closed.** Until now every
deployment HDT ran used the `Local` provider against a VHDX bolted to the VM.
The `Smb` provider's evidence was unit refusals, an operation-list equality test
and a loopback run - never a machine in WinPE pulling an image across a network.

**Measured, on `HDT External`, with nothing typed:**

```
status             : Succeeded          sequenceId : DEMO-M4
computerName       : HDT-SMB-01         provider   : Smb
deployRoot         : \192.168.2.108\HDTShare
resolvedDeployRoot : \192.168.2.108\HDTShare     connected : True
logPath            : W:\HDT\Logs
logDestination     : \192.168.2.108\HDTShare\Logs
launchedBy         : startnet           elapsedSecond : 230
heartbeat after reboot: OK
```

The five steps ran in order and all completed; the 64 GB target grew to ~12 GB
as the WIM came over the wire; the machine rebooted into full Windows carrying
the computer name the per-machine override set.

### What had to be true, and was

- **`HDT External`, not `HDT Lab`.** The isolated switch has no DHCP, so a VM
  there lands on APIPA and cannot reach the host - the reason this went unproven
  for five phases. On the external switch the lease arrived in **1 second**
  (`192.168.2.118/24`, gateway `192.168.2.1`).
- **The firewall rule already existed**: `HDT Lab SMB (445) inbound`, scoped to
  `192.168.2.0/24` and `172.30.30.0/24`. No host change was needed.
- **The credential comes from the workspace, in two halves** (DESIGN 6.3): the
  USERNAME in `workspace.yaml`'s `credential:` block, the PASSWORD in
  `Control\share-credential.json` via `Set-HDTShareCredential`. A first attempt
  omitted the block, and `Update-HDTBootImage` embedded nothing - producing an
  image that booted and then refused in WinPE. It now warns and turns
  `promptForCredential` on instead, which is MDT's behaviour.
- **`Get-NetIPAddress` does not exist in WinPE.** NetTCPIP is not in an ADK
  image. `Win32_NetworkAdapterConfiguration` is, because `WinPE-WMI` is one of
  the six required components.
- **`Get-VMBios` does not exist for Generation 2.** The BIOS GUID comes from
  `Msvm_VirtualSystemSettingData.BIOSGUID`, matched on the VM's `Id`.
- **The rules must name the task sequence.** `bootstrap.json` carries an empty
  `sequenceId` deliberately - one image, many sequences - so `HDTTaskSequenceID`
  has to be resolved from the rules, exactly as MDT resolves `TaskSequenceID`
  from `CustomSettings.ini`. The first run failed with precisely that sentence.

### Lab safety

`CM01` and `DC01` no longer exist on this host - the user deleted them. Nothing
in this spike created, touched or removed any VM but `HDT-Smb-Probe` and
`HDT-Smb-Deploy`, both `HDT-*`, both Generation 2, both under `C:\HDTLab\vms`.

## S15 — the Welcome screen, in WinPE, through the product ✅⚠

**W2's evidence.** W1 proved a window renders in this image by loading the XAML
itself. This ran the whole product path on the machine instead, unattended, on
`HDT External`:

```
launchedBy         : startnet          psVersion   : 5.1.26100.1
moduleImported     : True              modulePath  : X:\HDT\Modules
consoleHidden      : True              consoleRestored : True
networkRead        : True              hasLease    : True
ipAddress          : 192.168.2.126     subnetMask  : 255.255.255.0
gateway            : 192.168.2.1       dnsServer   : 1.1.1.1, 4.2.2.1
adapterDescription : Microsoft Hyper-V Network Adapter
fieldCount         : 7                 shown       : True
action             : Cancel            showError   : (none)
```

`Get-HDTNetworkConfiguration` → `Get-HDTWizardField` → `Show-HDTWizard` →
`New-HDTWizardHost`. The probe loads no XAML and decides no answer.

### What this settles

- **`Win32_NetworkAdapterConfiguration` reads a real lease in WinPE.** S14 said
  `Get-NetIPAddress` is absent; this is the positive half - the WMI route
  returned the address, mask, gateway and *both* DNS servers on a live machine.
- **`Hide-HDTShellWindow` works and reverses.** `consoleHidden` and
  `consoleRestored` are both true, and the screenshot has no black
  `X:\Windows\System32>` behind the wizard. `-WindowStyle Hidden` on the
  `entryCommand` is **not** sufficient on its own: it hides the PowerShell host,
  not the `cmd.exe` that `startnet.cmd` runs in. Both are needed.
- **A dismissed window is a Cancel, on the machine.** The probe closes the
  wizard with `WM_CLOSE`, which runs no handler, and the answer came back
  `Cancel`. That is the property that keeps a dismissed wizard from meaning
  consent to partition a disk, asserted somewhere other than a unit test.
- **The module loads from `X:\HDT\Modules`.** `Update-HDTBootImage` already
  stages the engine, `powershell-yaml` and `UI\` into the image, so there is
  nothing to scan a content disk for.

### Traps this hit

- **`FindWindow($null, $title)` answers 0, always.** `$null` cast to a `[string]`
  P/Invoke parameter marshals as **empty, not null**, so it searches for a
  window class literally named `""`. Use `[NullString]::Value` - or, better,
  `Process.MainWindowHandle`, which needs no title to keep in step with markup.
- **`GetVirtualSystemThumbnailImage` returns 32775 ("invalid state") often
  enough that one screenshot at a fixed time is not a screenshot.** The first
  run finished with no picture at all. Capture in a burst across the window the
  wizard might be up in.
- **⚠ `Save-HDTLabVmScreen` decodes the thumbnail palette wrongly.** The image
  is legible and correctly laid out, but the colours are not the wizard's -
  magenta where `#FF1E1E1E` should be. The helper is what is wrong, not the
  window; the same XAML renders correctly on the desktop. Not yet fixed, and it
  degrades "a screenshot is the evidence" for every increment after this one.

### Lab safety

The only VM created, started or removed was `HDT-W2-Wizard`: `HDT-*`,
Generation 2, under `C:\HDTLab\vms`, on `HDT External`. It is powered off and
left in place.


## S16 — dism's progress meter reaches PowerShell live, and a callback runs in somebody else's module ✅⚠

Run on 2026-08-17, on this host, under Windows PowerShell 5.1. Both findings are
measured, not reasoned about.

### The question

`Expand-WindowsImage` reports progress on PowerShell's *progress stream*, which
is a console bar and not data: nothing in WinPE reads it and there is no
parameter that turns it into something a caller can use. `dism.exe` prints a
percentage on stdout - MDT's mechanism - but redirected native output is a known
trap: the meter repaints with carriage returns, and if PowerShell buffers on
newlines alone the whole transcript arrives at the end, which is a bar that
jumps from nothing to done.

### ✅ It arrives live, through the plain call operator

`& dism.exe /Export-Image ... 2>&1 | ForEach-Object { ... }` on the 324 MB ADK
`winpe.wim`: **206 pipeline objects across 12.1 seconds**, one repaint per
object, first at 79 ms and roughly one per 1% thereafter. A
`Diagnostics.Process` with `ReadBlock` on the raw stream was measured beside it
and gave the same cadence (102 chunks, 12.0 s) for considerably more code.

**So the adapter keeps the existing `&` + `2>&1` + exit-code pattern.** No
`Start-Process`, no async reader, no runspace. `New-HDTImageService.ApplyImage`
now runs `dism.exe /Apply-Image /ImageFile: /Index: /ApplyDir:` and hands every
line to a callback as it arrives.

### ✅ The captured transcript, and the shape of the meter

`tests/fixtures/image/dism-apply-image-output.txt` is a real
`dism /Apply-Image` of `winpe.wim`, 178 lines. Three things in it were not
guessable:

- at 1% the number floats in spaces, at 85% it has an `=` run on both sides,
  and at 100% it is embedded in a solid bar with **no space around it at all**:
  `[==========================100.0%==========================]`. A pattern
  anchored on whitespace reads the first two and misses the one that says the
  apply finished.
- the run goes 1, 2, 3 ... 85 and then **jumps straight to 100**. A step that
  only reported on a five-point stride would say 85% and then nothing at all
  about an apply that finished, which is why `Invoke-HDTApplyImageStep` reports
  100 unconditionally.
- every meter line is preceded by an empty pipeline object.

### ⚠ A scriptblock invoked from a PowerShell class resolves commands in THAT class's module

The trap that cost the most here, and it is not about DISM at all.

`Invoke-HDTApplyImageStep` builds its progress callback with `.GetNewClosure()`
inside the Hephaestus module and hands it to `IImageService.ApplyImage`. The
real adapter is a `pscustomobject` in the same module and it worked. The
**fake** is a PowerShell `class` in `HDTFakes` - and a scriptblock invoked from
a class method resolves its commands **in the class's module**, where
`ConvertFrom-HDTDismProgressLine`, private to Hephaestus, does not exist.

It failed as `The term '...' is not recognized`, into the callback's own
`catch`, and looked exactly like an apply that printed no percentages: the step
still returned `Completed` and every other assertion still passed.

**The fix is to resolve the commands where the function is and capture the
`CommandInfo`:**

```powershell
$parseProgress = Get-Command -Name 'ConvertFrom-HDTDismProgressLine'
...
$percent = & $parseProgress -Line $Line
```

A `CommandInfo` invoked with `&` does not care whose scope it is called from.
Exported commands happen to resolve anyway - which is why `Write-HDTLog` looked
fine and only the private function broke - so the failure is invisible until a
callback reaches for something private. **Any scriptblock this engine hands to a
service must assume it will run in a foreign module.**

### ⚠ Applying an image to a plain directory leaves content an unelevated user cannot delete

The fixture capture applied `winpe.wim` to `C:\HDTLab\scratch\HDT-dism-fixture`.
dism applies the WIM's own security descriptors, so the tree ends up owned by
`NT SERVICE\TrustedInstaller`; `rd /s /q` and `icacls /grant` both fail without
elevation, and taking ownership needs it too. The integration tests apply to a
mounted VHDX which is detached and deleted whole, so they are unaffected - but a
scratch *directory* apply must be cleaned up from an elevated shell:

```powershell
takeown /f C:\HDTLab\scratch\HDT-dism-fixture /r /d y
icacls C:\HDTLab\scratch\HDT-dism-fixture /grant "$env:USERNAME:(OI)(CI)F" /t /c /q
rd /s /q C:\HDTLab\scratch\HDT-dism-fixture
```

### Lab safety

No VM was created, started or removed. Everything written went to
`C:\HDTLab\scratch\`, into directories this work created.


## S17 — Open CMD shut the machine down, and elevation is not the privilege ✅⚠

Run on 2026-08-17 against `HDT-Wizard-01` (Generation 2, `HDT External`,
`C:\HDTLab\vms`) booting a freshly built `HDTPE_wiz_x64.iso`. Everything here
was observed on the VM or on the build host, not reasoned about.

### ⚠ The one button for debugging a machine ended the machine

Pressing **Open CMD** on the Welcome screen opened a prompt, and then:

1. the payload threw `HDTDeploymentCancelled` - which is how it deliberately
   stops - and the catch classified every throw as `Failed`, printing `FATAL`
   plus an `Out-String` of the whole error record into the parent console;
2. the tail slept five seconds and ran `wpeutil shutdown`.

So the technician got a command prompt for five seconds and then a powered-off
machine. Fixed by `$result['leftAtCommandPrompt']`, set at both request sites
and guarding the `wpeutil` call; a `HDTDeploymentCancelled*` message now reports
`Cancelled` and one Warning line. `$ending` still holds only `shutdown` or
`reboot`, because a test pins its two values against `Get-HDTPowerCommand`.

Verified after the rebuild: prompt at `X:\Windows\System32>`, VM still Running
minutes later, and `X:\HDT\RESULT.json` reading

    Cancelled
    nothing - the technician was left at a command prompt
    True

### ⚠ SeTakeOwnershipPrivilege is DISABLED in an elevated token

`Update-HDTBootImage` could not brand a clean mount:

    the WinPE background could not be written over
    '...\mount\Windows\System32\winpe.jpg': Exception calling "TakeOwnership"...
    "Attempted to perform an unauthorized operation."

The build was fully elevated - `IsInRole(Administrator)` was `True` in the
process AND in the child. `whoami /priv` is what told the truth:

    SeTakeOwnershipPrivilege    Take ownership of files or other objects    Disabled

The privilege is in the token and switched off, and .NET's `SetAccessControl`
never enables it. **An "unauthorized operation" from SetOwner therefore reads
exactly like "run as administrator" while already being administrator.**
`takeown.exe` enables the privilege itself, which is the entire reason the tool
exists; `IFileSystem.TakeOwnership` now runs `takeown.exe` then `icacls.exe`
with an exit-code check apiece. The rebuild that followed took 244 s and wrote
both artifacts.

Ownership goes to the **caller**, not to Administrators: `takeown /A` needs
`SeRestorePrivilege` as well - a second privilege to be defeated by - and owning
the file is enough to grant the rest. The grant names `*S-1-5-32-544`, because
`BUILTIN\Administrators` is a localised name icacls resolves against the host.

### ✅ BGInfo works in WinPE, and the wizard is what hides it

The image's `startCommand` runs
`Bginfo64.exe "X:\Tools\Bginfo\WinPE.bgi" /timer:0 /silent /nolicprompt`, and it
does paint: the captured screen shows
`DHCP Server: 192.168.2.1 | IP Address: 192.168.2.30 | MAC Address: 00-15-5D-86-01-29`
and `Model: Virtual Machine` along the bottom.

It is invisible during a deployment because **BGInfo paints the desktop
wallpaper** and DESIGN 11.1's wizard and progress window are full-screen. It
shows around and behind windows, and only where the `.bgi` positions it - the
lab's config puts it at the bottom.

A `.bgi` records the host's own wallpaper path in a `Wallpaper` entry
(`...\DisplayFusion\WallpaperGenerated_1_Full.png` on this host, a file WinPE
does not have). **That is not what makes it fail, and it did not fail** - the
entry is BGInfo's record of the machine the config was saved on. It was worth
half an hour of a wrong theory; the screenshot settled it in one frame.

### ⚠ The suite cannot be gated from a git worktree

`git worktree add` plus `./build.ps1 test` reports three failures that are not
defects: `ProtectedPath.Contract` does a `Substring` on the repository root, and
two `ConsoleTreeNode` cases read the workspace by its canonical path. All three
pass in the repository itself. Gate in the repository, not in a copy of it.

### Lab safety

`HDT-Wizard-01` was started and left running with its prompt open. No VM was
created or removed, and nothing outside `C:\HDTLab\Share\Boot` and
`C:\HDTLab\scratch\bootimage` was written.
## S18 — WinPE has no compositor, and a transparent window paints over everything ✅⚠

Run on 2026-08-21 against `HDT-ZTI-02` (Generation 2, `HDT External`,
`C:\HDTLab\vms`) booting `HDTPE_wiz_x64.iso`, rebuilt six times across the
session. Everything here was observed on the VM, and four fixes were shipped and
withdrawn before it was.

### ⚠ A wallpaper set behind a covering window is never painted

A boot image carrying a BGInfo start command showed the image's own `winpe.jpg`
and no BGInfo for the whole of WinPE — and then BGInfo's version appeared the
instant the Welcome screen opened.

BGInfo does not paint pixels. It sets the DESKTOP WALLPAPER and returns, which
marks the desktop as needing a repaint rather than performing one. In full
Windows, Explorer does that repaint immediately. **WinPE has no Explorer** —
`cmd.exe` is the shell — so nothing redraws the desktop and the last thing
actually painted there stays on screen. The first thing that forces a real
repaint is a window taking a chunk of the screen, which is why the Welcome
screen revealed it.

It was invisible until the console moved. `startnet.cmd`'s console covered the
desktop from boot to wizard, so a desktop that never repainted looked exactly
like one that did. Hiding the console for the whole run is what exposed it.

Fixed in `Hide-HDTShellWindow`, which now asks for a repaint straight after
`ShowWindow`:

    InvalidateRect(NULL, NULL, TRUE)      // a NULL window means EVERY window
    RedrawWindow(GetDesktopWindow(), ...) // RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN

### ⚠ `SPI_SETDESKWALLPAPER` with a null path REMOVES the wallpaper

The first attempt at that repaint called
`SystemParametersInfo(SPI_SETDESKWALLPAPER, 0, NULL, SPIF_SENDCHANGE)`, on the
belief that a null `pvParam` means "re-apply whatever is already set". **It does
not.** `pvParam` is the bitmap's path and null or empty means remove it. The boot
image built with that call came up on a **black screen**, having deleted the
BGInfo wallpaper it was written to reveal.

A repaint must never be spelled as a set. `InvalidateRect` reads and writes
nothing.

### ⚠ A transparent window's repaint is not clipped by what is above it

The boot status overlay is a WPF window with `AllowsTransparency="True"`. Its
lines were drawn ACROSS the Welcome screen — over the share box and the
credential fields a technician types into.

Two frames settled the mechanism. An **opaque** `cmd.exe` window covered the
overlay completely. The Welcome screen — also opaque, also full-screen, opened
BEFORE the overlay's next repaint — was bled through the moment the overlay
repainted. So the overlay was below in z-order and painting through anyway:
WinPE runs **no desktop compositor**, and a layered window's repaint goes to the
screen without being clipped by the windows above it.

`SetWindowPos(hwnd, HWND_BOTTOM, ..., SWP_NOACTIVATE)` was tried and changed
nothing, because z-order was never what was being violated. The code was
removed rather than left in: dead Win32 that encodes a wrong theory is worse
than none.

**So a transparent window and any other window cannot share a WinPE display.**
`Start-HDTDeployment` closes the overlay before every window it opens and opens
it again afterwards, replaying the last twelve lines of its transcript into the
new one.

### ⚠ Hiding a `ShowDialog` window destroys it

Between those two, the overlay was given `Hide()`/`Show()` so it could step
aside without losing its history. It never came back. `Visibility = Hidden` on a
modal window is `Hide()`, and hiding a modal window **makes `ShowDialog`
return** — the script block finished, the runspace pipeline completed, and the
window was gone. `Handle.IsCompleted` flipping to `$true` is the signal; a
desktop probe measures it in four seconds without a boot.

The window now uses `Show()` plus `[Dispatcher]::Run()`.

### ⚠ Two maximized windows were covering the wallpaper they were meant to reveal

`HDTProgress.xaml` and `HDTFailure.xaml` were `WindowState="Maximized"` with an
opaque backdrop, because the console used to be hidden only for the wizard and a
small dialog would have shown the black edges of a half-drawn prompt around it.
That stopped being true at step 4a. Both are now `SizeToContent="WidthAndHeight"`
and `CenterScreen` — the progress card measures 720x313 — and a contract
iterates every boot-image window rather than naming these two.

### `tasklist` is not in WinPE

Diagnosing the above from an F8 prompt: `'tasklist' is not recognized`. Use
`powershell -nop -c "Get-Process ..."`; `WinPE-PowerShell` is one of the six
components always injected.

### Lab safety

`HDT-ZTI-02` was started and stopped repeatedly and `C:\HDTLab\Share\Boot` was
rebuilt six times. No VM was created or removed. One dismount of
`C:\HDTLab\scratch\bootimage\mount` was needed after a build was killed
mid-flight and left the image `NeedsRemount`.


---

## S19 — `Win32_PnPEntity` is fully populated in WinPE ✅⚠

**The question S1 did not answer.** S1 proved `Get-CimInstance` works in WinPE
using `Win32_ComputerSystem`. `Win32_PnPEntity` is a **different provider
class**, and the PnP driver-match fallback — `Get-HDTPresentDevice`,
`Get-HDTDriverMatch` — is built entirely on it. If it answered empty in WinPE
the fallback would match nothing, silently, and every unrecognised model would
deploy bare. That is the failure the fallback exists to prevent, so it could not
stay assumed.

Verified in a Gen2 VM on **`HDT External`** with a real DHCP lease, running
WinPE from HDT's own built boot image. The probe wrote JSON straight to the
share and it was read back on the host — not transcribed off a screenshot:

```
Count: 44   WithHwId: 42   PnpClassPopulated: 32   ElapsedMs: 498
```

```json
{ "Name": "Microsoft Hyper-V Video", "PNPClass": "Display",
  "HardwareID": ["VMBUS\{da0a7802-...}", "VMBUS\{5620e0c7-...}"],
  "CompatibleID": ["VMBUS\{da0a7802-...}"] }
```

- **It works.** 44 devices, 42 carrying a populated `HardwareID` array, in
  **498 ms** — negligible against a deployment, and it runs once, only on the
  fallback path. No `pnputil /enum-devices` or SetupAPI P/Invoke fallback is
  needed. MDT's `Microsoft.BDD.PnpEnum.exe` has no job here, which is just as
  well because rule 4 forbids it.

- ⚠ **`PNPClass` is on 32 of 44 rows, not all of them.** One VMBUS row carries
  `null` for `Name` **and** `PNPClass`. So a class filter must treat an absent
  class as "unknown" rather than assuming every device has one — and a grid
  grouped by class has an empty bucket that is real data, not a bug.

- **`CompatibleID` is `null` on some rows** (ACPI Module Device, Basic Display)
  and populated on others. That is the same pattern a full OS shows, not a
  WinPE artefact — `Get-HDTPresentDevice` turns it into an empty array so
  StrictMode code downstream never reads a null.

**Method, worth keeping.** Driving WinPE by screenshot and OCR was tried first
and was far too slow for reading an array of hardware ids. What worked: put the
VM on `HDT External`, reach the cmd prompt through HDT's **own** wizard "Open
CMD" escape hatch with `Msvm_Keyboard` (Tab + Enter — no mouse), `ipconfig
/renew` for a lease, then one `powershell -NoProfile -Command` line that ran the
query, timed it, and `Set-Content`'d the JSON to the share. **Catch the answer
in a file, never off the screen.**

**And the switch matters, exactly as S6 says.** The VM was first created on
`HDT Lab` and got no lease and no route to the share — which is precisely what
S6 records, rediscovered the hard way. `HDT External` is the switch for anything
that needs the network.

`HDT-PnP-Spike`, its VHDX under `C:\HDTLab\vms\`, and the probe file were all
removed; they were created by this spike. `CM01` and `DC01` were never touched.

---

## S20 — the ADK's WinPE bootloader is below the Secure Boot SVN floor ⚠

**Rufus refuses to write the ISO quietly.** Writing
`C:\HDTLab\Share\Boot\HDTPE_wiz_x64.iso` to a USB stick raises:

> **Revoked UEFI bootloader detected** — Rufus detected that the ISO you have
> selected contains a UEFI bootloader that has been revoked and that will
> produce a "Security Violation" screen, when Secure Boot is enabled on a fully
> up to date UEFI system.

**This is not a defect in the image and not a bad build.** It is what the ADK
ships. The boot file HDT copies into its media is the ADK's own:

```
…\Windows Preinstallation Environment\amd64\Media\EFI\Boot\bootx64.efi
10.0.26100.1085 (WinBuild.160101.0800), dated 2024-11-16
```

**The gate is the SVN, not the DBX, and not the certificate.** Rufus's own log
says which of the three refused it — `C:\HDTLab\Share\Boot\Rufus\rufus.log`,
lines 33–41:

```
UEFI bootloaders analysis:
  • /EFI/Boot/bootx64.efi*
  Signed by 'Microsoft Windows Production PCA 2011'
  SVN version 3.0 is lower than required minimum SVN version 7.0!
  WARNING: '/EFI/Boot/bootx64.efi' has been revoked by Windows SVN
  • /bootmgr.efi*
  Signed by 'Microsoft Windows Production PCA 2011'
  SVN version 3.0 is lower than required minimum SVN version 7.0!
  WARNING: '/bootmgr.efi' has been revoked by Windows SVN
```

**Secure Version Number**: a version floor embedded in the loader itself, which
the firmware compares against a minimum it has been told to enforce. This loader
carries SVN 3.0 and the floor is 7.0, so it is refused — both files, for the
same reason.

Write the distinction down so nobody re-derives it, because the two are related
and are not the same mechanism:

| Mechanism | What it lists | How a build gets refused |
|---|---|---|
| **DBX** (forbidden-signature database) | **hashes** of specific revoked binaries, and revoked certificates | the firmware finds this exact file's hash in the list |
| **SVN** (Secure Version Number) | nothing — it is a **version floor** | the loader's own embedded SVN is below the enforced minimum |

Both are part of the response to **CVE-2023-24932 (BlackLotus)** — Microsoft
moved to an SVN floor precisely because revoking by hash does not scale across
every servicing build of a boot manager. What refused this image was the floor,
so no DBX entry names it and none needs to.

The ADK's copy is below the floor, so **every** WinPE stick built from this ADK
— MDT's, HDT's, or a hand-made one — hits it.

### Where every copy on this machine stands

Read tonight, from each source's own `bootx64.efi` / `bootmgr.efi`:

| Source | Version / date | Issuer |
|---|---|---|
| ADK WinPE Media (what HDT ships) | 10.0.26100.1085, 2024-11-16 | Production PCA 2011 |
| `C:\HDTLab\media\Win11-LTSC-2024\` | 10.0.26100.1041, 2024-09-06 | Production PCA 2011 |
| `C:\HDTLab\media\WS2025-Std\` | 10.0.26100.1041, 2024-09-06 | Production PCA 2011 |
| this laptop, `C:\Windows\Boot\EFI\bootmgfw.efi` | 10.0.28000.342, written 2026-07-12 | Production PCA 2011 |

Two conclusions, both tested tonight and both the opposite of the obvious guess:

- **The install media is not a fix.** LTSC 2024 and Server 2025 both carry
  `10.0.26100.1041` — **44 builds behind** the ADK's own copy. Swapping either
  one in is a regression, not a repair. The staged media is the first place
  anyone reaches for and it is the wrong one.
- **The certificate is not the discriminator.** All four are signed by
  *Microsoft Windows Production PCA 2011*, the patched loader included. A fully
  patched Windows still signs under it; only the SVN moved. Anyone comparing
  issuers will conclude all four are equivalent, and all four are not.

Note the tell on the patched copy: its build, **28000.342**, runs *ahead* of the
OS build it came from (26100). Servicing ships the boot manager on its own
version track, so a boot manager whose build number outruns the OS is the
post-revocation one. That is how to recognise a good source without a signtool.

**What it costs, exactly:**

| Secure Boot on the target | Result |
|---|---|
| **Enabled** | the machine shows "Security Violation" and will not boot the stick |
| **Disabled** | boots normally; nothing else about the deployment is affected |

Nothing HDT does is sensitive to Secure Boot. Driver injection, the wizard, the
engine and the share are all indifferent to it — this is purely whether the
firmware will start the media.

**For the lab: turn Secure Boot off on the test machine** (Dell: F2 at
power-on → Boot Configuration). That is the right answer for proving a
deployment and the wrong answer for a fleet.

**For production media this needs solving properly**, and it is not yet done:
the `bootmgr.efi` and `bootx64.efi` in the media have to be replaced with
current ones from a fully patched Windows, and the boot image rebuilt around
them. That is **now actually on the roadmap** — `docs/ROADMAP.md`, M4's "What M4
ships without" list, with the two other files it has to touch and the risk —
rather than fixed here, because it is a media concern rather than a driver one
and it deserves its own verification.

> This spike previously said the follow-up was "recorded on the roadmap" when
> nothing on either roadmap mentioned it. Corrected 2026-08-30, along with the
> DBX/SVN attribution above. A claim that work is tracked is worth exactly as
> much as the tracking entry.

### What is still unverified, stated so it is not assumed

- **Nobody has read the SVN of the `10.0.28000.342` loader.** It is the
  candidate replacement on the strength of its build number and its date, and
  that is inference, not measurement. `signtool` is **not installed on this
  host**, so nothing here reads an SVN directly.
- **The cheap test is Rufus itself**, because Rufus is what read the SVN in the
  first place: copy the patched loader into a scratch media tree, build an ISO
  from it, and let Rufus analyse the ISO. If the analysis comes back clean, the
  replacement clears the floor.
- **That answers the SVN and nothing else.** Whether a 28000-series boot manager
  boots against the ADK's 26100-era `EFI\Microsoft\Boot\BCD` is a **separate,
  untested question**, and it cannot be answered by an analyser at all — it
  needs a Generation 2 VM with Secure Boot on, booting the rebuilt media.

**Do not read the warning as "the ISO is untrustworthy".** Rufus phrases it as a
possible malware indicator because it cannot know where an image came from. This
one was built on this machine, from the installed ADK, minutes earlier.

## S21 — `tzutil` is not in WinPE, and the boot image's zone must be set offline ✅

**Verified by execution**, twice: at a real WinPE prompt (`tzutil` → *command
not found*; `w32tm` likewise), and by reading the images themselves —

```powershell
# neither the ADK's untouched WinPE nor a finished HDT boot image carries it
Get-WindowsImageContent -ImagePath '…\Windows Preinstallation Environment\amd64\en-us\winpe.wim' -Index 1
Get-WindowsImageContent -ImagePath '<share>\Boot\HDTPE_x64.wim' -Index 1
```

154 executables are reachable on WinPE's PATH in a built HDT image. `tzutil` and
`w32tm` are not among them. The captured set is
`tests/fixtures/winpe/winpe-command-amd64.json`, and
`tests/contract/StartnetCommand.Contract.Tests.ps1` asserts every command
`startnet.cmd` emits is in it.

**What it cost before it was found.** HDT wrote `tzutil /s "<id>"` into
`startnet.cmd` for a release. cmd.exe printed *'tzutil' is not recognized*,
startnet ran straight on to the next line, and **nothing failed anywhere** — the
build was green, the manifest recorded the startnet text containing the line, and
every deployment ran on the image's baked-in **Pacific Standard Time**. The only
visible symptom was the engine's `[datetime]::UtcNow` reading eleven hours out
while `time` at the prompt was correct: the hardware clock was right and the
*zone* had never moved.

**The answer file cannot set it either, and that was checked rather than
assumed.** `wpeinit` accepts exactly eight settings, all
`Microsoft-Windows-Setup`: Display, EnableFirewall, EnableNetwork, LogPath,
PageFile, Restart, RunSynchronous, RunAsynchronous. `TimeZone` belongs to
`Microsoft-Windows-Shell-Setup` and to the deployed OS's passes, so putting it in
`windowsPE` risks `wpeinit` rejecting the whole file. MDT's own
`Unattend_PE_x64.xml` carries `Microsoft-Windows-Setup` and nothing else, and
neither MDT nor PSD sets a WinPE zone at all.

**What works:**

```cmd
dism /Image:<mount> /Set-TimeZone:"Israel Standard Time"
```

Offline only — dism refuses it against `/Online`.

> ⚠ **CORRECTED BY S21.1 — the claim below was WRONG and cost a second
> defect.** `/Set-TimeZone` writes the **standard half only**: `Bias`,
> `StandardBias`, `TimeZoneKeyName` and `StandardName`. It leaves `DaylightBias`
> at 0, `DaylightName` empty, `StandardStart` and `DaylightStart` **all zeros**,
> writes **no `ActiveTimeBias` at all**, and leaves `DynamicDaylightTimeDisabled`
> at the 1 the ADK ships. That is why the lab still read one hour ahead after
> this spike was written. Read S21.1 before trusting anything here about what
> this command writes.

It writes
`HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation` (Bias, StandardBias,
DaylightBias, ActiveTimeBias, TimeZoneKeyName and the transition dates) as one
consistent set, and **validates the id against the image before writing** — so a
zone that does not exist fails the build, at a build host, with a message. That
key being read at boot is not a hope: the -8 the lab measured *was* that key's
ADK default.

**The rule this leaves behind:** a boot image setting that needs a command at run
time needs that command proven present first. A build-time write has nothing left
to go missing.

## S22 — dism prints no meter for `/Apply-Unattend`, and a hand-built command line eats its own quote ✅⚠

Measured on 2026-08-29, on this host and on the machine that surfaced it. Both
findings correct something that was already believed here.

### ⚠ S16 is true of `/Apply-Image` and false of `/Apply-Unattend`

S16 established that dism's percentage meter reaches a PowerShell pipeline live,
and that finding is sound — for the verb it was measured on. It was then assumed
to hold for the servicing pass, and the assumption is wrong.

`LT-D5M1NN3` `run-20260829-223623` was deployed from a boot image built **after**
the meter was wired to `Invoke-HDTApplyUnattendStep`. In that one run:

| Step | `step.progress` records |
|---|---|
| `ApplyImage` | **20** |
| `ApplyDrivers` | 21 |
| `InstallApplications` | 9 |
| `ApplyUnattend` | **0**, across 153 seconds of real `offlineServicing` over 260 `.inf` packages |

The callback resolves and the parser works — the same run proves it on the other
verb. **`dism.exe` simply prints no percentage for `/Apply-Unattend`:** a banner,
then silence, then one sentence. MDT knew, and says so in code rather than in a
comment — `LTIApply.wsf:1042` reports a flat `99` immediately before shelling the
call, instead of driving a bar from its output.

**The rule this leaves behind:** a tool's meter is a property of the *verb*, not
of the executable. Measure the verb you are about to ship, on the machine, and
do not carry a finding across from a sibling command.

### ✅ The fix is MDT's poll-scrape-tick, and a pipeline cannot do it

`& dism | ForEach-Object` only runs the block when a line arrives, and the engine
is Windows PowerShell 5.1 and single-threaded — so between the banner and the
final sentence *nothing in the deployment executes*. That is the defect: not a
bar that moves too slowly, but a step that cannot report at all while it is the
only thing running.

`ZTIUtility.vbs`'s `RunCommandLog` (2173-2261) does all three — poll `oExec.Status`
with `SafeSleep 100`, scrape the percentage out of stdout, **and** beat a timed
event 41003 for when the tool says nothing. `ApplyUnattend` now starts dism
through `ProcessStartInfo`, drains stderr with `ReadToEndAsync` (the classic
redirect deadlock is not hypothetical), and waits on `ReadLineAsync` in 500 ms
slices, ticking a callback on every slice it waits through.

**`ApplyImage` keeps its pipeline, deliberately.** Its meter works on real
hardware, and the arrival of that meter is itself the proof the step is alive.
Converting it would risk the one number a technician watches to buy liveness it
already has.

### ⚠ `ProcessStartInfo.Arguments` is one string, and `W:\` ends in a backslash

.NET Framework — which is what WinPE has — gives `ProcessStartInfo` no
`ArgumentList`, only an `Arguments` **string**, which Windows parses back with
`CommandLineToArgvW`. `/Image:` takes the *root* of the offline installation,
`W:\`. Quoted the obvious way:

```
"/Image:W:\" "/Apply-Unattend:W:\Windows\Panther\unattend.xml" "/ScratchDir:W:\HDT\Scratch"
```

argv comes back as **one argument**:

```
/Image:W:" /Apply-Unattend:W:\Windows\Panther\unattend.xml /ScratchDir:W:\HDT\Scratch
```

The backslash escaped the closing quote and the rest of the line was swallowed as
text. dism would have been handed a single nonsense switch — a silent corruption
of the only call that runs `offlineServicing`.

The rule is **not** "escape every backslash": a backslash is only special
immediately before a quote. A run of them before an embedded quote doubles, a run
at the *end* of a quoted argument doubles (the closing quote is the quote it
precedes), and every other separator is left alone. That is
`ConvertTo-HDTNativeArgument`, and its tests assert it by running the built line
through a real process and reading the argv back, because the string alone proves
nothing.

**The rule this leaves behind:** moving a native call off PowerShell's `&`
operator means taking over its argument quoting, and the trap is invisible in
every path that happens to have no space in it.

## S21.1 — `dism /Set-TimeZone` writes the STANDARD HALF ONLY, and S21 said otherwise ✅

**Verified by execution**, by reading the registry out of two images and
comparing them side by side. This is the second half of the same defect: S21
above took the lab from **eleven hours out to one**, and that last hour was a
different bug hiding behind the first.

### What was believed, and is false

S21, the comment in `IBootImageService.SetTimeZone` and the header of
`New-HDTBootImageService` all stated that `/Set-TimeZone`

> writes Bias, StandardBias, DaylightBias, ActiveTimeBias, TimeZoneKeyName and
> the standard/daylight transition dates **as one consistent set**.

**It does not.** It writes the standard half of the zone and stops. That claim
survived a build, a deployment and a code review, and it is why the remaining
hour was blamed on WinPE rather than on the image. The natural next diagnosis —
*"WinPE does not perform DST transitions"* — is **also false**, and would have
led to a runtime correction nobody needed.

### The two tables, as measured

Same zone id (`Israel Standard Time`), same key
(`SYSTEM\CurrentControlSet\Control\TimeZoneInformation`), read 2026-08-29 during
Israeli daylight time:

| value | full Windows (build host) | HDT boot image, after dism |
|---|---|---|
| `Bias` | -120 | -120 ✅ |
| `StandardBias` | 0 | 0 ✅ |
| `TimeZoneKeyName` | `Israel Standard Time` | `Israel Standard Time` ✅ |
| `StandardName` | MUI string | MUI string ✅ |
| **`DaylightBias`** | **-60** | **0** ❌ |
| **`DaylightName`** | set | **empty** ❌ |
| **`StandardStart`** | recurring rule | **all zeros** ❌ |
| **`DaylightStart`** | recurring rule | **all zeros** ❌ |
| **`ActiveTimeBias`** | **-180** | **ABSENT** ❌ |
| **`DynamicDaylightTimeDisabled`** | **0** | **1** ❌ |

With no `ActiveTimeBias` the kernel falls back to `Bias + StandardBias`, which is
**-120 the year round**. A correct machine reads **-180** between the March and
October transitions.

**-120 + -60 = -180 — the exact hour every WinPE record was ahead of true UTC.**

It also explains S21's eleven hours with no extra theory: the ADK default is
Pacific and the reading was bias **480**, the *standard* value, in August. Two
measurements, two different zones, both the standard bias. Nothing was ever
evaluating a rule, because no rule was ever present.

### WinPE is not missing the data — only the copy of it

The ADK's stock `winpe.wim` carries the **complete** time zone database:
**141 zones** under `SOFTWARE\Microsoft\Windows NT\CurrentVersion\Time Zones`,
each with its 44-byte `TZI` and a `Dynamic DST` subkey. `Israel Standard Time`
there reads `Bias -120, StandardBias 0, DaylightBias -60`, March last-Friday
02:00 to October last-Sunday 02:00 — captured verbatim as
`tests/fixtures/winpe/timezone-israel-tzi.json`.

The daylight rule was sitting in the image the whole time. Nothing had ever
copied it into the key the kernel reads.

The stock `Control\TimeZoneInformation` is worth recording too: Pacific,
`DaylightBias 0`, both transition values all zeros, **no `ActiveTimeBias` value
at all**, `DynamicDaylightTimeDisabled 1`. dism changes the zone identity and
leaves every one of those in place.

### How to repeat it without building anything

No mount, no rebuild, nothing written — 7-Zip reads a WIM read-only, which is
what makes this safe to run while a deployment is live:

```powershell
& 'C:\Program Files\7-Zip\7z.exe' x -o"$env:TEMP\tz" `
    '<any>.wim' 'Windows/System32/config/SYSTEM' 'Windows/System32/config/SOFTWARE'

reg load HKLM\HDTPE "$env:TEMP\tz\Windows\System32\config\SYSTEM"
Get-ItemProperty 'HKLM:\HDTPE\ControlSet001\Control\TimeZoneInformation'

# THE UNLOAD FAILS WITHOUT THIS. PowerShell's registry provider holds a handle on
# every key it has read, and reg unload answers "Access is denied" - measured.
[gc]::Collect(); [gc]::WaitForPendingFinalizers()
reg unload HKLM\HDTPE
```

An offline hive has **no `CurrentControlSet`** — that link is made at boot — and a
WinPE `SYSTEM` hive has exactly one control set: `ControlSet001`, beside
`DriverDatabase`, `Keyboard Layout`, `RNG`, `Select`, `Setup`, `Software`, `WPA`
and nothing else. Resolving `Select\Current` would be a branch that can only ever
answer 1.

### The fix, and why a build-time write does not expire here

`ConvertTo-HDTTimeZoneDaylightValue` emits the missing half and
`IBootImageService.SetTimeZoneDaylight` writes it, in `Update-HDTBootImage` step
**9c — after dism, never before**, because dism rewrites the whole key from the
zone database and would erase a daylight half written first *while the build
stayed green*.

**Nothing it writes is a moment.** An image is built once and booted for months,
so computing "is it daylight time today" and baking the answer would be right in
August and an hour out from the last Sunday of October — worse than being
honestly wrong all year. Instead:

- the transition `SYSTEMTIME`s carry **`wYear = 0`**, Windows' encoding for the
  *recurring* rule "the Nth weekday of month M", evaluated against whatever day
  the machine boots on;
- the **open-ended** adjustment rule is used (`DateEnd` 9999-12-31), never "the
  rule covering today" — picking by today's date is a moment by the back door;
- **`ActiveTimeBias` is deliberately never written.** It is the only value in
  that key answering "is it daylight time *right now*". Left absent — exactly as
  dism leaves it — the kernel computes it at each boot, which is how a full
  Windows machine comes up correct the morning after a transition with no
  service running.

### STILL UNPROVEN, AND HERE IS THE CHECK

**That last bullet is reasoned, not measured.** A deployment was running on the
lab hardware, so the boot image could not be rebuilt, and *"the WinPE kernel
evaluates the recurring rule and computes `ActiveTimeBias` at boot"* has not been
observed. It is the same `ntoskrnl` as full Windows and no service is involved,
which is the whole basis for expecting it.

**The next boot image build settles it in one glance.** Two checks, and they
separate the two failure modes:

1. **Did the build write the rule?** At a WinPE prompt — `reg` *is* in
   `tests/fixtures/winpe/winpe-command-amd64.json`; `tzutil` and `w32tm` still
   are not:

   ```
   reg query HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation
   ```

   Expect `DaylightBias 0xffffffc4` (-60), `DynamicDaylightTimeDisabled 0x0`, and
   `StandardStart` / `DaylightStart` **not** all zeros. If these are wrong, step
   9c did not run — a build problem, not a kernel one.

2. **Did the kernel act on it?** Compare the first WinPE record's `ts` in
   `HDT.jsonl` against true UTC:

   - **equal → the rule is being evaluated.** Fixed.
   - **one hour ahead → it is not.** The kernel is still using
     `Bias + StandardBias`, and the honest answer becomes the `clockUnsynced`
     flag the engine already emits.

   In that case also read whether `ActiveTimeBias` is now *present* in check 1.
   If the kernel writes it back at boot it appears; if the key still has no
   `ActiveTimeBias`, nothing evaluated anything.

**THE CHECK IS ONLY MEANINGFUL DURING DAYLIGHT TIME.** Between the last Sunday of
October and the last Friday of March a correct machine and a broken one read
*identically* — both -120. Running this in January proves nothing and will look
like a pass.

### The downside is bounded — do not roll this back if the hour is still wrong

If the kernel turns out not to evaluate the rule, an image built this way behaves
**exactly as one built before it**: the fallback is `Bias + StandardBias`, which
is today's behaviour. Every value added is inert in that case rather than
harmful, and none can become wrong at a transition. There is no version of this
change that is right in August and broken in November — the specific failure it
was designed around. A reverted step 9c buys nothing and loses the fix if the
kernel *does* evaluate.

**The rule this leaves behind:** S21 said "a build-time write has nothing left to
go missing", and that is still true — but a build-time write can still write only
*half* of what it claims. What a tool documents itself as writing is not
evidence; read the key back out of the artefact. Both defects here were found by
reading the image, and neither was visible from a green build.

---

## S23 — MDT's "boot into WinPE once" is not a one-shot, and `/cleanup` is what undoes it ✅⚠

Date: 2026-08-31. **The first time this repository has ever run `bcdedit` against
a ramdisk boot entry.** Everything about the FullOS → WinPE transport up to here
was read out of MDT's VBScript; this is where it was checked against the tool.

**Run against a STANDALONE SCRATCH STORE**, `bcdedit /createstore` into the
scratchpad, every command aimed at it with `/store`. Nothing here touched this
laptop's own boot configuration, and the store file was deleted afterwards.

### S23.1 — the ten create commands are accepted exactly as composed ✅

`Get-HDTBcdCommand -Action Create` emits ten invocations. All ten returned
**exit 0**, and the entry enumerates as:

```
identifier              {7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}
device                  ramdisk=[C:]\HDT\Boot\boot.wim,{ae5534e0-a924-466c-b836-758539a3ee3a}
path                    \windows\system32\boot\winload.efi
description             HDT Windows PE
osdevice                ramdisk=[C:]\HDT\Boot\boot.wim,{ae5534e0-a924-466c-b836-758539a3ee3a}
systemroot              \windows
detecthal               Yes
winpe                   Yes
```

Three things that were guesses before and are facts now:

- **`{ramdiskoptions}` is an alias for `{ae5534e0-a924-466c-b836-758539a3ee3a}`**
  and bcdedit resolves it inside the `device` string. The comma-separated
  `ramdisk=[<drive>]<path>,{ramdiskoptions}` syntax MDT uses is accepted verbatim.
- **The description must be a BARE token, not a quoted one.** These arguments are
  splatted at `bcdedit.exe` as an array and Windows PowerShell quotes what needs
  quoting; the enum shows `description  HDT Windows PE` with no stray quotation
  marks. Writing `'"{0}"' -f $Description` into the token — which is what MDT's
  string-concatenated command line needs — would have named the entry with the
  quotes in it.
- **`bcdedit` never validates the paths.** `\HDT\Boot\boot.wim` does not exist on
  this laptop and every command still returned 0. That is the silent failure the
  step's own guard exists for: arming a boot into a file that is not there is
  accepted here and arrives as an `0xc000000f` on a machine that has already been
  generalized.

### S23.2 — `/bootsequence` needs a `{bootmgr}` in the store ⚠

Against a bare `/createstore` store the arm **failed**:

```
/bootsequence {7f1b6e18-...}
    exit=1
    An error has occurred setting the element data.
    The system cannot find the file specified.
```

`bootsequence` is an **element on `{bootmgr}`**, and `/createstore` produces a
store with no boot manager object in it. Adding one and asking again returned
**exit 0**, with the element where it belongs:

```
Windows Boot Manager
identifier              {9dea862c-5cdd-4e70-acc1-f32b344d4795}
bootsequence            {7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}
```

**Why it matters to the code rather than to the probe.** Every store HDT arms
against has a `{bootmgr}` — the full OS uses the system store it booted through,
and the WinPE teardown names the ESP store `bcdboot` wrote. But the error text is
the least helpful sentence bcdedit produces, and anybody who meets it while
pointing at the wrong store will read "The system cannot find the file specified"
as a missing `boot.wim`. It is a missing `{bootmgr}`.

### S23.3 — MDT's four commands are all PERMANENT, measured ✅

`AdjustBCDDefaults` was run in full against the same store, one command at a
time. After all four, `{bootmgr}` reads:

```
default                 {7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}
displayorder            {7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}
bootsequence            {7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}
timeout                 0
```

**So "MDT's is not a one-shot" is no longer an inference from reading the
VBScript.** `/bootsequence` alone is consumed by the boot it causes; `/default`
and `/displayorder` are not, and a machine that never reaches `LTICleanup.wsf`
has WinPE as its default OS for ever. HDT runs `/bootsequence` and nothing else,
which leaves `{default}` naming Windows — so the same abandoned machine degrades
to "boots Windows" instead.

**And `timeout 0` survives the teardown.** After `/delete <id> /cleanup` the boot
manager still reads `timeout 0`: MDT permanently sets the machine's boot menu
timeout to zero as a side effect of a capture and never puts it back. One more
reason the arm is one command.

### S23.4 — `/cleanup` is what makes the teardown complete ✅

`/delete {7f1b6e18-...} /cleanup` returned 0, and the boot manager afterwards:

```
Windows Boot Manager
identifier              {9dea862c-5cdd-4e70-acc1-f32b344d4795}
description             Windows Boot Manager
timeout                 0
```

**All three references went with the entry** — `default`, `displayorder` and
`bootsequence` — in one command. That is what `/cleanup` does and it is the one
part of MDT's BCD handling that is unambiguously right
(`LTICleanup.wsf:119-121`). Without it the store keeps a `displayorder` naming an
object that no longer exists.

It also means a stale `bootsequence` from a previous reference build is cleared
by the same call the step already makes before it creates the entry.

### S23.5 — sysprep is INDIFFERENT to an armed `/bootsequence`, both orderings measured ✅

**MEASURED on 2026-08-31** on `HDT-M7-RefApp`, twice, by running a real
`sysprep /generalize` with `/bootsequence` armed and reading the machine's own
engine log off its disk afterwards. This sub-section used to say NOT MEASURED and
everything in it was inference.

**THE ANSWER IS THAT SYSPREP DOES NOT CARE.** Both orderings were run:

| ordering | run | what sysprep did |
|---|---|---|
| arm **before** `Sysprep` (HDT's) | `run-20260831-093444` | exit 0, `ImageState` = `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE` |
| arm **after** `Sysprep` (MDT's) | `run-20260831-094740` | exit 0, same, and the arm then succeeded on the generalized machine |

The second run's log, read off the disk:

```
sysprep generalized this machine in 36199 ms; ImageState is IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE.
step 12 'Sysprep' completed
step 13 'Boot into WinPE after sysprep' (BootToWinPE) starting, attempt 1 of 1
creating the UEFI boot entry {7f1b6e18-...} for C:\HDT\Boot\boot.wim
The next boot will be the WinPE staged at C:\HDT\Boot\boot.wim. The firmware boot order is unchanged.
step 13 'Boot into WinPE after sysprep' completed
step 14 'Restart into WinPE' completed
```

**Nothing complained, in either order.** MDT's comment at `LTIApply.wsf:347-350`
about deferring the BCD work "so that Sysprep doesn't complain" does not
reproduce on Windows 11 LTSC 2024 under Hyper-V. `reference.yaml` therefore keeps
arming **before** the seal, which is the ordering with the better fail-safe: a
machine that cannot be brought back is never generalized.

**AN EARLIER READING OF THIS EVIDENCE WAS WRONG AND IS RECORDED HERE SO IT IS
NOT REPEATED.** After the first run, the offline store showed `{bootmgr}` still
carrying `bootsequence {7f1b6e18-...}` while the object itself enumerated as
"There are no matching objects", and that was written up as "sysprep deletes the
OSLOADER object". The second run disproves it: the object is **equally absent
after an arm that ran *after* generalize**, when there was no generalize left to
delete anything. Whatever removes it is not sysprep. See S23.7.

**A SEPARATE, REAL FINDING FROM THE SAME RUNS:** once a machine has been
generalized it can no longer reach the deployment share — `"The network location
cannot be reached"` — so the engine's status mirror to
`Logs\_active\<run>.json` fails for every step after `Sysprep`. The run
continues correctly against `C:\HDT\Logs\status.json`, and the failure is
logged rather than fatal, which is right. **But a console watching the share
sees the run frozen at `Sysprep` for the rest of its life**, and anyone
diagnosing from the share alone will conclude the machine hung in sysprep when it
did not. The local log is the source of truth after the seal.

### S23.6 — the first real attempt never reached sysprep: `bcdedit` was called through a corrupted path ✅

**MEASURED on 2026-08-31, run `run-20260831-091544`, on `HDT-M7-RefApp`.** The
first time anything ran `BootToWinPE action: arm` on a machine, it failed — and
**not for any reason S23.5 is about**.

```
step 12 'Boot into WinPE after sysprep' failed: could not create the boot entry
that reaches the staged WinPE: ... "The term 'C:\Windows\System32cdedit.exe'
is not recognized as the name of a cmdlet, function, script file, or operable
program."
```

`New-HDTImageService.ps1`'s `RunBcdEdit` invoked

```powershell
& "$env:SystemRoot\System32<0x08>cdedit.exe" @argument
```

where `<0x08>` is a **literal backspace byte** standing where `\b` was meant to
be — written into the file by an edit that let something interpret `\b` as an
escape before the bytes landed. So **every** `bcdedit` call the transport made
died: the create, the arm, and the teardown. The sibling call twelve lines above
it, written as a normal string, was correct, which is why nothing else noticed.

**WHY NOTHING CAUGHT IT, AND THIS IS THE PART WORTH KEEPING.** Adapters over
external tools are branch-free and deliberately not unit tested (CLAUDE.md rule
1) — there is nothing in them to test but the call itself. 12822 passing tests
therefore said nothing whatever about whether that call names a program that
exists. It could only surface on a real machine, and it did: at step 12 of 16,
in the full OS, after Windows had been deployed and Acrobat installed.

**IT IS INVISIBLE THREE WAYS.** It renders as
`$env:SystemRoot\System32\bcdedit.exe` in an editor, because a terminal drawing a
backspace erases the character before it. `grep System32.bcdedit` does not match
it. `grep System32cdedit` does not match it either, because the byte is still
between them. Only a byte-level scan finds it.

**AND IT WAS NOT ALONE — SIX MORE, EVERY ONE A `\b` OR A `\3` IN A PATH.** A
repository-wide byte scan found `scratch\bootimage`,
`Share\bootstrap-rules.yaml`, two PCI device ids, and — worst —
`New-HDTFakeImageService.Tests.ps1` asserting `\HDT\Boot<0x08>oot.wim`,
`\HDT\Boot<0x08>oot.sdi` and `\windows\system32<0x08>oot\winload.efi` in three
places. **Those are the exact ramdisk paths the BootToWinPE mechanism is built
on**, so the fake agreed with itself about a corrupted string while the real path
was wrong — CLAUDE.md's "the fake was wrong, not the caller" happening in the
one place it could do most damage.

`tests/contract/NoControlCharacter.Contract.Tests.ps1` now refuses any byte below
0x20 other than tab, CR and LF, and 0x7F, across every authored text file. It
found the seventh occurrence on its first run.

**THE FAIL-SAFE ORDERING PAID FOR ITSELF ON ITS FIRST OUTING.** Both
`BootToWinPE` steps run *before* `Sysprep` and both fail the sequence rather than
warning, precisely so that a machine which cannot reach WinPE has not yet been
sealed. That is exactly what happened: the arm failed, the run stopped, and the
machine was left un-generalized with Windows and Acrobat on it — recoverable,
rearm count untouched, nothing stranded. Had the arm sat after sysprep as MDT
orders it, this defect would have surfaced on a generalized machine with no leg
left to fix it.

### S23.7 — the armed boot is taken and then DECLINED: the machine falls back to Windows ⚠ SUPERSEDED BY S23.8

> **⚠ THE TITLE OF THIS SECTION IS WRONG AND THE READING BELOW IS WRONG.**
> S23.8 ran the probe this section asks for, on a machine, and measured the
> opposite: the entry **does** persist to the system store, the one-shot **is**
> taken, and a machine boots the staged WinPE — including after
> `sysprep /generalize`. Reading (a) is dead. So is "the boot manager declines
> it". What is left of this section is the observation that three reference
> builds ended in OOBE with a `bootsequence` element pointing at an object that
> was gone, and that remains unexplained — but it is not the transport, and
> nothing here should be used to reason about the transport. **Read S23.8.**

**THIS IS THE REMAINING BLOCKER FOR THE REFERENCE LOOP**, measured on
2026-08-31 across three runs on `HDT-M7-RefApp` - `run-20260831-093444`,
`run-20260831-094740` and `run-20260831-100741` - and it is **not** sysprep
(S23.5), **not** the corrupted `bcdedit` path (S23.6, fixed) and **not** Secure
Boot (ruled out below).

**WHAT HAPPENS.** Everything up to the reboot is clean and the machine's own log
says so: the WinPE is staged to `C:\HDT\Boot\boot.wim`, the ramdisk entry is
created, `/bootsequence` is set, `bcdedit` exits 0 for all ten commands, and the
restart is issued. The machine then boots **Windows** and runs OOBE.

**WHAT THE STORE LOOKS LIKE AFTERWARDS**, read offline with the VHDX mounted
read-only, on a 17-object store:

```
{bootmgr}
  displayorder            {default}
  bootsequence            {7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}   <-- present
bcdedit /enum {7f1b6e18-...}
  There are no matching objects or the store is empty.             <-- absent
bcdedit /enum all | findstr 7f1b6e18
  bootsequence            {7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}   <-- the ONLY hit
```

There is no `{ramdiskoptions}` object either. So the `/set {bootmgr}
bootsequence` persisted and **the `/create` of the OSLOADER did not** — even in
the run where the arm happened *after* generalize, with nothing left that could
have stripped it.

**SECURE BOOT WAS THE LEADING HYPOTHESIS AND IT IS NOW RULED OUT**, which was
worth one run to establish. S20 records that the ADK's WinPE bootloader is below
the Secure Boot SVN floor, and the VM is Generation 2 with `SecureBoot: On`,
template `MicrosoftWindows` - so a boot manager refusing the staged
`winload.efi` and falling back to `{default}` would have explained everything.

**`run-20260831-100741` was run with `Set-VMFirmware -EnableSecureBoot Off` and
behaved IDENTICALLY**: Acrobat installed, WinPE staged, entry armed, sysprep
generalized, and the machine came back in Windows OOBE. The store afterwards is
the same pair - `bootsequence` present on `{bootmgr}`, the object it names
absent. **Secure Boot is not the blocker.**

**SO THE FAULT IS IN THE ENTRY, NOT IN THE TRUST DECISION.** Two readings remain
and they have different fixes:

  a. the `/create` never persists to the system store, even though `bcdedit`
     exits 0 for it, while the `/set {bootmgr} bootsequence` in the same
     transport does; or
  b. it persists, the boot manager cannot use it and falls back, and Windows
     Setup's own BCD maintenance during OOBE tidies away the orphaned custom
     objects afterwards - leaving the `bootsequence` element behind.

Every run so far ends in OOBE, so every offline read happens *after* a Windows
Setup pass, and the two are indistinguishable from the evidence gathered.

**THE PROBE THAT SEPARATES THEM, and it needs no reference build at all:** on a
deployed machine, run `BootToWinPE action: stage` then `action: arm`, and
**enumerate the store immediately, before any reboot**. If the object is there,
it is (b) and the question becomes why the boot manager declines it. If it is
not, it is (a) and the suspect is `/create <explicit-guid> -application OSLOADER`
against the system store - compare with MDT's `/create /d "..." /application
OSLOADER`, which lets bcdedit mint the GUID and then reads it back.

Worth noting against (a): **S23.1 ran these exact ten commands against a
standalone scratch store and the entry enumerated correctly afterwards.** So the
command shape is good and the difference is the store, the machine, or the
Windows Setup pass that follows.

**WHAT IS PROVEN AND SHOULD NOT BE RE-DERIVED**: staging works, the ten bcdedit
commands all return 0 (S23.1), sysprep is indifferent to the arm (S23.5), the
`InstallApplications` step installs a real vendor MSI inside the reference build
in ~95 s, and `Sysprep` genuinely generalizes. The loop fails at exactly one
place: the boot that the one-shot was supposed to redirect.

### S23.8 — the transport WORKS: (a) is dead, and the real defect is that HDT takes WinRE's ramdisk options ✅

Date: 2026-08-31. **Every line of this section was executed, not reasoned.** The
probe S23.7 asked for — stage, arm, then enumerate *before any reboot* — was run
on a throwaway Windows 11 LTSC VM (`HDT-S23-BCD`, Generation 2, `HDT External`,
built by applying the staged media to a VHDX; no deployment, no share, no HDT
engine on it) and then followed through a real reboot. The VM was deleted
afterwards.

**S23.7 offered two readings and they are no longer indistinguishable.**

#### S23.8.1 — `/create` persists to the SYSTEM store, immediately ✅

The exact ten commands `Get-HDTBcdCommand -Action Create` emits, run with **no
`/store`** on a running machine, all returned 0, and `bcdedit /enum <id>` in the
same session, before any reboot, printed the entry in full:

```
identifier              {7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}
device                  ramdisk=[C:]\HDT\Boot\boot.wim,{ramdiskoptions}
winpe                   Yes
```

**Reading (a) — "the create never persists to the system store" — is FALSE.**

#### S23.8.2 — the running system store IS the ESP file, measured ✅

Asked of both in the same session, `bcdedit` with no `/store` and
`bcdedit /store S:\EFI\Microsoft\Boot\BCD` reported **18 objects each**, both
carried the newly created entry, and both showed the `bootsequence` element on
`{bootmgr}`. There is no second store, and the "which store is written versus
which is read" hypothesis is closed. (The two renderings differ cosmetically:
the system store prints `default {current}` where the file store prints
`{default}`. Same object.)

#### S23.8.3 — the armed one-shot IS taken ✅

With a real `HDTPE_x64.wim` staged at `C:\HDT\Boot\boot.wim`, the machine
rebooted **into the staged WinPE** — HDT's own boot image, its wizard, its
bootstrap, which then started a deployment and failed pre-flight on the 40 GB
disk (`run-20260831-073229`). Afterwards, back in Windows:

```
{bootmgr}   bootsequence   -- GONE, consumed by the boot it caused
{7f1b6e18-...}             -- still there
```

**That is the exact INVERSE of S23.7's signature** (bootsequence present, object
absent), which is the clearest evidence that whatever happened in those three
reference builds is not this mechanism.

#### S23.8.4 — sysprep does not touch the entry, read BEFORE the reboot ✅

`sysprep /generalize /oobe /quit` was run with the entry armed, the VM was then
powered off **without rebooting**, and the ESP store was read offline — so no
Windows Setup pass ever ran between the seal and the read. Everything survived:

```
objects: 18 -> 16          (WinRE's own entries, via generalize's reagentc teardown)
{bootmgr} bootsequence     -- present
{7f1b6e18-...}             -- present
{ramdiskoptions}           -- present
```

S23.5's conclusion ("whatever removes it is not sysprep") is now confirmed by a
direct pre-reboot measurement rather than inferred from two runs.

#### S23.8.5 — a GENERALIZED machine still boots the armed WinPE ✅

The same VM, generalized and armed, was booted: it reached the staged WinPE
again (`run-20260831-075301`). **So the transport is not defeated by the seal.**

#### S23.8.6 — THE REAL DEFECT: HDT was taking WinRE's `{ramdiskoptions}` ⚠ FIXED

`reagentc /info` on the probe machine, with HDT's entry in place:

```
Windows RE status:         Enabled
Windows RE location:       \\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE

bcdedit /enum {ramdiskoptions}
  ramdisksdidevice        partition=C:
  ramdisksdipath          \HDT\Boot\boot.sdi        <-- HDT's staged file
```

`{ramdiskoptions}` is a **well-known, shared** object. HDT tolerated the failing
`/create` on a machine that already had one — and then set both of its elements
anyway, repointing that machine's WinRE at HDT's staged `boot.sdi`. **And the
`remove` action deletes that file by name**, so a machine HDT was asked only to
build a reference image on is left with a WinRE aimed at a file that is no longer
on the disk.

`Get-HDTBcdCommand`'s own header refuses to *delete* `{ramdiskoptions}` for
precisely this reason, and the code then overwrote it — the same harm reached
more quietly.

**MDT DOES NOT DO THIS.** `ZTIBCDUtility.vbs` `CreateRamDiskEntryEx` (:86-89):

```vbs
If BCDObjectExists("{ramdiskoptions}") then
    oLogging.CreateEntry "{ramdiskoptions} already present.", LogTypeInfo
    exit Function
End if
```

MDT writes to the object only when it is absent, and an entry on a machine that
already has one simply uses the one that is there. That is safe because
`boot.sdi` is a generic ramdisk descriptor rather than a per-image file.

**Fixed** by `IImageService.TestRamdiskOptions(store)` plus
`Get-HDTBcdCommand -RamdiskOptionsPresent`: the step asks first, and the three
`{ramdiskoptions}` commands are skipped entirely when the machine already owns
one. A probe that cannot read the store answers "no", which is the behaviour HDT
already had — failing an arm over a question about somebody else's WinRE would
strand a reference build.

#### S23.8.7 — `bcdedit /enum` on a missing object exits **0** ✅

```
bcdedit /store <store> /enum {ramdiskoptions}
  There are no matching objects or the store is empty.
  exit=0
```

So the existence probe **must read the output**, not the exit code. MDT's
`BCDObjectExists` parses output for the same reason, and so does
`TestRamdiskOptions`. This extends S23.1's "bcdedit validates no paths" to
reads: a 0 from `bcdedit` means almost nothing on its own.

#### S23.8.8 — `bcdedit /delete {ramdiskoptions} /cleanup` REFUSES ✅

Measured against a real store: the command runs, and the object is still there
afterwards. bcdedit protects the well-known object. So "delete it and recreate
it" was never available as a way out of S23.8.6, even setting WinRE aside.

#### S23.8.9 — arming a store OFFLINE does not work, and it wasted a probe ⚠

A private device-options object (`bcdedit /create <guid> ... -device`) was tried
as an alternative to sharing `{ramdiskoptions}`. It composes and enumerates
correctly against a file store. **Booted, it failed** — and so did the CONTROL,
the identical arm written to the same store, offline, with the well-known
`{ramdiskoptions}`. Both offline arms failed; both online arms (S23.8.3,
S23.8.5) succeeded.

**So the variable was the offline edit, not the identifier, and the private-GUID
result is VOID — it proves nothing either way.** It is recorded because the
control is the only reason that is known: without it, this would have been
written up as "bootmgr requires the well-known object", which is not measured.
**Do not arm a BCD store on a mounted VHDX and expect the machine to boot it.**
Arm from the running machine, which is what the step does.

#### What S23.8 leaves open — ANSWERED BY S23.10, AND THE ANSWER IS NO

> **⚠ THE HYPOTHESIS BELOW WAS MEASURED AND IS WRONG.** S23.10 ran a real
> reference build with S23.8.6's fix in place. A deployed machine's WinRE is
> registered under **private GUIDs**, not the well-known `{ramdiskoptions}`; the
> arm logged `ramdiskOptionsPresent: false`, so HDT created that object itself;
> and it is **absent from the ESP store afterwards** on a machine where
> `generalize` never ran at all. `reagentc` was never an owner and generalize
> was never the remover. **Read S23.10.**


Three reference builds ended in Windows OOBE with `bootsequence` present on
`{bootmgr}` and the object it named absent. Nothing measured here reproduces
that, and the pieces S23.7 blamed are all cleared: the store, the create, the
seal, the boot manager. The one difference this probe could not carry is that a
real reference machine has a **WinRE registered by HDT's own `SetRecoveryImage`
step before the arm**, so its `{ramdiskoptions}` belongs to `reagentc` — and
`sysprep /generalize` disables WinRE, which is what removed two objects in
S23.8.4. That is the next thing to measure, and S23.8.6's fix is a prerequisite
for measuring it cleanly, because until now HDT was writing to that object
itself.

### S23.9 — sysprep can fail in 34 seconds on Appx and still exit 0, and the run never reaches the reboot ⚠

Date: 2026-08-31, `run-20260831-171421` on `HDT-M7-RefApp`. Read offline from the
machine's own `C:\HDT\Logs\HDT.log` and `Windows\System32\Sysprep\Panther\`.

**EVERYTHING UP TO THE SEAL WORKED, AND IT IS WORTH SAYING SO.** Acrobat Reader
installed in the full OS, `\ReferenceBuild\marker.txt` was stamped, and the
WinPE was staged - `C:\HDT\Boot\boot.wim` and `boot.sdi` were both on the disk
afterwards. Eleven steps completed.

**SYSPREP THEN FAILED 34 SECONDS IN, AND EXITED 0 DOING IT:**

```
SYSPRP Failed while deleting per user keys under
       'Software\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore': 0x800703fa
SYSPRP ActionPlatform::LaunchModule: Failure occurred while executing
       'SysprepGeneralize' from C:\Windows\System32\AppxSysprep.dll; dwRet = 0x3fa
SYSPRP RunDlls:An error occurred while running registry sysprep DLLs, halting sysprep execution
```

`0x800703fa` is `ERROR_KEY_DELETED`. **THE Sysprep STEP CAUGHT IT**, which is the
check earning its place:

```
sysprep returned 0 but this machine reports ImageState 'IMAGE_STATE_UNDEPLOYABLE',
not IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE, so it was not generalized.
```

The run ended `Failed at step 13 of 16` at 17:20:50 — **eleven completed, one
failed, one skipped** — a minute after it started sysprep. So this run says
NOTHING about the capture boot: there was no restart 2 to observe, and any
reading of it as "came back in OOBE" or "came back in WinPE" would be inventing a
measurement that did not happen.

**THREE THINGS THIS COST AN HOUR TO LEARN, AND THEY ARE OPERATIONAL:**

1. **THE MACHINE WAS LEFT RUNNING.** The run ended Failed at 17:20:50 and the VM
   was still `Running`, idle at under 1% guest CPU, an hour later. Anything
   waiting for `Off` as its "the sequence ended" signal — which
   `tests/e2e/ApplicationRoundTrip.E2E.Tests.ps1` does — reads a fast FullOS
   failure as a **75 minute timeout**.

2. **THE SHARE LOG STOPS AT THE FAILURE AND LOOKS LIKE A HANG.** Sysprep tears
   the network down as it goes, so the last three records — the failure, the
   status write and the log copy — could not be mirrored:
   `The network location cannot be reached`. From the share the run appears to
   stop mid-sysprep and stay there. **`Get-SmbSession` on the host showing no
   session from the guest is the cheap discriminator**, and the machine's own
   `C:\HDT\Logs\HDT.log` has what the share never received.

3. **Appx generalize failures are not deterministic.** The three runs of S23.7
   generalized the same image successfully hours earlier. Nothing in HDT changed
   between them and this one that touches Appx.

### S23.10 — `bcdedit` exits 0 for a `/create` whose object is NOT in the store, and HDT never read it back ⚠ FIXED, CAUSE FOUND IN S23.11

Date: 2026-08-31, same run as S23.9, read offline from the VHDX with the VM off:
the ESP store `S:\EFI\Microsoft\Boot\BCD`, 17 objects.

**THE S23.7 SIGNATURE REPRODUCED, ON A MACHINE THAT NEVER GENERALIZED AND NEVER
RAN OOBE.**

```
{bootmgr}  bootsequence  {7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}   <-- present
bcdedit /store <esp> /enum {7f1b6e18-...}   There are no matching objects       <-- absent
bcdedit /store <esp> /enum {ramdiskoptions} There are no matching objects       <-- absent
bcdedit /store <esp> /enum all | findstr 7f1b6e18   -> the bootsequence line, and nothing else
```

**THAT KILLS S23.7'S READING (b).** (b) was "the object persists, the boot manager
declines it, and Windows Setup's own BCD maintenance during OOBE tidies away the
orphan afterwards". There was no OOBE pass on this machine and no successful
generalize — sysprep died 34 seconds in (S23.9) and the machine sat idle until it
was powered off. Nothing ran that could have tidied anything. **The object was
never in the ESP store.**

**AND IT IS NOT THE `{ramdiskoptions}` GUARD.** The arm step logged
`"ramdiskOptionsPresent": false`, so S23.8.6's guard skipped nothing and HDT
created the object itself — and it is absent too. **Both `/create`s failed to
persist while the `/set {bootmgr} bootsequence` from the same transport
persisted.** The guard is right and stays, but it was not the cause of the OOBE
runs, and S23.8's closing hypothesis — that a `reagentc`-owned
`{ramdiskoptions}` torn down by generalize was taking HDT's entry with it — does
not survive this either: this machine's WinRE is registered under **private
GUIDs** (`{7fc36b73-...}` "Windows Recovery Environment", `{7fc36b74-...}`
"Windows Recovery"), not the well-known object, and generalize never ran.

> **⚠ THE PARAGRAPH BELOW WAS MEASURED AND IS WRONG.** The machine was never
> the variable. S23.11 ran the same ten commands by hand on a clone of THIS
> machine and every one of them persisted; the difference is that HDT handed the
> adapter its ten commands as ONE element, so a single malformed `bcdedit` ran
> and its exit code was never read. **Read S23.11.**

**SO S23.8.1 AND THIS DISAGREE, AND THE DIFFERENCE IS THE MACHINE.** S23.8.1
measured a `/create` persisting immediately, on a throwaway VM built by applying
media to a VHDX by hand. This is an **HDT deployment** — partitioned by
`DiskPartition`, imaged by `ApplyImage`, booted through `ConfigureBoot`'s
`bcdboot` — and the arm runs in the resumed full-OS leg. Something about that
machine or that process context is the variable, and it is the next thing to
measure. **It is not the store file, not the seal, not the boot manager and not
Secure Boot**, all of which are already ruled out.

#### S23.10.1 — the defect that made this expensive: nothing read the entry back ⚠ FIXED

`Invoke-HDTBootToWinPEStep`'s arm branch called `AddRamdiskBootEntry`, then
`SetBootSequenceOnce`, and **reported success** — resting the one guarantee the
whole reference template is built on ("nothing is sealed until we know it can
come back") on a `bcdedit` exit code. S23.1 records that `bcdedit` validates no
paths; S23.8.7 records that it exits 0 reading an object that is not there. It
also, now, exits 0 **creating** one that does not end up there.

**Four reference builds were generalized on that unverified success**, and every
one of them was stranded — which is the entire cost of this defect, because the
step runs while the machine is still a Windows somebody can log into.

**Fixed** by `IImageService.TestBootEntry(store, id)`: after the create and
**before the arm**, the entry is asked for by identifier, and the step fails when
the store does not have it. A store that cannot be READ fails the step too —
the opposite of `TestRamdiskOptions`, deliberately, and the reasoning is in the
code: that probe answers "no" when it cannot read, because failing an arm over a
question about somebody else's WinRE would strand a build for nothing, while
this probe IS the fail-safe and an unconfirmed guarantee before the seal is worth
a rerun.

**This does not fix the create.** It converts a reference build that seals a
machine it cannot bring back into one that stops, unsealed, with a message naming
the store — and it is what will make the next run of S23.10 report the fault in
one minute instead of ninety.

### S23.11 — the create was never ten commands: `@()` around a comma-protected return handed the adapter ONE ✅ FIXED

Date: 2026-08-31. **Every line of this section was executed on a copy of the
machine that failed**, `HDT-M7-RefApp`'s VHDX cloned into a throwaway VM
(`HDT-S23-BCD2`, Generation 2, `HDT External` with the adapter **disconnected**
so it could not reach the share, deleted afterwards). S23.10 named the machine as
the variable and asked which store bare `bcdedit` writes there. **It is the same
store, and the machine was never the variable.**

#### S23.11.1 — three hypotheses died in the first ten minutes ✅

Read offline from the mounted clone, before booting anything:

| Asked | Measured | Verdict |
|---|---|---|
| Is the ESP full? | 256 MB FAT32, **222.5 MB free** | no |
| Are there two stores? | one, `S:\EFI\Microsoft\Boot\BCD`; `\EFI\Microsoft\Recovery\BCD` is WinRE's and holds no HDT object | no |
| Did the store refuse the write? | see S23.11.2 — `bcdedit` run by hand there is flawless | no |

The disk `DiskPartition` built is **two partitions**, ESP + Windows: no MSR, no
recovery partition, WinRE registered from `\Recovery\WindowsRE` on the OS volume
under the private GUIDs S23.10 named.

**One instrument note, because it wasted a step.** The registry hive header's
FILETIME at offset 12 does **not** move when `bcdedit` writes — calibrated
against a copy of that store, where a `/create` left the timestamp at
`17:16:03.47` while the file grew 28672 -> 32768 bytes. The **sequence numbers**
at offsets 4 and 8 are the instrument that works; they move on every invocation,
a read included.

#### S23.11.2 — every one of the ten commands persists on that machine, by hand ✅

The exact ten `Get-HDTBcdCommand -Action Create` emits, run one at a time in the
full OS as the autologon Administrator, with the ESP store's length, hive
sequence number and SHA-256 taken around each, and the entry read back through
**both** the system store and the ESP file after every command:

```
BASELINE                          len=28672 seq=34/34   17 objects both ways
create OSLOADER      exit 0       -> present in system store AND file store
set device/osdevice  exit 0       -> both stores show it
...
ARM /bootsequence    exit 0
FINAL                             len=32768             19 objects both ways
```

**So S23.8.1 and S23.10 never disagreed about the machine.** The hand-run
transport works identically on a hand-built VM and on an HDT-deployed one.

#### S23.11.3 — THE DEFECT: `$this.RunBcdEdit(@(Get-HDTBcdCommand ...))` passes ONE element ⚠ FIXED

The real adapter, run on that same machine against the same store, reproduced the
failure in 164 ms:

```
AddRamdiskBootEntry: returned, no exception  [164 ms]
after : id present (system store) = False
```

Instrumenting the loop shows what it received:

```
RunBcdEdit got: type=System.Object[] Count=1
entry[1] type=System.Management.Automation.PSObject[] argCount=42
  args= </create> <{ramdiskoptions}> <-d> <Ramdisk Device Options>
        </set> <{ramdiskoptions}> <ramdisksdidevice> <partition=C:> ...
        </create> <{7f1b6e18-...}> <-d> <HDT Windows PE> <-application> <OSLOADER>
        ... </set> <{7f1b6e18-...}> <winpe> <yes>
entry[1] Tolerate type=System.Object[] truthy=True
```

`Get-HDTBcdCommand` returned `, ([pscustomobject[]] @($command))`. **The unary
comma protects the array from the pipeline unroll, and the caller is a METHOD
ARGUMENT, which is an expression rather than a pipeline** — so the `@()` there
*wrapped* the array instead of collecting it. Two consequences, and it takes both
to make the failure silent:

1. `$entry.Argument` **member-enumerated** across all ten commands and flattened
   into **42 tokens fired at a single `bcdedit`** (62 with a `/store` prefix).
   bcdedit parsed the front of that and created nothing.
2. `$entry.Tolerate` became a **ten-element array**, and a non-empty array is
   **truthy**, so `RunBcdEdit`'s one branch — `if ($entry.Tolerate) { continue }`
   — fired and **`AssertExitCode` was never called at all**.

**AND THAT IS THE WHOLE ASYMMETRY S23.10 COULD NOT EXPLAIN.** `Arm` is a
**one**-command list, so the same wrapping flattens to `/bootsequence <id>` — a
correct command line by accident — and its `Tolerate` unrolls to a real `$false`,
so its exit code *was* checked. One command that worked, ten that never ran.
`Remove` is one command too, which is why `/delete`'s exit 1 was reported
correctly in every log.

**The 94 ms was the tell, and it was in the log the whole time.** Step 12 of
`run-20260831-171421` logged the create at 17:20:14.237 and success at
17:20:14.331 — 94 ms for what should have been eleven `bcdedit` launches, on a
machine where the preceding `/delete` alone took 853 ms. It was one process, not
eleven.

#### S23.11.4 — the fix is in the COMPOSER, and the test is on the shape the adapter consumes ✅

`Get-HDTBcdCommand` drops the unary comma from all three returns. Every caller
already wraps in `@()`, and `@(<one object>)` is a one-element array, so the
collapse the comma guarded against is harmless — while the comma itself was the
thing that made ten commands arrive as one.

**Not the adapter, deliberately.** `New-HDTImageService` is untested by design
(CLAUDE.md rule 1) and its line is ordinary PowerShell; the composer was the one
telling a lie about its own shape, and it is the file a unit test can hold.

**AND THE TEST HAD TO CHANGE SHAPE TOO, WHICH IS THE REAL LESSON.** Thirty-three
assertions covered this function character by character and every one of them
passed while it was broken, because they all reach it through a helper that
**assigns** the result — and assignment collects correctly. The new
`Context 'the shape the adapter consumes'` computes the count **inside** the
module scope in the adapter's own expression form, and asserts it for
**Create, Arm and Remove**, plus that `Tolerate` is a scalar `[bool]` on every
element and that no command line exceeds eight tokens. It fails 3 of 3 before the
fix (`Expected 10, but got 1`; `Expected 8, but got 62`) and passes after.

#### S23.11.5 — verified on the machine, offline, after a power-off ✅

The fixed module imported on the clone, `AddRamdiskBootEntry` + `TestBootEntry` +
`SetBootSequenceOnce` run as the step runs them, the VM powered off, and the ESP
store read from the host:

```
ramdiskOptionsPresent=True TestBootEntry=True armed

identifier   {7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}
device       ramdisk=[D:]\HDT\Boot\boot.wim,{ae5534e0-a924-466c-b836-758539a3ee3a}
path         \windows\system32\boot\winload.efi
description  HDT Windows PE
osdevice     ramdisk=[D:]\HDT\Boot\boot.wim,{ae5534e0-a924-466c-b836-758539a3ee3a}
systemroot   \windows
detecthal    Yes
winpe        Yes

{bootmgr} bootsequence {7f1b6e18-3e9a-4a1e-9a1d-2f6c4b8d5e30}
```

The `[D:]` is the host's letter for that volume while the VHDX is mounted, not
the guest's; `{ramdiskoptions}` renders as its well-known GUID because S23.8's
guard was active — the machine already had one by then, from the earlier probe —
which is the guard doing its job.

#### S23.11.6 — the sweep: which other callers were affected ✅

`RunBcdEdit` has exactly three callers, and `bcdedit` is reached from two other
methods that do not use it at all:

| Method | Commands | Was it broken? |
|---|---|---|
| `AddRamdiskBootEntry` | 7 or 10 | **yes** — the whole defect |
| `SetBootSequenceOnce` | 1 | no, by the accident of being one |
| `RemoveBootEntry` | 1 | no, same accident |
| `InstallBootFile` | `bcdboot`, direct `&` | not affected |
| `SetBootOrderFirst` | one `bcdedit`, direct `&` | not affected |

So the store resolution was never wrong anywhere — `Get-HDTBcdStoreArgument` is
correct and S23.8.2 stands. **Only a multi-command list was affected, and
`AddRamdiskBootEntry` is the only one there is.**

#### What this closes, and what stays

`TestBootEntry` **stays**, and S23.10.1's reasoning is unchanged: it is the guard
that turns an unverifiable arm into a build that stops unsealed. It is now the
thing that would have found this in one run instead of four.

S23.7's readings (a) and (b) are both dead, and so is S23.8's closing hypothesis
about `reagentc`. The transport works, the store works, the seal is indifferent,
the boot manager takes the one-shot (S23.8.3, S23.8.5) — and the create now
reaches the store on the machine that failed four times.

### S23.12 — the sysprep Appx failure has a NAME, and Acrobat is in it ✅

Date: 2026-08-31, read from `HDT-M7-RefApp`'s own
`Windows\System32\Sysprep\Panther\setupact.log` and its offline `SOFTWARE` hive.
**Recorded, not mitigated** — S23.9 says the failure is non-deterministic and
nothing here changes HDT's behaviour.

The generalize pass got **further than "Appx is flaky" suggests**, and removed
three packages cleanly first:

```
17:20:47 SYSPRP All appx packages were verified to be inbox or alluser installed.
17:20:48 SYSPRP Package Microsoft.SecHealthUI_1000.26100.1.0_x64__8wekyb3d8bbwe was removed
17:20:49 SYSPRP Package Microsoft.MicrosoftEdge.Stable_152.0.4191.53_neutral__8wekyb3d8bbwe was removed
17:20:49 SYSPRP Package AdobeAcrobatReaderCoreApp_26.0.0.1_x64__pc75e8sa7ep4e was removed
17:20:49 SYSPRP Failed while deleting per user keys under
                'Software\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\': 0x800703fa
```

**THE THIRD ONE IS ACROBAT'S, AND `InstallApplications` PUT IT THERE FOUR
MINUTES EARLIER.** Adobe Acrobat Reader's installer registers a companion Appx
package, `AdobeAcrobatReaderCoreApp`, and the offline `SOFTWARE` hive shows it in
**both** places:

```
...\Appx\AppxAllUserStore\Applications\AdobeAcrobatReaderCoreApp_26.0.0.1_x64__pc75e8sa7ep4e
...\Appx\AppxAllUserStore\S-1-5-21-...-500\AdobeAcrobatReaderCoreApp_26.0.0.1_x64__pc75e8sa7ep4e
```

`S-1-5-21-…-500` is the built-in Administrator — **the account HDT's own
autologon runs the full-OS leg as**, and the only per-user SID key under
`AppxAllUserStore` on that machine. Sysprep removed the all-user registration and
then failed sweeping the per-user records with `0x800703fa`
(`ERROR_KEY_DELETED`, `gle=ERROR_FILE_NOT_FOUND`), and **both Acrobat records
were still in the hive afterwards**.

**So the cheap answer is yes:** `Remove-AppxPackage -AllUsers -Package
AdobeAcrobatReaderCoreApp_26.0.0.1_x64__pc75e8sa7ep4e` before `Sysprep` takes out
the record the sweep tripped on. HDT ships no such mitigation today, and the
general shape is worth more than the one package: *an application installed in
the full-OS leg registers an Appx for the autologon account, and generalize's
per-user sweep races its own all-user removal*. It is unmitigated in MDT and in
PSD alike.

`sysprep` has **no BCD module at all** in `Generalize.xml` — the full module list
was read and there is nothing boot-related in it, which independently confirms
S23.5 and S23.8.4: sysprep is not what removes a BCD entry, and never was.

**One operational note, and it cost two cycles.** A machine left in
`IMAGE_STATE_UNDEPLOYABLE` runs `sysprep /respecialize /quiet` on its next boot,
fails it with `0x8007001f`, and **the built-in Administrator does not autologon
and will not accept its password** — so a failed reference build cannot simply be
logged into to look at. Getting into one means an offline plant: a boot-time
service under `ControlSet001\Services` whose `ImagePath` is a `cmd.exe /c net
user ...`. `powershell.exe -File` in the same slot started and produced nothing;
`cmd.exe` worked first time.

### S23.13 — the Appx mitigation works, and the capture leg was reading a dead drive letter ✅

Date: 2026-08-31, two runs of `REF-ACROBAT` on `HDT-ACR-REF01`
(`run-20260831-193211` and `run-20260831-194337`), against a boot image rebuilt
from the bundle carrying 62a1ccd's fix.

#### The one-shot works, end to end, for the first time

S23.11's unary comma was the whole of it. With it fixed:

```
step 12: creating the UEFI boot entry {7f1b6e18-...} for C:\HDT\Boot\boot.wim
step 12: The next boot will be the WinPE staged at C:\HDT\Boot\boot.wim.
         The firmware boot order is unchanged.
```

and the reboot after `Sysprep` **landed in WinPE**, on the leg the engine
expected, with no host-side boot-order flip and no boot media in the drive.
`TestBootEntry` passed, which is what four earlier builds could not make it do.

#### The Acrobat Appx package, removed before the seal

S23.12 named it; this ran the mitigation. A `PowerShell` step ahead of `Sysprep`:

```
pre-sysprep: removing Appx AdobeAcrobatReaderCoreApp_26.0.0.1_x64__pc75e8sa7ep4e
pre-sysprep cleanup: 2 task(s) defined, 2 completed, 0 failed
pre-sysprep: 52 Appx package(s) still registered for all users
```

The package is absent from those 52, and `sysprep /generalize` completed.

**It is written as a LIST of pre-seal tasks, not as one removal.** The user's own
framing is the general case — "some application like NPP needs a command line to
reset before we can sysprep" — and the shape a site extends is an entry in
`$preSysprepTask` with a name, a reason and a script block. A failing entry is
logged and the build continues, deliberately: `Sysprep` is the step that gets to
say whether the machine can be sealed, and a cleanup that could not run must not
throw away an hour of installing before it gets the chance.

#### And then step 17 of 17 failed on a drive letter from a previous boot

`run-20260831-193211` reached the capture with the machine already generalized
and lost it:

```
step 16: bcdedit /store S:\EFI\Microsoft\Boot\BCD /delete ...
         The boot configuration data store could not be opened.
step 17: Could not find the directory to capture, 'W:\'
```

**`S:` and `W:` are the DEPLOYMENT WinPE's letters.** `Invoke-HDTDiskPartitionStep`
publishes `HDTSystemVolume` and `HDTOSVolume` from the letters it assigns, and
the engine carries them across reboots in `state.json` — correct for every
deployment, because the full-OS leg never reads them again.

A reference build breaks that assumption by going *back* into WinPE. The WinPE
that captures is a second boot of a **different image** — the one `BootToWinPE`
staged onto the local disk — and it mounts the same partitions under its own
letters. Step 16 tolerated the miss and left a boot entry behind; step 17 failed
the run outright, at the single most expensive point a reference build has.

**This is an engine gap, not a template one.** MDT does not have it because
`ZTIBackup` determines the drive to capture *at capture time* rather than
trusting a variable set before a reboot. The template answers it today with a
`PowerShell` step first in the capture leg
(`TaskSequences\REF-ACROBAT\Resolve-CaptureVolume.ps1`) that asks every lettered
volume two questions — does it carry `Windows\System32\ntoskrnl.exe`, does it
carry `\EFI\Microsoft\Boot\BCD` — and republishes both variables. Missing the OS
volume is a refusal naming what was looked for; missing the BCD store is a note,
because `BootToWinPE remove` already survives it.

**The engine should do this itself**, in `Invoke-HDTCaptureImageStep` or on entry
to a resumed WinPE leg: a `HDTOSVolume` inherited across a reboot into a
different WinPE is not evidence, and the failure it produces arrives four steps
and one generalize too late to recover from.

`run-20260831-194337` measured the drift exactly, and **both** letters had moved:

```
inherited HDTOSVolume     : W        <- the deployment WinPE's letters
inherited HDTSystemVolume : S
found an operating system on C:      <- the capture WinPE's
found a BCD store on D:
HDTOSVolume is now C
HDTSystemVolume is now D
```

`capturing C:\ into ...\Captures\REF-ACROBAT.wim` then ran, and the reference
build completed all eighteen steps.

#### A residue, recorded and not fixed

With the store finally *found*, `BootToWinPE remove` still cannot delete the
one-shot entry from inside the WinPE that entry booted:

```
bcdedit /store D:\EFI\Microsoft\Boot\BCD /delete {7f1b6e18-...} /cleanup
  The boot configuration data store could not be opened. Access is denied.
```

`Access is denied` and no longer `cannot find the file` — the path was wrong
before and the permission is wrong now. It is **not** a defect in the captured
image: the capture reads the OS volume and the entry sits on the EFI system
partition, so nothing of it travels into the WIM, and the step's own message is
correct that the machine still boots Windows. It matters for a machine that is
KEPT rather than discarded, which a reference machine is not. Left as it is.
