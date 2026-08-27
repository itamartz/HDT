# HDT Roadmap

Companion to [DESIGN.md](DESIGN.md). Milestones are ordered by **dependency and
risk**, not by feature appeal — the parts most likely to invalidate the design
come first.

Every milestone follows the same rule from DESIGN §12.2: **the tests listed
under "Tests first" are written and failing before the implementation starts.**
A milestone is not done until its exit criteria are met with a green suite.

---

## M0 — Skeleton and harness

*Goal: it is impossible to add untested code after this point.*

- Repo structure (`src/Hephaestus/`, `schemas/`, `tests/`, `docs/`, `samples/`),
  `git init`, `.gitignore`, `README.md`.
- Module manifest, `Set-StrictMode`, public/private function layout, build
  script (`Invoke-Build` or plain `build.ps1`).
- Pester 5 harness, PSScriptAnalyzer settings, CI workflow (Windows runner).
- Fixture conventions and the first hand-written fakes (`FakeFileSystem`,
  `FakeCimProvider`).

**Tests first:** the harness proves itself — a deliberately failing test fails
CI, a passing one passes, analyzer violations block. Plus the **naming contract
test** from DESIGN §15.1: every function the module defines matches
`^[A-Z][a-z]+-HDT[A-Z]` with an approved verb. Landing this in M0 means an
unprefixed command can never be committed in the first place.

**Exit:** `./build.ps1 test` runs green locally and in CI on a clean clone.

---

## M1 — Variables and rules

*Goal: the thing that replaces `CustomSettings.ini` + `ZTIGather`, proven without
touching hardware.*

- Fact gathering behind `ICimProvider` (Make, Model, UUID, firmware, TPM, NIC…).
- `rules.yaml` parser + schema.
- Resolution engine: five-source precedence, first-match-wins per variable,
  `%Var%` expansion, `setFrom:` script rules.
- **Provenance recording** — every variable knows which source set it.

**Tests first:** precedence across all five sources; wildcard and multi-key
`when` matching; fallback rules only filling unset variables; recursive and
cyclic `%Var%` expansion; provenance correctness; malformed YAML producing a
pointed configuration error, not a crash.

**Exit:** given a fixture machine's facts and a `rules.yaml`, the engine
produces the expected variable set *and* explains every value.

---

## M2 — Task sequence engine (no real work)

*Goal: sequencing, conditions, and reboot-resume are correct before any step does
anything destructive.*

- `sequence.yaml` parser + schema; groups, nesting, conditions.
- Step contract (`Test-Applicable` / `Invoke-Step` / `Get-StepDescription`) and
  discovery of step types from `Modules\`.
- Execution loop: ordering, `condition`, `continueOnError`, `retry`, `timeout`,
  `runIn` phase filtering.
- State document, checkpointing, skip-completed-on-resume.
- Autologon lifecycle (DESIGN §4.5) behind `IRegistryService` / `ILsaService`:
  per-deployment password generation, arm-before-restart, `AutoLogonCount`,
  boot-time reconcile, `finally` teardown.
- Structured JSONL logging + `ConvertTo-HDTReport`.
- Step types implemented: `SetVariable`, `PowerShell`, `CommandLine`, `Restart`
  — plus a `NoOp` test step.

**Tests first:** the DESIGN §12.2.1 target — a full sequence executes against
fake services and asserts the exact ordered operation list. Plus: conditions
skipping groups; `continueOnError` semantics; retry/backoff; a simulated reboot
mid-sequence resuming at the right index; an interrupted non-resumable step
failing rather than silently re-running.

Autologon gets its own block, since it is the mechanism most likely to leave a
machine in a bad state: the teardown checklist (DESIGN §4.5.3) is asserted empty
after a successful run, after a **failed** run, after an **abandoned** run
(state document present but stale), and after a run whose state document is
missing entirely. Plus: the password is different on every run; `AutoLogonCount`
matches the number of remaining legs; arming is idempotent across repeated
restarts.

**Spike inside M2:** verify the LSA-secret + `AutoLogonCount` combination on
each supported Windows build before building on it. If it does not hold, fall
back to registry storage with explicit teardown and update DESIGN §4.5.2.

**Exit:** a multi-group sequence with reboots runs to completion in a Pester
run, with a readable report, having touched nothing real.

**✅ Met.** `tests/unit/TaskSequence.EndToEnd.Tests.ps1` runs
`samples/workspace/TaskSequences/DEMO-M2/sequence.yaml` across three legs and two
reboots against fakes, asserting the exact ordered list of the 31 operations it
would have performed on a machine, every step accounted for exactly once, the
JSONL `seq` continuous across all three legs, an empty autologon checklist at the
end, and a rendered report — in about three seconds, which is itself evidence
that nothing in it was real. The same sequence was then run live against the real
filesystem, clock, process service and script invoker (with power, registry and
LSA still faked, because a demonstration may not reboot the developer's machine)
and its report opened in a browser.

**Two limitations M2 ships with, documented in DESIGN §4.3 rather than hidden:**
`timeoutMinutes` is not pre-emptive — only `CommandLine` can enforce it, and an
overrun is otherwise detected after the fact; and `PauseOnError` returns with the
state loaded rather than opening a prompt, because the prompt belongs to the
caller. **And one thing M2 does not ship:** the final Administrator password
policy that DESIGN §4.5.3 requires at the end of the teardown checklist. It is
listed under M6.

---

## M3 — Imaging

*Goal: the destructive parts, guarded.*

- `IDiskService` / `IImageService` adapters over DISM, storage cmdlets,
  `bcdboot`, `reagentc`.
- Named disk layouts (`uefi-standard`, `bios-standard`); firmware detection.
- Steps: `Validate`, `DiskPartition`, `ApplyImage`, `ApplyUnattend`,
  `ConfigureBoot`.
- `Import-HDTOperatingSystem`, `os.yaml`, index selection by number/name/edition.

**Tests first:** layout planning for UEFI and BIOS, including the recovery
partition; **target-disk ambiguity refusing to proceed** (multiple disks, data
volumes present, USB source disk in range) — this is the destructive failure
mode from DESIGN §9.1 and gets the most tests; index resolution; unattend
placement. Integration layer: real apply to a scratch VHDX.

Each of those bullets, against the file that proves it:

| Tests first | Proven by |
|---|---|
| layout planning for UEFI and BIOS, with the recovery partition | `tests/unit/Get-HDTDiskLayout.Tests.ps1`, `tests/unit/New-HDTDiskLayoutPlan.Tests.ps1` — arithmetic asserted to the byte on 64 GiB, 128 GiB and an awkward 32 GB disk |
| **target-disk ambiguity refusing to proceed** | `tests/unit/Select-HDTTargetDisk.Tests.ps1` (the seven rules, both classes), and `tests/unit/Invoke-HDTDiskPartitionStep.Tests.ps1` — where the assertion that matters is *"writes nothing when it refuses"* |
| index resolution | `tests/unit/Resolve-HDTImageIndex.Tests.ps1`, `tests/unit/Invoke-HDTApplyImageStep.Tests.ps1` |
| unattend placement | `tests/unit/Invoke-HDTApplyUnattendStep.Tests.ps1` — `Windows\Panther\unattend.xml` asserted exactly, because that is the path SPIKES S7 verified |
| the whole WinPE leg, as one ordered operation list | `tests/unit/Imaging.EndToEnd.Tests.ps1` — DESIGN §12.2.1's benchmark for this milestone |
| real apply to a scratch VHDX | `tests/integration` (04-04) |

**Exit:** a VM boots into Windows from a sequence run end-to-end. **That is
demonstrated in 04-04, not before it.** Everything above this line is proven
against hand-written fakes: the ordered operation list is what HDT *would* do to
a machine, asserted in a Pester run that touches nothing. The lab run is what
turns it into what HDT *does*.

**✅ Met.** `tests/e2e/Deployment.E2E.Tests.ps1` builds `HDT-M3-Deploy` —
Generation 2, Secure Boot on, 4 GB, 2 vCPU, on the isolated `HDT Lab` switch —
boots it from the WinPE ISO, types one line at the prompt, and lets
`Invoke-HDTTaskSequence` run `samples/workspace/TaskSequences/DEMO-M3` against
the **real** disk and image services: Validate, DiskPartition, ApplyImage,
ApplyUnattend, ConfigureBoot. It then starts the VM again **with the WinPE ISO
still in the DVD drive and the firmware boot order untouched**, and the machine
reaches full Windows 11.

| Leg | Time |
|---|---|
| Content disk staged (engine, `powershell-yaml`, workspace, 4 GB WIM) | 12–14 s |
| WinPE boot → all five steps → shutdown | 273 s wall, of which the engine reported **100 s** |
| Apply of Windows 11 index 1 alone (integration suite, local disk) | **132–134 s** (SPIKES S6 measured 95 s over SMB) |
| First Windows boot to a settled integration-services heartbeat | 265 s |

**What it proves.** That the machine reached Windows is asserted from the
integration-services heartbeat — WinPE never reports one and full Windows always
does — not from a screenshot. And because the media was still attached, it also
proves `ConfigureBoot`'s `SetBootOrderFirst` works: SPIKES S6's fourth finding
was that a machine whose firmware still prefers the boot media simply reboots
into WinPE and the deployment appears to loop. That call had never run anywhere
before, because it edits the firmware boot order of the machine it runs on.

**Six things the lab run corrected**, each of which the fakes had been green
about (SPIKES S9):

1. `Clear-Disk` **throws on a RAW disk**, and every factory-fresh machine disk is
   RAW. `DiskPartition` called it unconditionally and could not have partitioned
   a new machine.
2. **Windows Setup silently discards a `ComputerName` over 15 characters.** The
   first run reported `Succeeded` on every step and produced a machine called
   `WIN-N91191NN153`. `ApplyUnattend` now refuses the name instead.
3. `Initialize-Disk` creates a Microsoft Reserved partition **on the host and not
   inside WinPE** — S6's own log said so and nobody had noticed.
4. `reagentc /setreimage` against an offline image **exits 0, prints "Operation
   Successful" and registers nothing.** WinRE on the deployed machine is Setup's
   doing, not `ConfigureBoot`'s.
5. The MSR is 16 759 808 bytes at offset 17 408 — which together are exactly the
   16 MB the layouts carry as `ReservedSizeByte`.
6. FAT32 uppercases a volume label; nothing may match one case-sensitively.

**What M3 ships without, stated plainly:**

- **No reboot into the full OS driven by the engine.** `DEMO-M3` has no `Restart`
  step, deliberately: the WinPE→full-OS handoff arms autologon through the
  registry and an LSA secret, and in WinPE those are the RAM disk's. That belongs
  to M4's `Start-HDTDeployment`.
- **No autologon resume**, for the same reason. The first logon of the machine
  being built is configured by the unattend, which is what `ApplyUnattend` stages.
- **No drivers** (M5) and **no applications, updates or roles** (M6).
- **No share.** The workspace is a locally attached content disk, because
  PROJECT.md requires the isolated `HDT Lab` switch and SPIKES S6 records that a
  VM there cannot reach a share on the host. The `Smb` provider is M4's.
- **No boot image built by HDT.** The ISO is SPIKES S1/S3's hand-built artifact;
  `Update-HDTBootImage` and `New-HDTBootIso` are M4's, and until they exist the
  harness types one line at the WinPE prompt instead of `startnet.cmd` doing it.
- **No PXE.** M4.
- **WinRE is not configured by HDT** — see finding 4 above.
- **Domain join is unproven end to end.** The `HDT Lab` switch is isolated by
  design, so a test VM cannot reach `DC01` and must not be moved to. `JoinDomain`
  is verified against a fake only (PROJECT.md says so explicitly).

---

## M4 — Boot image, ISO, and PXE

*Note: the ISO half lands early in this milestone, not at the end — it is the
debugging vehicle for everything after it. M3's VM testing uses it too, so in
practice `New-HDTBootIso` is pulled forward into M3 if imaging work needs it.*

- `Update-HDTBootImage`: ADK detection, optional components in dependency
  order, boot driver injection, engine staging, `startnet.cmd`, export.
- **`New-HDTBootIso`**: `oscdimg` wrapper, `-Firmware UEFI|BIOS|Both`,
  `-NoPromptForKey` via `efisys_noprompt.bin` (DESIGN §5.2).
- Build manifest recording exactly what went into the WIM; `-SkipIso`.
- `Import-HDTBootImageToWds` with replace-in-place semantics;
  `New-HDTPxePayload` for non-WDS TFTP/HTTP stacks.
- `Smb` content provider, credential prompt flow, least-privilege share ACL doc.

**Tests first:** component ordering and dependency validation; manifest
accuracy; **WIM/ISO equivalence — the WIM inside the ISO hashes identical to the
standalone WIM** (DESIGN §6.1.1, the property the whole debugging story rests
on); `-NoPromptForKey` selecting `efisys_noprompt.bin` and warning on
`-Firmware BIOS`; `-SkipIso` skipping only the ISO; WDS import replacing rather
than duplicating an existing image; payload staging completeness; provider
contract tests (`Smb` and `Local` behave identically from a step's
perspective); refusal to fall back to guest auth.

**Exit (v1):** a VM boots the ISO unattended with no keypress and deploys.

~~**and** a physical or virtual machine PXE-boots the same image from WDS.~~
**MOVED TO v2 by the user on 2026-08-25.** v1 deploys from the ISO, which is
proven; PXE needs an isolated `HDT-WDS01` that `PROJECT.md` rule 3 will not let
stand beside CM01's responder, and waiting on lab hardware is not a reason to
hold v1. `Import-HDTBootImageToWds` and `New-HDTPxePayload` still ship — they
are scheduled out, not cut, and nothing in v1 assumes they are absent.

**✅ Met, as scoped above.**

`tests/e2e/UnattendedDeployment.E2E.Tests.ps1` builds a boot image with
`Update-HDTBootImage`, creates `HDT-M4-Deploy` — Generation 2, Secure Boot on,
4 GB, 2 vCPU, on the isolated `HDT Lab` switch — boots it from the ISO **that
build produced**, and then **sends the machine nothing at all**. Inside the
image, `startnet.cmd` runs `wpeinit` and then `X:\HDT\Start-HDTDeployment.ps1`,
which resolves its own deploy root and runs
`samples/workspace/TaskSequences/DEMO-M4` against the real disk and image
services. The VM is then started again **with the ISO still attached and the
boot order untouched**, and reaches full Windows 11.

`RESULT.json`, read off the content disk after the machine powered itself off:

```
status Succeeded    launchedBy startnet    provider Local    sequenceId DEMO-M4
deployRoot \Share   resolvedDeployRoot C:\Share   deployRootSource Discovered
yamlBase X:\HDT\Modules\powershell-yaml   psVersion 5.1.26100.1
elapsedSecond 105   endedWith "wpeutil shutdown"   computerName HDT-M4-01
```

| Leg | M3 (SPIKES S9.12) | M4 (SPIKES S12) |
|---|---|---|
| Boot image built by HDT | — (hand-built spike artifact) | **134 s** |
| Content disk staged | 12–14 s | **11 s**, and it no longer carries the engine |
| WinPE boot → five steps → shutdown | 273 s wall, engine reported 100 s | **248 s wall, engine reported 105 s** |
| First Windows boot to a settled heartbeat | 265 s | **319 s** |

**The M4 leg is 25 s faster than the M3 one that a harness started by hand** —
the machine begins deploying the moment `wpeinit` returns, instead of after a
harness slept and typed.

**Why "zero keystrokes" is a fact and not a claim.** Three independent proofs:
`tests/unit/UnattendedDeploymentE2E.Tests.ps1` parses the E2E in the *fast* suite
and asserts it names no `Send-HDTLabVmText`, `TypeText`, `TypeKey` or
`Msvm_Keyboard`; the guest reports `launchedBy startnet`, which only the image's
own `startnet.cmd` sets; and nothing types, so a `startnet.cmd` that failed to
launch the payload would leave a WinPE prompt and time out rather than pass.

**What the lab run corrected.** One defect, and both E2E files found it in the
same run (SPIKES S12.3): **the state document was frozen by its own log
relocation.** `state.json` lives in the log directory, 05-03's relocation mirrors
that whole directory onto the target volume, the writes kept going to the RAM
disk, and `Copy-HDTLog` then shipped the frozen copy to the share — so the state
document a technician reads reported three steps `Pending` on a deployment that
had succeeded and booted. DESIGN 4.4.6's heartbeat was moved for exactly this
reason ten lines earlier; the state document was not. It had been unprovable for
two plans because SPIKES S10's missing media stopped `-Task e2e` from running at
all.

**What M4 ships without, stated plainly:**

- ~~**No VM deployed over SMB.**~~ **CLOSED by SPIKES S14.** This was true of
  the M4 run above and of every run before it: on the isolated `HDT Lab` switch
  a VM cannot reach a share on the host (SPIKES S6), so that image declared
  `provider: Local` and a **volume-relative** `deployRoot`. S14 moved the VM to
  `HDT External`, which carries a real DHCP lease, and deployed `HDT-SMB-01`
  through the product with `provider: Smb` and a UNC `deployRoot` — image
  pulled across the network, logs written back to the share. SMB deployment has
  since run repeatedly, the wizard E2E included.
- **No WDS import has ever executed, anywhere in this repository.** This host is
  Windows 11 Pro; `Get-Module -ListAvailable WDS` and `Get-Command wdsutil.exe`
  both return nothing, and standing WDS up beside `CM01`'s PXE responder is
  refused by `PROJECT.md` rule 3. `Import-HDTBootImageToWds`'s replace-in-place
  semantics — including "importing the same image twice leaves one image" — are
  asserted against `New-HDTFakeWdsService`. The one thing this machine can prove
  is proven against the real adapter: `New-HDTWdsService` refuses with a named
  `HDTDependencyError`. **This is why the PXE clause moved to v2** rather than
  being carried as an open v1 gap — see the exit criterion above.
- **The PXE payload is staged and hash-verified but has never been
  network-booted.** `New-HDTPxePayload`'s `Complete` means "every declared file
  is staged and its bytes verify" and **not** "a machine will PXE boot from
  this". The `BCD` it stages is the ADK media template, which describes booting
  `sources\boot.wim` from removable media; a TFTP/HTTP stack generally needs its
  own store and its own device element. The source file, the integration test and
  this list all say so in those words.
- **No drivers in the deployed OS** (M5) and **no applications, updates, roles
  or BitLocker** (M6). Drivers reach the BOOT IMAGE — a selection profile names
  folders and `Update-HDTBootImage` injects them — but nothing puts a driver on
  the machine being built, because that is the `ApplyDrivers` step and it does
  not exist.
- **No engine-driven reboot into an autologon resume.** `DEMO-M4` has no
  `Restart` step, deliberately and for DEMO-M3's unexpired reason: the reboot
  ceremony arms autologon through the registry and an LSA secret, and in WinPE
  those belong to the RAM disk. The first logon of the deployed machine is
  configured by the unattend, which `ApplyUnattend` stages.
- **Domain join is still unproven end to end**, for the reason `PROJECT.md`
  gives: the `HDT Lab` switch is isolated and a test VM must not be moved to
  reach `DC01`.
- **DESIGN 11's technician UI is absent.** It is M8.

**One thing M4 shipped late, in 05-06, because it was the phase's own unanswered
question.** M2 above asked whether WinPE needs `wpeutil reboot` rather than
`shutdown.exe` and named phase 05 as the owner; five plans went by with it open
and `New-HDTPowerService` never once executed. **It is answered now, and it was
not a matter of style — `shutdown.exe` is not in WinPE at all:**

```
Windows\System32\shutdown.exe   ABSENT
Windows\System32\wpeutil.exe    PRESENT, 32768 bytes
```

read out of the boot image `Update-HDTBootImage` builds, and confirmed from
inside a running WinPE by the smoke probe. So the old adapter would have given a
`Restart` step a command that does not exist. Nothing caught it because `DEMO-M3`
and `DEMO-M4` both deliberately have no `Restart` step and the `IPowerService`
contract's real row is skipped permanently — a contract test may not reboot the
machine running it.

`Get-HDTPowerCommand` now makes the decision (pure, 26 tests),
`New-HDTPowerService -Environment` is **mandatory** so no caller can inherit the
wrong answer, and `tests/e2e/WinPeSmoke.E2E.Tests.ps1` **powers its VM off with
the real adapter** — the probe's fallback marker `FALLBACK.txt` is asserted
absent, so "the machine ended" cannot stand in for "the service ended it". The
payload's own `endedWith: wpeutil shutdown` is still a direct call, after the
catch, because it must work on a run where the module never imported.

**Two questions this phase cannot decide for itself**, both about whether the
gaps above are acceptable: an isolated `HDT-FS01` file server on `HDT Lab` would
let a VM deploy over SMB, and an isolated `HDT-WDS01` would let the WDS import
run for real. Neither is built, and neither may be built on `Default Switch`.

---

## M5 — Drivers  ·  **BUILT · EXIT NOT YET PROVEN ON HARDWARE**

> **All of it is built as of 2026-08-27.** The group-match path — MDT's PRIMARY
> one — shipped first, with the catalog: drivers go on the share, are named by a
> selection profile, are read out of their own `.inf` files, can be turned off
> one at a time, and are injected into a boot image. The PnP FALLBACK, the
> `ApplyDrivers` step, the class filter and the coverage report followed.
>
> **What is left is the proof, not the code.** The exit criterion is a real
> unrecognised model deployed end to end with a working network card, and that
> deployment has not been run. See "Exit" below.

### Shipped

- **Selection profiles** — `Control\selection-profiles.yaml`, MDT's selection
  profile kept: a named set of share-relative include paths, reused by the boot
  image and (later) by media. `Get-`/`Expand-`/`New-`/`Set-`/`Remove-` and
  `Save-HDTSelectionProfileDocument`, all splicing so an administrator's
  comments survive. Two built-ins — `all-drivers`, `everything` — resolve with
  no document, so a share nobody has authored on still builds.
- **The driver store** — `New-HDTDriverFolder` makes `Make\Model` in one call;
  `Import-HDTDriver` puts a vendor pack on the share and EXPANDS it: a Dell
  `.cab` through `expand.exe`, an HP SoftPaq by running the `.exe` with the
  switches that unpack rather than install. The `.inf` count is taken afterwards,
  from the files on disk, because a vendor installer's exit code is not evidence.
- **The catalog** — `ConvertFrom-HDTDriverInf` reads a driver out of its own
  `.inf`: name, class, provider, version, date and every hardware id, through
  decorated `[Manufacturer]` sections, `%TOKEN%` indirection and UTF-16LE.
  `Get-HDTDriver` walks the store and answers a row per file. There is no index
  document: the `.inf` files ARE the index, and an index beside them is a second
  answer that can go stale.
- **A driver can be turned off** — `Set-HDTDriverState` writes only the disabled
  set to `Control\driver-state.yaml`, and deletes the document when the last one
  is enabled. DISM's `-Recurse` takes a whole folder and has no "except that
  one", so `Get-HDTBootImageDriverInjection` hands it the folder whole when
  nothing is disabled and one `.inf` at a time when something is.
- **Boot image injection** — `bootImage.drivers:` names a profile, and
  `Update-HDTBootImage` calls `AddDriver` once per included folder, in declared
  order. **One image carries a Dell WinPE pack and an HP one**, which a single
  folder name never could. A share written before profiles existed still names a
  folder and still works: `Resolve-HDTBootImageDriverPath` tries the profile
  first and falls back.
- **The console** — a Selection Profiles node with a tick-box tree editor
  (tri-state, because "some of Drivers" and "all of Drivers" are a hundred
  `.inf` files apart); New Folder, Import Drivers and Delete Driver Folder on the
  Drivers node; a Drivers tab that shows the folders it will actually inject and
  marks in red any the share has not got; a grid of the drivers in a folder; and
  a properties window per driver — Workbench's, with its two tabs collapsed into
  one — carrying the Enable tick box and the PnP ids.

### Built 2026-08-27 — the half that was deferred

- **`ApplyDrivers` step.** Group match primary, PnP behind it, offline injection
  into the applied volume via `IImageService.AddDriver`. The group is a path a
  rule builds — `Win11\%HDTMake%\%HDTModel%` — of any depth and any names;
  nothing discovers or imposes a `Make\Model` shape.
- **PnP match**, ranked specificity → version → date. **Specificity is not a
  score HDT invents:** Windows publishes `HardwareID` most-specific-first with
  `CompatibleID` as the generic tail, so the rank is the INDEX of the match. The
  original plan was to parse `VEN`/`DEV`/`SUBSYS`/`REV` and score it, which
  would have been a second opinion about something Windows already decides.
- **The class filter** — `Get-HDTBootCriticalClass`: Net, SCSIAdapter, HDC,
  System. A driver whose class cannot be read is KEPT, because dropping a NIC
  driver over a missing field is the wrong direction to fail in.
- **`Get-HDTDriverCoverage`** — which models have a group, and which have an
  EMPTY one, which is a different problem wanting a different fix.
- **The decision is in the log**: five `driver.*` events, so "why did this
  machine get that driver" is answered by filtering rather than by reasoning.

**No `driver-index.json`, and DESIGN §7 has been corrected to say so.** The
`.inf` files are the catalog. Measured cost of not having an index: 2.5 s to
read a 211-file store, 0.5 s for the device query — about three seconds, once,
on the fallback path only.

**Verified in real WinPE (SPIKES S19)**, which is what the whole fallback rests
on and what S1 never tested: `Win32_PnPEntity` answers 44 devices with populated
hardware ids in 498 ms. `PNPClass` is populated on 32 of 44, so nothing may
assume a class is present.

**Exit — built, not yet proven on hardware.** The criterion is *an unrecognised
model deploys with working network and storage via PnP fallback*, and that means
a real machine no rule matches, deployed end to end, with a working NIC
afterwards. Every piece is in place and unit-tested against captured devices and
real vendor `.inf` files; what has not happened is the deployment. Recorded as
built rather than met, because the difference between those two is exactly what
this section exists to keep honest.

---

## M6 — Applications and full-OS steps

- `app.yaml` schema; `InstallApplications` step.
- Detection rules (`msiProduct`, `file`, `registry`, `script`) — **optional**.
  An `app.yaml` that declares no `detect:` installs every time the step reaches
  it, which is what an unconditional installer or a script wrapper wants. MDT has
  no detection at all, so omitting it lands exactly on MDT's behaviour; declaring
  it is the improvement, not the requirement. The engine never invents a
  detection rule for an app that declined to declare one.
- Dependency topological sort with cycle detection at authoring time.
- Exit-code classification, `3010` reboot-and-resume.
- **`InstallRoles`** (DESIGN §10.2): `Install-WindowsFeature` wrapper, feature
  name validation, SxS source through the content provider.
- **`EnableBitLocker`** (DESIGN §10.3): `scope: usedSpaceOnly | full`, protector
  and method selection, AD/Entra escrow verified before encryption starts.
- **The local Administrator password is a variable, not a step.** This bullet
  previously specified a `SetAdminPassword` step type; **DESIGN §4.5.2 and §4.5.4
  already settle it the other way and they win.** The password is
  `HDTAdminPassword`, resolved through the §3.1 precedence like any other
  variable and defaulted in **the fallback rule of `rules.yaml`** — MDT's
  `[Default]` section. *Not* `workspace.yaml`: DESIGN §4.5.2 said so in passing
  and was wrong, because `workspace.yaml` is not one of §3.1's six variable
  sources, so a default living there would resolve through no precedence and
  record no provenance. Both documents are corrected.

  The teardown deliberately does **not** change the account — the machine keeps
  the password the administrator configured, so a technician can log into a
  deployment that *failed*, which is the case that matters. This is MDT's
  `AdminPassword`, and it removes a step type rather than adding one.

  **`HDTAdminPasswordPolicy` is CUT (user, 2026-08-25), and M6 has no loose end
  left.** HDT supplies the password as clear text, exactly as MDT does:
  `HDTAdminPassword` resolves through the rules engine and the deployed machine
  keeps it. `rotate`, `laps` and `disable` were a local-account service and
  three more end states to test, for a policy MDT never had — a site that wants
  LAPS installs LAPS. DESIGN §4.5.4 records the decision.
- Server task sequence in `samples/`.
- **`WindowsUpdate` is deferred to v2** — see below.

### Deferred out of M6 to v2

**`WindowsUpdate`** (DESIGN §10.1): WUA COM API, WSUS target, category and
exclusion filters, multi-pass loop with reboots. **Scheduled out of v1 at the
user's direction on 2026-08-16; the design section stays in full.**

What deferring it costs, stated so it is not discovered later: **a machine HDT
builds leaves the bench with exactly the patches its source image carried.**
There is no in-sequence patching, so currency is whatever the media has plus
whatever Windows Update does on its own schedule after the technician hands the
machine over. The sample sequences do not run it, and DESIGN §10.1's "run it
twice, once before applications and once after" describes v2. Nothing in v1 is
built in a way that assumes the step is absent: it is a step type like any other,
and adding it later adds files rather than changing them.

**No Windows Server VM in the E2E matrix** either. `InstallRoles` still ships and
still gets a server sample sequence; only the Hyper-V leg is scheduled out.

**Tests first (full-OS steps):** `InstallRoles` failing fast on an unknown
feature name with valid alternatives listed, and resolving SxS source identically
under `Smb` and `Local`. BitLocker: **escrow verified before encryption begins**
(a machine encrypted with no recoverable key is worse than an unencrypted one —
this gets a dedicated test), `scope` mapping to `-UsedSpaceOnly`, `escrow: none`
warning, `wait: false` returning without blocking.

**Tests first (admin password policy):** `keep` leaving the configured password
in place and the autologon torn down around it; `rotate` landing on the second
configured value; `laps` leaving the account enrolled rather than rotated;
`disable` leaving it disabled; an unknown policy value rejected at validation
rather than at deploy time; and no policy path writing the password into a log
line or into `state.json`.

**Tests first (applications):** dependency sort determinism; cycle detected as a validation
error; detection short-circuiting an already-installed app **when one is
declared**, and an app declaring none installing every time; reboot mid-list
resuming at the next app, not restarting the list; success vs. reboot vs. failure
code classification.

**Exit:** a sequence installs a dependency chain across a reboot, idempotently.

---

## M7 — Capture and standalone media  ·  **DEFERRED TO v2**

> **v2, not cut.** Scheduled out of v1 at the user's direction; the milestone is
> kept here in full so v2 starts from a written plan rather than a memory. See
> `.planning/ROADMAP.md` "v1 scope" for what deferring it costs.


- `Sysprep` and `CaptureImage` steps; `Captures\` output; promotion into the OS
  catalog.
- `New-HDTMedia`: content projection for a selected set of sequences, ISO and
  USB (FAT32 boot + NTFS content) layouts.

**Tests first:** projection completeness — every artifact a selected sequence
references is included, and nothing else (this is the correctness heart of media
generation, and it is pure logic); provider-swap equivalence: the same sequence
produces the same operation list under `Local` as under `Smb`.

**Exit:** a USB stick built from the share deploys a machine with no network.

**Carried over from v1, and it must be decided before `New-HDTMedia` is
written** — three behaviours built for SMB that a disc has no answer for:

1. **Five attempts, then the Welcome screen.** `Start-HDTDeployment` retries the
   deploy root five times (2/4/6/8s) and, when it still cannot be reached, opens
   the Welcome screen with the share box prefilled so a technician can correct
   it. That is right for SMB, where the usual cause is an address that moved. On
   media there is nothing to correct: the content is on the disc the machine
   booted from, and a share box offered for a disc is a question with no answer.
   The Local provider should fail with what is actually wrong - the marker was
   not found on any ready volume - rather than asking for a UNC path.

2. **The corrected share is carried into the full-OS leg, for UNC only.**
   `Invoke-HDTTaskSequence` writes the resolved deploy root into the staged
   `bootstrap.json` so the resume leg uses the share that actually answered.
   It is guarded to `\\` deliberately: media that is `D:` in WinPE is commonly
   another letter once Windows has assigned its own, so carrying a resolved
   local path would hand the resume a drive letter that has moved. Media must
   keep the image's own value and resolve it again through
   `Resolve-HDTDeployRoot` from the content marker. There is a test for this -
   "leaves a local root alone, because a drive letter moves" - and it should
   stay green when media arrives.

3. **The log copy-back has two destinations, and a disc is not one.** The WinPE
   leg now copies its log to `<osvolume>\HDT\Logs` before restarting, and the
   run is copied to `<deployRoot>\Logs` at the end. The first is right for
   media; the second writes to read-only content. `Get-HDTLogDestination`
   already answers `HDTSLShare` first, which is the escape hatch - but a media
   deployment with no `HDTSLShare` set should not be trying to write to the
   disc, and today nothing stops it.

---

## M8 — Console (WPF)

- WPF/.NET 8 shell, MVVM, `Microsoft.PowerShell.SDK` runspace hosting.
- Workspace tree navigation; schema-driven validation surfaced inline.
- Task sequence editor with **comment-and-order-preserving** YAML round-trip.
- Monitoring view tailing `Logs\_active\`.
- Every action displays the cmdlet it invokes.

**Tests first:** view-model logic under test independent of the UI; YAML
round-trip fidelity (a load/save cycle on every sample produces a byte-identical
file) — the constraint from DESIGN §11 that keeps git review usable.

**Exit:** an admin can author a task sequence and get it deployed without ever
opening a shell — edit it in the console, build the boot image and ISO from the
console, then watch the run land in Monitoring — and read off the equivalent
cmdlet for every action while doing it.

**The console never starts a deployment, and "run" here does not mean a Run
button.** That is MDT's split and HDT keeps it: the Workbench authors, the
*target machine* boots ISO or PXE into WinPE, and LiteTouch runs the sequence
there. The console's whole share in the run is upstream (boot image, ISO,
published share) and downstream (`Logs\_active\`, the report).

**✅ Met. All four legs, walked in the real window on 2026-08-26 and finished on a real machine on 2026-08-27.**
Not read out of the source: the console was opened on `C:\HDTLab\Share` and
driven through UI Automation with a real mouse, because the last five defects in
it were found by looking at it and every one of them passed its tests first.

| Leg | How it was proven |
|---|---|
| **Author** | New Task Sequence on the Task Sequences node wrote `M8-WALK` to the share, and `sequence.yaml` came back carrying `HDTOSImage`, `HDTFullName`, `HDTOrgName` and `HDTAdminPassword` |
| **Edit** | the editor opened it, eight tabs, and the Disk tab's five buttons edited the partition table |
| **Build the boot image and ISO** | Update Boot Image, from the Windows PE window: 17 steps in **1:47**, `HDTPE_wiz_x64.wim` (476 MB) and `.iso` (529 MB) rewritten, manifest `builtUtc` moving from `2026-08-23T21:18:33Z` to `2026-08-26T18:01:50Z` |
| **Read the cmdlet off every action** | a contract now asserts every console window's markup carries a `*CommandText`, with `HDTBuildProgress.xaml` the one named exception |

**✅ The fourth leg is met too, on 2026-08-27, and it brought the rest of the
toolkit with it.** `HDT-MON-01` — Generation 2, Secure Boot on, 4 GB, 2 vCPU, on
`HDT External` — booted the ISO the console had just built, reached
`\\192.168.2.112\HDTShare`, and ran `DEMO-05` zero-touch. Fourteen seconds after
the VM started, a run appeared in `Logs\_active\` and the console's Monitoring
node drew it; it was watched through `Install Operating System` and
`Restart into Windows`.

**And it did not stop at WinPE.** The machine restarted into full Windows 11,
resumed under autologon, and the engine carried on to step 11 of 12 — which is
the whole WinPE→full-OS handoff, proven on a machine, not the Monitoring branch
alone. It ended on the failure screen (DESIGN 11.3) naming the step, the type,
the reason and the log path, because `DEMO-05` carries a `Run Command Line` step
with `command: ''` — the share's own content, and exactly what the console's
Command page already warns about when that step is selected.

**Two defects the deployment found**, both in the screen that exists to watch
one, and neither reachable without a real machine:

1. **A live run showed as `Unreadable`, counted as "1 finished", and reported
   its last heartbeat as "(never)".** WinPE syncs no clock, so the heartbeat's
   stamp was eight hours AHEAD of the console's; the age went negative, and `-1`
   was also the sentinel for "no timestamp at all". One value, two meanings.
2. **Nothing compared `deployRoot` with `bootstrap-rules.yaml`'s
   `HDTDeployRoot`.** The lab's lease moved, `deployRoot` was corrected, the
   image was rebuilt — and every machine still went to the old address because
   both bootstrap rules still named it. The Welcome screen even displayed the
   corrected address, because that box is filled from the workspace while the
   rule is what the connection used. Step 12b warns per rule now.

**What the run needed from the lab, recorded because none of it was HDT's
doing:** the host's DHCP lease had moved (`PROJECT.md`'s rule, met in practice),
SMB was blocked on `HDT External` (Public profile, `SMB-In` disabled), and the
share ACL grants only `svc-hdt-deploy` — which is DESIGN 6.3 working, and also
why an administrator cannot open the share in Explorer.

**Three defects the walk found, all fixed, all of which passed their tests:**

1. **New Task Sequence named a command that built a different sequence.** The
   footer showed three parameters; Create passed a fourth, `-Variable`, carrying
   the operating system, the registered owner, the organisation and the
   administrator password — so an administrator who copied the line, which is
   the one thing DESIGN 12 says it is for, got a sequence with none of them.
   §4.5.4 makes that window the admin password's only home, which is what made
   it the worst place to lose it.
2. **Partition Properties had nowhere to print what OK runs** — the only console
   window without a command line, and the one place eight boxes are decided.
3. **Every partition edit died on a blank line.** `Test-HDTConsoleLineChange`
   allowed an empty collection and not an empty string, and its argument is a
   whole sequence document. Three test files cover that area and the defect sat
   in the gap between them: they exercise the commands, and the button sweep
   skips the five that would have hit it.

### Still open on the console — found 2026-08-27, importing a Dell `.exe`

**The console writes no log at all.** Not a thin one, not a debug one — nothing
in the repository writes a console log. The engine has `HDT.jsonl` and a
numbered file per step; the window beside it has nothing, so when an
administrator says "it crashed" there is no evidence and the only way to answer
is to read the source and guess. That is what happened here. **This is the first
one to fix**, because the other two are the kind of thing a log would have
named in a line.

What it has to record, which is what was wanted and missing on the day: what the
window was asked to do, which command it invoked with which arguments, how long
that took, and the whole exception with its stack when one is thrown - including
the ones already swallowed into a status line, where the message survives and
the type and stack do not.

1. **A long import freezes the window.** `Import-HDTDriverArchive` runs the
   expander through `IProcessService` with a ten-minute timeout, and the console
   calls it on the WPF dispatcher thread. Nothing is marshalled off it. A vendor
   `.exe` that opens a GUI instead of self-extracting blocks for the full ten
   minutes and Windows paints "Not Responding" — but so does a perfectly healthy
   pack of a hundred and forty `.inf` files, for less time. **The freeze is not
   about the `.exe`**; it is every import, and every other long console action
   on the same thread.

2. **Dell's `.exe` switches were never verified.**
   `Get-HDTDriverExpandCommand` hands every `.exe` HP's SoftPaq switches -
   `/s /e /f"dest"` - under a comment asserting "Dell's own .exe packs accept
   the same shape". Nobody ran one. Dell Update Packages take `/s /e=<path>`,
   so a Dell `.exe` gets switches it does not understand and either shows its
   interactive installer or extracts nothing. An unverified claim in a comment
   is exactly what `.planning/SPIKES.md` exists to replace, and this one has
   been sitting in the code being believed.

---

## Post-v1 candidates

Ordered by likely value, all pending the open questions in DESIGN §14:

- `Http` content provider (the interface exists from M4; this fills it in).
- BitLocker **pre-provisioning in WinPE** (encrypt-before-apply; the full-OS
  step ships in M6).
- SQL or REST per-machine settings provider.
- Reference image build pipeline (scheduled patch-and-capture).
- Server OS roles and features.

---

## Sequencing notes

- **M1 and M2 are the ones that must be right.** They encode the model; every
  later milestone is steps plugged into them. Time spent on their tests is
  repaid at every milestone after.
- **M3 lands before M4** deliberately — proving imaging against a VM with local
  content is faster to iterate than debugging through PXE.
- **The console (M8) is last and optional.** If it slips, HDT still ships.
- Each milestone ends with its samples in `samples/` and its docs updated, so
  the design document and the code do not drift apart.
