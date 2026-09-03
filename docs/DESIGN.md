# Hephaestus Deployment Toolkit — Design

**Status:** Draft v0.1 — design only, no implementation yet.
**Date:** 2026-08-12

HDT is a replacement for the Microsoft Deployment Toolkit (MDT), which has been
in maintenance mode since 2019 (last release 8456) and has no supported story
for current Windows releases. HDT keeps MDT's operational model — a deployment
share, task sequences, a driver store, an application catalog — and rebuilds the
engine on PowerShell instead of VBScript/WSH.

---

## 1. Goals and non-goals

### Goals

- **Familiar model.** An admin who knows MDT should recognize every concept:
  deployment share, task sequence, out-of-box drivers, applications, capture.
- **PowerShell all the way down.** No `.wsf`, no `cscript`, no HTA. The engine
  runs in WinPE as PowerShell and is debuggable in the field with a console.
- **Two boot paths from one source.** The same share content produces both a
  PXE-bootable network deployment and a self-contained USB/ISO for sites with no
  server. Standalone media is a *projection* of the share, not a separate build.
- **Config as data.** Task sequences, rules, and catalogs are human-readable
  files that diff cleanly in git. The console edits those files; it does not own
  hidden state.
- **Test-driven.** HDT is built test-first with Pester: a failing test before
  the code that satisfies it, every time. This is a design constraint, not just
  a process one — it forces the engine's decision logic (rule evaluation, driver
  matching, step sequencing, disk layout planning) to be pure and injectable
  rather than reaching for hardware and UNC paths mid-function. See §13.2.

### Deferred to v2 (designed, scheduled out)

These are **fully designed below and not cut** — v2 starts from a written plan.
They are simply not in v1:

- **§7 Driver management — partly built.** There **is** an out-of-box driver
  store now: `New-HDTDriverFolder` and `Import-HDTDriver` fill it, a **selection
  profile** (`Control\selection-profiles.yaml`) names folders in it, and
  `Update-HDTBootImage` injects every folder a profile names — so one boot image
  carries two vendors' WinPE packs, and a machine needing a NIC driver to reach
  the share gets one.

  **This is now built, and the catalog it was waiting for turned out not to need
  an index.** `ConvertFrom-HDTDriverInf` reads a driver out of its own `.inf`;
  `Get-HDTDriverMatch` ranks the store against the ids a machine publishes;
  `ApplyDrivers` injects a group whole and falls back to PnP when no rule
  recognised the model; and the network/mass-storage class filter picks the
  classes a boot image actually needs. `driver-index.json` was never written —
  see §7.
- **§9.3 Capture** and **§6.2 standalone media.** v1 applies images; it does not
  sysprep and capture its own, and it does not project a workspace onto a USB
  stick. `New-HDTBootIso` still ships in v1 — a bootable WinPE ISO is not the
  same thing as offline media carrying the OS and applications.
- **§10.1 Windows Update.** No `WindowsUpdate` step. A machine HDT builds leaves
  the bench with exactly the patches its source image carried; currency after
  that is whatever Windows Update does on its own schedule. The other two
  full-OS steps, §10.2 `InstallRoles` and §10.3 `EnableBitLocker`, **are** in v1.

### Non-goals (v1)

- **User state migration (USMT).** Not deferred — **out of scope permanently.**
  HDT does not capture or restore user state, and has no `ScanState`/`LoadState`
  steps, no state store, and no hardlink-migration path. It deploys machines;
  user data is somebody else's problem (OneDrive Known Folder Move, Enterprise
  State Roaming, or an existing backup product). This is a deliberate scope cut:
  USMT is a large surface area, it is the source of a disproportionate share of
  MDT's failure modes, and it is decreasingly relevant in fleets where profiles
  already sync. HDT targets **bare-metal and wipe-and-load only.**
- **Configuration Manager integration.** HDT is standalone, not an MECM
  companion. No CM task sequence import.
- **Any dependency on MDT itself.** MDT is deprecated; a replacement that still
  requires it installed is not a replacement. HDT ships no MDT component and
  imports none — no `MicrosoftDeploymentToolkit` module or `MDTProvider` drive,
  no `Microsoft.BDD.*` assemblies, no `ZTI*`/`LTI*` scripts, no `ts.xml` or MDT
  `Control\` layout, no MDT database schema. Enforced by a contract test that
  scans `src/` for those identifiers. HDT's only external Microsoft dependencies
  are the **Windows ADK** (DISM, oscdimg, WinPE) and, optionally, the **WDS**
  server role — both supported products independent of MDT.
- **Ongoing patch management.** HDT runs Windows Update *during* a deployment
  (§10.1) so a machine leaves the bench current. It does not manage patching
  after that, and it does not maintain a servicing pipeline for images — that
  belongs to Intune/WSUS/ConfigMgr and to the reference image workflow (§9.3).
- **Non-Windows targets.** Windows client and server only.
- **Multi-tenant / RBAC.** File-share ACLs are the authorization model in v1.

### Explicit constraint: PowerShell 5.1

Anything that runs inside WinPE must be **Windows PowerShell 5.1 compatible**.
WinPE ships .NET Framework, not .NET; PowerShell 7 in WinPE is possible but adds
a large payload and startup cost to every boot image. The engine therefore
targets 5.1 and avoids PS7-only syntax (`??`, `?.`, ternary, `ForEach-Object
-Parallel`). Admin-side cmdlets and the console may assume 5.1 *or* 7 and are
verified against both.

---

## 2. Object model

Seven concepts. Everything else is a property of one of them.

| Concept | MDT equivalent | HDT representation |
|---|---|---|
| **Workspace** | Deployment share | A directory tree + `workspace.yaml` |
| **Operating system** | Operating Systems node | Imported WIM/FFU + `os.yaml` metadata |
| **Task sequence** | Task Sequences node | `sequence.yaml` (ordered steps) |
| **Application** | Applications node | Source folder + `app.yaml` |
| **Driver** | Out-of-Box Drivers | `.inf` set — the files are the catalog (§7) |
| **Rules** | CustomSettings.ini + MDT DB | `rules.yaml` (ordered match/assign) |
| **Media** | Offline Media | Generated ISO/USB output |

### 2.1 Workspace layout

```
\\server\HdtShare\
  workspace.yaml              # share identity, version, defaults
  rules.yaml                  # variable resolution rules (replaces CustomSettings.ini)
  Boot\
    HDTPE_x64.wim             # generated boot image -> WDS
    HDTPE_x64.iso             # same image, mountable -> VM debugging
    HDTPE_x64.manifest.json   # what went into this build
    boot.sdi, bootmgr*        # PXE payload staging
  OperatingSystems\
    Win11-24H2-Ent\
      os.yaml
      sources\                # full ISO extract or install.wim
  TaskSequences\
    STD-CLIENT\
      sequence.yaml
      unattend.xml
  Applications\
    7Zip-24.09\
      app.yaml
      source\
  Drivers\                    # free-form: any names, any depth, yours to shape
    Win11\Dell inc\Latitude 7450\
      <inf tree>              # no generated index - the .inf files ARE it (§7)
  WindowsUpdates\             # MDT's Packages node (§7.5)
    KB5094126-x64\
      update.yaml             # what the package said about itself
      windows11.0-kb5094126-x64_<sha>.msu
  Scripts\                    # user extension points (.ps1)
  Modules\                    # engine payload staged to clients
  Logs\                       # per-deployment logs, if logging to share
  Captures\                   # sysprepped WIMs land here
  Control\
    machines\                 # per-machine variable overrides, <UUID>.yaml (optional)
    os-releases.yaml          # the releases an update can be filed under (§7.5)
```

The engine treats the workspace as **read-only during deployment** except for
`Logs\` and `Captures\`. That means the deployment account needs write access to
exactly two folders — a meaningful improvement over MDT, where the same account
often has broad share rights.

### 2.2 Why YAML

MDT splits configuration across `ts.xml` (machine-generated, painful to merge),
`CustomSettings.ini` (a bespoke INI dialect with an implicit evaluation order),
and a SQL database. HDT uses one format for all authored data. YAML because
task sequences are deeply nested and INI/CSV can't express that, while XML
review diffs are unreadable. Every file has a `schemaVersion` and a JSON Schema
in `schemas/` so the console, CI, and cmdlets validate identically.

---

## 3. Variable and rule engine

This replaces `ZTIGather.wsf` + `CustomSettings.ini` + the MDT database.

### 3.1 Variable sources, in precedence order

1. **Command line / media prompt** — what the media was launched with.
2. **The wizard** — what the technician typed at the machine (§11.2). It beats
   everything below and loses only to the command line: that was set before this
   machine booted, so the wizard could not have known about it, while the person
   who set it could not have known what the wizard would ask. **An empty box is
   not an answer** — a value the technician left blank is skipped rather than
   resolved, or it would silence the rule that would have supplied a real one.
3. **Per-machine override** — `Control\machines\<UUID>.yaml`, if present. This is
   the MDT-database equivalent, but file-based; a SQL or REST provider can be
   plugged in later behind the same interface.
4. **Rules** — `rules.yaml`, first-match-wins per variable (§3.3).
5. **Gathered facts** — hardware, firmware, network (§3.2).
6. **Sequence defaults** — declared in `sequence.yaml`.

Higher entries win. Every variable resolution records *which* source set it,
and that provenance is written to the log — the single biggest debugging pain in
MDT is not knowing why `HDTComputerName` ended up as it did.

### 3.2 Naming: HDT takes MDT's variable set, under its own prefix

HDT provides **the same variables MDT does, meaning for meaning**, so an admin's
existing knowledge and runbooks carry over. But every one is **prefixed `HDT`**:

| Prefix | Meaning | Writable? |
|---|---|---|
| `_HDT*` | Set by the engine | **No** — assigning one is a validation error |
| `HDT*` | Deployment variables: rules, sequences, wizard, per-machine overrides | Yes, unless its row in `Get-HDTVariableMap` says otherwise |

**Why prefix rather than reuse MDT's exact names.** HDT depends on no MDT
component (§1). A variable called `HDTComputerName` that looks like MDT's but is
resolved by a different engine, with different precedence and different
edge-case behaviour, is a trap — it invites an admin to assume semantics that
do not hold. A distinct namespace makes the boundary explicit, keeps HDT
variables from colliding with anything MDT or ConfigMgr leaves in the
environment, and makes `HDT*` greppable in a mixed estate mid-migration.

**Translation table** — the mapping is mechanical, so an MDT runbook converts by
search-and-replace:

| MDT | HDT | MDT | HDT |
|---|---|---|---|
| `OSDComputerName` | `HDTComputerName` | `Make` | `HDTMake` |
| `TaskSequenceID` | `HDTTaskSequenceID` | `Model` | `HDTModel` |
| `JoinDomain` | `HDTJoinDomain` | `SerialNumber` | `HDTSerialNumber` |
| `DomainAdmin`/`DomainAdminPassword` | `HDTDomainAdmin`/`HDTDomainAdminPassword` | `UUID` | `HDTUUID` |
| `MachineObjectOU` | `HDTMachineObjectOU` | `Product` | `HDTProduct` |
| `JoinWorkgroup` | `HDTJoinWorkgroup` | `SystemSKU` | `HDTSystemSKU` |
| `AdminPassword` | `HDTAdminPassword` | `IsDesktop`/`IsLaptop`/`IsServer` | `HDTIsDesktop`/`HDTIsLaptop`/`HDTIsServer` |
| `Applications` | `HDTApplications` | `IsVM` | `HDTIsVM` |
| `SkipWizard` and `Skip*` | `HDTSkipWizard`, `HDTSkip*` | `Architecture` | `HDTArchitecture` |
| `DeployRoot` | `_HDTDeployRoot` | `IsUEFI` | `HDTIsUEFI` |
| `WSUSServer` | `HDTWSUSServer` | `Memory` | `HDTMemory` |
| `DriverGroup` | `HDTDriverGroup` | `MacAddress`/`IPAddress`/`DefaultGateway` | `HDTMacAddress`/`HDTIPAddress`/`HDTDefaultGateway` |
| `_SMSTSLogPath` | `_HDTLogPath` | `TimeZoneName` | `HDTTimeZone` |
| `ProductKey` | `HDTProductKey` | `AssetTag` | `HDTAssetTag` |
| `MandatoryApplications` | `HDTMandatoryApplications` | `FinishAction` | `HDTFinishAction` |
| `TaskSequenceName` | `HDTTaskSequenceName` | `TaskSequenceVersion` | `HDTTaskSequenceVersion` |
| `_SMSTSOrgName` | `HDTBrandingName` | | |

**Where HDT keeps one name and MDT keeps two.** `OverrideProductKey` exists in
MDT because a task sequence could carry its own key and a rule needed a way to
beat it. §3.1's precedence already answers that — a rule outranks a sequence
default — so a second name would be a second way to say the same thing, and the
pair is exactly where an MDT admin loses an afternoon.

**`HDTProductKey` unset removes the element rather than emptying it.** Windows
reads `ProductKey` in the specialize pass; an empty element fails the pass, and
so does a literal `%HDTProductKey%`. No element at all is how every KMS, MAK-by-
script and LTSC deployment has always run, so that is what an unsupplied key
produces. A template that hard-codes a key and never names the variable is left
alone — only the element still holding the unresolved token goes.

**`HDTFinishAction` is decided by `Get-HDTFinishAction`, not by either payload.**
`REBOOT`, `SHUTDOWN`, `LOGOFF` or `NONE`; `RESTART` is accepted for `REBOOT`
because that is the word this engine uses everywhere else. A value nobody meant
does nothing and warns — a typo resolving to the nearest match would power off a
machine somebody was about to work on, and refusing would turn a deployment that
succeeded into a failed one at the very last step. On the WinPE leg it applies
only to a `Succeeded` run: `RebootPending` means the machine is going back into
what it just built, and a finish action honoured there would leave an imaged
machine that never ran a full-OS step.

**`HDTMandatoryApplications` does not jump the queue**, which is where HDT parts
company with MDT. MDT installs its mandatory list first because it processes two
lists in two loops; `Resolve-HDTApplicationOrder` emits ready applications
smallest id first precisely so a plan does not depend on the order a selection
was written in. A site that needs its agent before everything else declares a
dependency edge.

**`HDTDeploymentType` and `HDTDeploymentMethod` are two questions, not one.**
MDT declares both in `ZTIGather.xml` and HDT carries both:

| MDT | HDT | Answers | Values |
|---|---|---|---|
| `DeploymentType` | `HDTDeploymentType` | *what* is being done | `NEWCOMPUTER` — this engine performs bare-metal installs only |
| `DeploymentMethod` | `HDTDeploymentMethod` | *how this machine reached its content* | `UNC` from a share, `MEDIA` from the disc or stick it booted from |

They are independent, and the trap is assuming they are not: **a media
deployment is still `NEWCOMPUTER`**. MDT's `LiteTouch.wsf` decides the method by
walking every ready drive looking for its media marker and defaulting to `UNC`
when it finds none; HDT decides it from the provider `bootstrap.json` already
names, through `Get-HDTDeploymentMethod`, so the value cannot disagree with the
provider actually in use — a stale marker on a second disk cannot talk a
deployment out of the network it is really reading from.

MDT also has `OSD` and `SCCM`. HDT has neither: those describe an MECM
deployment, and §1 takes no dependency on MECM, so **two values is the whole
set.**

**`HDTDeploymentMethod` is the one writable-looking name that is not writable.**
It carries no underscore — MDT's name is `DeploymentMethod` and a step condition
reads `%HDTDeploymentMethod%` — so the `_HDT*` prefix cannot say it and the map
row does instead, through an explicit `Writable = $false`.
`Assert-HDTRuleDocument` refuses **every name the map marks not writable**,
rather than a list of names written into the validator, so the next
engine-published variable is refused the day its row lands. A `rules.yaml` that
declared `MEDIA` on a share would produce a deployment that skips the network it
is using, and every symptom of that points somewhere else.

HDT-specific additions with no MDT equivalent: `HDTSecureBootEnabled`,
`HDTTPMVersion`, `HDTBootMode` (`PXE` | `Media`), `HDTDiskLayout`,
`HDTImageIndex`, `HDTUnattendPath`.

**Published by an imaging step**, rather than gathered or authored — nothing can
know `HDTOSVolume` before the disk has been partitioned. They are ordinary
writable `HDT*` names, so a later step or a condition composes on them normally:

| Variable | Set by | Meaning | MDT |
|---|---|---|---|
| `HDTTargetDisk` | `DiskPartition` | the disk number that was partitioned | `OSDDiskIndex` |
| `HDTSystemVolume` | `DiskPartition` | the ESP / System Reserved drive letter | `BootVolume` |
| `HDTOSVolume` | `DiskPartition` | the Windows drive letter | `OSVolume` |
| `HDTRecoveryVolume` | `DiskPartition` | the recovery drive letter, or empty | `RecoveryVolume` |
| `HDTImageIndex` | `ApplyImage` | the index that was applied | — |
| `HDTUnattendPath` | `ApplyUnattend` | where the unattend was staged | — |

`Get-HDTVariableMap` prints this table at runtime, and a contract test asserts
every documented MDT name has exactly one HDT counterpart, so the mapping cannot
silently drift.

### 3.2.1 Gathered facts

Collected once at engine start in WinPE, refreshed after OS apply.

Source: CIM — `Win32_ComputerSystem`, `Win32_ComputerSystemProduct`,
`Win32_BaseBoard`, `Win32_BIOS`, `Win32_Tpm` — plus firmware detection from
`$env:firmware_type` and the `SecureBoot` registry path.

**Network facts come from `Win32_NetworkAdapterConfiguration`, not
`Get-NetIPAddress`.** WinPE has no `NetTCPIP`/`NetAdapter` module (§5.1,
verified in SPIKES.md S1), so `HDTMacAddress`, `HDTIPAddress` and
`HDTDefaultGateway` are gathered via CIM and configured via `netsh`. This is the
same reason `PSDGather.ps1` uses WMI.

**Those three are the multi-valued facts, and they stay lists.** A machine has
as many addresses as it has adapters, and `Test-HDTRuleMatch` matches a list on
**any element** — which is what lets `when: { HDTDefaultGateway: "10.20.30.1" }`
fire on a machine whose second adapter carries that gateway. **As text they are
comma-delimited**, everywhere and by one command
(`ConvertTo-HDTVariableText`): the `%Var%` substitution, the `var.resolve` log
line, the HTML report cell and the unattend value all read the same rendering,
so what a technician sees is what a rule matched. This is MDT's own shape for a
gathered adapter fact — `ZTIGather.xml` declares `OSDAdapter0IPAddressList`,
`OSDAdapter0Gateways` and `OSDAdapter0DNSServerList` as `type="string"`,
described "Comma delimited list", and reserves `type="list"` — the shape that
surfaces as `Applications001`, `Applications002` — for authored inputs such as
`Applications` and `DriverPaths`. **HDT therefore has no numbered
`HDTIPAddress001`**, and a value must never reach a person as `System.Object[]`;
the provenance export keeps the real JSON array, because that one is read by a
machine.

### 3.3 rules.yaml

```yaml
schemaVersion: 1
rules:
  - name: Lab subnet
    when: { HDTDefaultGateway: "10.20.30.1" }
    set:
      HDTJoinDomain: lab.contoso.com
      HDTTaskSequenceID: LAB-CLIENT
      HDTSkipWizard: true

  - name: Latitude naming
    when: { HDTModel: "Latitude*", HDTIsLaptop: true }   # wildcards allowed
    set:
      HDTComputerName: "LT-%HDTSerialNumber%"
      HDTDriverGroup: "Dell\\%HDTModel%"

  - name: Fallback
    set:
      HDTComputerName: "PC-%HDTSerialNumber%"
      HDTJoinWorkgroup: WORKGROUP
```

Evaluation: rules are walked top to bottom; a rule applies if every `when` key
matches. A `set` key only takes effect if that variable is **not already
resolved** — so first match wins per variable, and later rules act as
fallbacks. `%Var%` expands against already-resolved variables.

This is deliberately less powerful than `CustomSettings.ini`'s
`Priority=`/section-chaining, which almost nobody fully understands. If a rule
needs real logic, it calls a script: `setFrom: Scripts\Get-ComputerName.ps1`,
whose stdout object becomes the variable set.

---

## 4. Task sequence engine

### 4.1 sequence.yaml

```yaml
schemaVersion: 1
id: STD-CLIENT
name: Standard Windows 11 Client
description: Bare-metal client build
variables:
  HDTOSImage: Win11-24H2-Ent
  HDTDiskLayout: uefi-standard
steps:
  - group: Preinstall
    steps:
      - name: Validate
        type: Validate
        minRamMB: 4096
        minDiskGB: 60
      - name: Format and Partition
        type: DiskPartition
        layout: uefi-standard
        wipe: true

  - group: Install
    steps:
      - name: Apply OS
        type: ApplyImage
        os: "%HDTOSImage%"
        index: 3
        target: primary
      - name: Inject Drivers
        type: ApplyDrivers
        group: "%HDTDriverGroup%"
        fallback: match-pnp        # index lookup if no group matches
      - name: Apply Unattend
        type: ApplyUnattend
        template: unattend.xml
      - name: Prepare Boot
        type: ConfigureBoot

  - group: State Restore
    condition: '"%_HDTPhase%" == "FullOS"'
    steps:
      - name: Join Domain
        type: JoinDomain
        domain: "%HDTJoinDomain%"
        ou: "%HDTMachineObjectOU%"
        continueOnError: false
      - name: Install Applications
        type: InstallApplications
        selection: "%HDTApplications%"
      - name: Windows Update
        type: WindowsUpdate
        continueOnError: true
      - name: Custom
        type: PowerShell
        script: Scripts\Set-CorpBaseline.ps1
        runIn: FullOS
```

Three details in that document are load-bearing rather than stylistic, and each
was corrected in M2 after the parser and the condition grammar existed:

- **Every variable is `HDT`-prefixed** (§3.2), and the schema enforces it. The
  first draft of this example wrote `OSImage`, which no workspace can use.
- **A condition is a single-quoted YAML scalar.** The grammar carries double
  quotes as part of itself (`"%A%" == "B"`), so an unquoted mapping value ends
  the scalar at the first quote and every YAML parser rejects the line.
- **`_HDTPhase` is `WinPE` or `FullOS`** (§4.4.1). The first draft compared it to
  `"OS"`, which never matched anything and would have silently skipped the whole
  State Restore group.

`samples/workspace/TaskSequences/STD-CLIENT/sequence.yaml` is this sequence as a
file that imports and validates today.

### 4.2 Step types (v1)

`Validate`, `DiskPartition`, `ApplyImage`, `CaptureImage`, `ApplyDrivers`,
`ApplyUnattend`, `ConfigureBoot`, `BootToWinPE`, `Restart`, `PowerShell`,
`CommandLine`, `InstallApplications`, `InstallRoles`, `JoinDomain`,
`SetVariable`, `WindowsUpdate`, `Sysprep`, `EnableBitLocker`, `ApplyUpdates`.

`ApplyUpdates` and `WindowsUpdate` are different steps and the names are close
enough to be worth separating here too: `ApplyUpdates` injects imported `.msu`
packages into the applied volume offline, in WinPE (§7.5); `WindowsUpdate` is
the online full-OS step against WSUS, and is deferred to v2 (§10.1).

`BootToWinPE` is the FullOS -> WinPE transport, and it exists because one
firmware-order switch cannot serve two restarts that want opposite things. A
reference build restarts once into Windows and once into WinPE;
`ConfigureBoot`'s `setBootOrder` can only satisfy one. It stages a WinPE onto
the local disk under \HDT\Boot, adds a ramdisk BCD entry for it and arms
`bcdedit /bootsequence` - so the firmware order is left alone and the Windows
Boot Manager hands out exactly one boot. Its `action` is `stage`, `arm` or
`remove`; the first two run before `Sysprep` and fail the sequence rather than
sealing a machine that cannot come back.

Each step type is a set of functions discovered **by name**. Third-party step
types can be dropped into `Modules\` — the engine discovers them by convention,
so extending HDT does not mean forking it.

**The convention, as implemented (M2).** For a step type `Foo`:

| Function | Required | Contract |
|---|---|---|
| `Invoke-HDTFooStep` | **yes** | `-Step`, `-Context`; returns a `New-HDTStepResult` |
| `Test-HDTFooStepApplicable` | no | `-Step`, `-Context`; `$false` skips the step |
| `Get-HDTFooStepDescription` | no | `-Step`; one line for the log and the console |

A type exists exactly when `Invoke-HDT<Type>Step` is exported by a loaded
module, and `Get-HDTStepType` refuses to run when two modules export the same
type — an ambiguous step type is a configuration error, not a race.

**The result contract** is closed: `Completed`, `Failed`, or `RebootRequested`.
`RebootRequested` is what triggers the §4.5 reboot ceremony, so an installer
returning `3010` and a `Restart` step take the same path through the engine.

These names are a compatibility surface for anyone writing a step type, which is
why they are in the design rather than only in the code.

Common properties on every step: `name`, `condition`, `continueOnError`,
`timeoutMinutes`, `runIn` (`WinPE` | `FullOS` | `Any`), `retry`, `resumable`,
`log`.

### 4.3 Execution and reboot resume

The hard part of any task sequence engine is surviving reboots, including the
one where the OS changes out from under you.

- The engine maintains a **state document** (`state.json`): resolved variables,
  the step index, per-step results, and a run ID.
- Location by phase: WinPE → `X:\HDT\state.json`, mirrored to the target disk's
  `\HDT\` as soon as a formatted volume exists. Full OS → `C:\HDT\state.json`.
  The mirror is what makes the WinPE→OS transition survivable.
- **Resume in the full OS** uses **autologon as the local Administrator**, the
  MDT model, so the sequence continues in a real interactive session. See §4.5
  for the mechanism and its lifecycle.
- **Resume back in WinPE** is a *scan*, not a boot flag — see §4.3.1. It is what
  lets one sequence deploy, customize in the full OS, sysprep, and capture.
- Every step is **idempotent or checkpointed**. On resume the engine skips
  completed steps by index and re-runs the interrupted one only if the step
  declares `resumable: true`.
- **A step that owns a list can ask to be re-entered.** A step returning
  `RebootRequested` is normally recorded `Completed`, which advances the step
  index past it — correct for a `Restart` step, and wrong for an
  `InstallApplications` step (§8) that receives a `3010` halfway down its list:
  the applications after it would be silently skipped and the run would report
  success having installed half the software. Such a step returns
  `New-HDTStepResult -Reenter`, and the engine records it **`Pending`** instead,
  leaving the step index where it is. The reboot ceremony is otherwise
  unchanged; the next leg runs the step again, and the step resumes from
  progress it checkpointed into a variable — variables being part of the state
  document. It is opt-in because the default is right for every other step: a
  `Restart` step that re-entered would reboot forever.
- Failure ends the sequence, writes a failure report, and — if
  `PauseOnError` — leaves the state loaded so the technician can inspect it on
  the machine that failed. This is the MDT `LTISuspend` idea, generalized.

**Two limitations, both discovered in M2 and both deliberate:**

- **`timeoutMinutes` is not pre-emptive.** It is passed to the step — only
  `CommandLine` can enforce it, through `IProcessService`, which kills the
  process — and is otherwise measured by the loop *after* the step returns, so an
  overrun becomes a `Failed` result carrying `TimedOut`. HDT does not preempt a
  synchronous step: one that hangs in-process hangs the sequence, exactly as
  MDT's does. Running steps in a child runspace is a post-v1 idea, and
  `ForEach-Object -Parallel` is not available to an engine that must run under
  Windows PowerShell 5.1.
- **`PauseOnError` does not open a prompt.** The loop logs at `Error` that the
  run is paused, writes the heartbeat and returns with the state loaded and
  saved; dropping to a live prompt belongs to the caller (`Start-HDTDeployment`).
  An engine that blocked on input could not be unit tested and would hang CI.

#### 4.3.1 Resuming back into WinPE

The full-OS→WinPE direction is what a reference build needs between `Sysprep`
and `CaptureImage`, and it is a *different problem* from the WinPE→full-OS one.
Going forward, the engine arms the machine to come back to it. Coming back,
nothing was armed: the WinPE entry point simply ran, and it used to mint a new
run at step 1 every time — so the capture boot started the sequence again, at
the `DiskPartition` step, against the volume it had just sealed.

**Two questions, and conflating them is the trap:**

| | |
|---|---|
| **Transport** | how the machine ends up running WinPE |
| **Discovery** | how the engine learns a run is already in progress |

MDT answers transport with `bcdedit /bootsequence` pointing at a `boot.wim`
staged on the local disk (`ZTIBCDUtility.vbs` → `AdjustBCDDefaults`, called from
`LTIApply.wsf /PE /BCD`). That is **not** discovery: `/bootsequence` is consumed
by the boot manager before any deployment code runs, so the booted image cannot
ask whether it arrived that way. MDT knows this — which is why it *also* stages
`C:\MININT` and looks for it. (Nor is it self-cleaning, despite the name:
`AdjustBCDDefaults` sets `/bootsequence` **and** `/default` **and**
`/displayorder /addfirst`, and `LTICleanup.wsf` has to delete the entry
explicitly afterwards. PSD has no equivalent at all — its capture path is an
acknowledged stub.)

**HDT keys discovery to the disk, not the transport.** `Get-HDTResumeCandidate`
scans the lettered volumes through `IDiskService` for `\HDT\state.json` — the
document §4.3 already mirrors onto the OS volume. A machine that reached WinPE by
a one-shot boot entry, by PXE, by an ISO left in the drive, or because somebody
pressed F12 gets the same, correct answer; a transport-keyed check would answer
correctly for one of those four and format the disk for the other three. It reads
the state document rather than a marker of its own, because a separate marker is
a second source of truth about whether a run is live, and the case where the two
disagree is a wiped disk.

**It answers three ways, where the full-OS reconcile (§4.5.4) answers two.** That
asymmetry is the whole safety property. `Invoke-HDTBootReconciliation` collapses
"cannot tell" into *Teardown*, which is right in the full OS — the worst case of
being wrong is a machine that does not log itself on. Here, "there is no run"
means "mint one and start at step 1", and step 1 of a deployment sequence formats
a disk.

| Found | Answer |
|---|---|
| no state document on any volume | `None` — deploy normally |
| one, readable, `Running`, fresh | `Resume` |
| one, `Succeeded`/`Failed` | `None` — the run is over, this is a new deployment |
| unreadable, or not valid JSON | **`Ambiguous` — refuse** |
| two or more volumes carry one | **`Ambiguous` — refuse** |
| `Running` but stale past `MaxAgeHour` | **`Ambiguous` — refuse** |
| the volumes cannot be listed | **`Ambiguous` — refuse** |

A **half-written state document is a crashed run, not an absent one**, and is
never read as "start from the beginning". The stale case is the one deliberate
divergence from §4.5.4, which tears a stale run down: an abandoned run and a live
one are indistinguishable to a clock that has skewed, and WinPE's does. Every
refusal names the file, because the operator's way out is to delete it — an
explicit act of consent in a way that "it started a new deployment" is not.
`X:` is never scanned: it is the RAM disk, new on every boot, so it cannot carry
a run across one.

**And a resumed leg cannot reach a destructive step.** `Invoke-HDTTaskSequence
-Resumed` refuses `DiskPartition` and `ApplyImage` outright — the step types that
would destroy the installation the run exists to finish. The guard runs *before*
the already-completed check, deliberately: that check consults the same state
document, so a guard placed after it would find a corrupt `stepIndex`'s step
recorded `Completed`, skip it, and be dead code in exactly the case it exists
for. It **fails** rather than skipping, because a resumed leg that reaches one of
these has a defect in it and a skip is how that stays invisible.

**A resumed leg also refuses to run in the wrong phase.** If the step at
`stepIndex` cannot run in this leg's phase, the machine booted into the wrong
environment and the run stops rather than skipping forward. Narrow on purpose —
a phase skip in the *middle* of a sequence is legitimate — and it closes a
failure that resume itself creates: a reference build whose restart 1 lands back
in WinPE would otherwise skip `Customize`, `Sysprep` and the second restart by
phase filter, go straight to `CaptureImage`, capture a machine that was never
prepared, and report success.

*Revised 2026-08-31. This paragraph previously said the transport below was "not
yet built" and that the reference template got back to WinPE with
`setBootOrder: false`.* Both are now wrong. `setBootOrder: false` was measured on
2026-08-31 to send restart 1 back into WinPE, stopping the build there, and the
transport that replaced it is `BootToWinPE` (§4.2, §9.3): a locally staged WinPE
plus a one-shot boot entry, MDT's own answer. **One firmware-order switch cannot
serve both restarts** — restart 1 must reach Windows, restart 2 must reach WinPE
— and that tension does not dissolve by choosing a side; it dissolves by the
machine no longer depending on the firmware order to return to WinPE. Staging a
local `boot.wim` and pointing `bcdedit /bootsequence` at it is what buys that, so
`setBootOrder` is back to `true` on the reference sequence like every other.
Discovery is deliberately independent of the transport, so this changed nothing
above.

### 4.4 Logging

Logging is a first-class feature, not a side effect. MDT's logging is the part
admins actually live in during a failed deployment, and HDT must be at least as
good — detailed, per-step, and extensible by whoever writes a custom step.

#### 4.4.1 `_HDTLogPath` and the engine variables

**`_HDTLogPath` is the single canonical log directory**, set by the engine and
available to every step, every condition, and every user script. Nothing writes
a log anywhere else.

The leading underscore follows MDT's convention (`_SMSTSLogPath`): variables
prefixed `_` are **set by the engine and read-only** — a sequence or rule that
tries to assign one is a validation error, not a silent override. The full set:

| Variable | Meaning |
|---|---|
| `_HDTLogPath` | Current log directory (moves with the phase, see below) |
| `_HDTRunId` | Unique id for this deployment run |
| `_HDTPhase` | `WinPE` or `FullOS` |
| `_HDTStepName` / `_HDTStepType` | The executing step |
| `_HDTDeployRoot` | Resolved workspace root |
| `_HDTVersion` | Engine version |

`_HDTLogPath` follows the deployment rather than staying put:

| Phase | Value |
|---|---|
| WinPE, before a disk exists | `X:\HDT\Logs` |
| WinPE, after the target volume is formatted | `<target>\HDT\Logs` (mirrored, so the WinPE→OS transition keeps history) |
| Full OS | `C:\HDT\Logs` |
| On phase end and on failure | copied to `<share>\Logs\<ComputerName>-<RunId>\` |
| While the run happens | mirrored line by line to `<HDTSLShareDynamicLogging>\<RunId>\` |

Copy-back happens **on failure too** — a deployment that dies is exactly when
the logs matter, and MDT's habit of stranding them on a wiped machine is a real
operational problem.

**The live mirror rolls per run, and the run folder is what makes it one file
across the reboot.** `HDTSLShareDynamicLogging` is MDT's `SLShareDynamicLogging`
and resolves to a folder per *machine* — the shipped rule is
`\\<host>\<share>\Logs\%HDTComputerName%`. Every mirrored line is an append and
nothing rolls or truncates, so a single `HDT.log` there accumulated every
deployment that machine had ever had: the real one in this lab held 206 CRLF and
253 bare LF, a pre-CRLF-fix run and a post-fix one in one file, and CMTrace
could parse neither half cleanly.

So `New-HDTLogContext`'s `SetDynamicPath` composes a folder named for the run
underneath whatever the rule resolved, giving
`Logs\LT-7FJ45S2\run-20260829-151848\HDT.log`. **Roll, never truncate** —
truncating destroys the previous run's evidence at exactly the moment somebody
re-runs *because* the last one failed — and never size-based, because capping
splits one deployment across two files and a deployment is the unit anybody
reads.

**It is keyed on the run id, which is the one thing that survives the restart.**
`Start-HDTDeployment` mints it, `state.json` carries it over, and
`Start-HDTResume` builds its own log context with `$state.runId` — so both legs
compose the identical path and append to one file. Keyed on anything the reboot
changes — the phase, the log root, the clock — it would produce two half-logs
and look like it worked. Neither payload composes the folder; they hand the
resolved rule value to `SetDynamicPath` and prepare `$log.DynamicPath`, so there
is one place that knows the shape and no second one to keep in step.

Rolling turns one unbounded file into one small folder per re-image, and nothing
prunes them. That is deliberate: a deletion policy that ran on a share is a
deletion policy that can lose the log somebody was about to read.

**The relocation is a mirror, the loop owns it, and it never fails a run.**
`Set-HDTLogPath` copies everything already written — `HDT.log`, `HDT.jsonl`,
`status.json`, `Steps\`, `Gather\`, `Native\` — onto the target volume and
repoints the live context there; the RAM-disk copy **stays**, because a move that
failed halfway would have destroyed the only log it was called to preserve. It is
triggered by `Invoke-HDTTaskSequence`, not by the partition step: a step does not
own the log context, and the loop is the one place that sees every step finish.
Four conditions must hold — the phase is `WinPE`, `HDTOSVolume` is now non-empty,
the log is still on the RAM disk, and the step that just ran reported
`Completed`. `seq` (§4.4.2) is **not** reset by the move; it is monotonic across
the whole run and restarting it would be exactly the ambiguity the counter exists
to prevent. A destination that cannot be written — full, unformatted after all, a
letter that went away — produces a `Warning` record through the old context,
leaves everything pointing at `X:`, and the run continues: losing the logs is not
an acceptable price for moving the logs. The state document's mirror (§4.3) is
pointed at `<target>\HDT\state.json` at the same moment and by the same trigger,
because it is the same information — and a caller who passed `-MirrorStatePath`
or `-StatusPath` explicitly is not overruled.

#### 4.4.2 Two formats, one write

Every log call emits both, from a single `Write-HDTLog` invocation:

- **`HDT.log` — CMTrace format.** MDT admins have CMTrace/OneTrace open already
  and know how to read it. Emitting the same format means their existing
  workflow, filtering and error-highlighting work on day one. Deliberately not
  a new thing to learn.
- **`HDT.jsonl` — JSON Lines.** The structured source of truth: timestamp,
  run id, phase, step name and type, status, duration, severity, message,
  component, thread, and variable-provenance events (§3.1). This is what
  `ConvertTo-HDTReport` renders to HTML and what the console's monitoring view
  consumes.

Both are **UTF-8 with no byte order mark**, written through
`[System.IO.File]::AppendAllText`. (A spike wrote UTF-16 by accident via
`Tee-Object`'s default encoding and the result was unreadable in half the
tooling; `Set-Content -Encoding UTF8` emits a BOM under Windows PowerShell 5.1
and none under pwsh 7, which would put one in exactly the files a parser reads.
The log writer sets the encoding explicitly and both cmdlets are banned in it.)

**The report.** `ConvertTo-HDTReport` renders the JSONL to **one self-contained
HTML file** — inline CSS, no script, no CDN, no external font — because a report
is read from a USB stick, from a share, and from a machine with no network. It
parses **line by line**: a blank line is ignored and a line that does not parse
is counted and reported *in the report*, never thrown, because a truncated final
line is the normal state of a log from a machine that died and that is exactly
when somebody renders one. Everything is HTML-escaped, and the deployment
password cannot appear: the report is built from the JSONL, which never carries
it, and from the state document, from which it reads only the status, the leg and
the step records.

**Directory structure.** Fixed and predictable, so a human and a parser can both
find things without searching:

```
<_HDTLogPath>\
  HDT.log                     master, CMTrace format
  HDT.jsonl                   master, structured
  status.json                 current step heartbeat
  state.json                  the run state document (4.3)
  Steps\
    001-Validate.log          per step, numbered in execution order
    002-DiskPartition.log
    003-ApplyImage.log
    003-ApplyImage.dism.log   native tool output, kept beside its step
    ...
  Gather\
    facts.json                resolved facts (3.2)
    provenance.json           every variable + which source set it (3.1)
    devices.json              every PnP device and its hardware ids
  Native\
    dism-<timestamp>.log      raw tool logs, unparsed
    setupact.log              collected from the target where relevant
```

`devices.json` is the one fact gather never recorded. The twenty facts in
`facts.json` are what a *rule* matches on — make, model, serial, chassis,
firmware — and **not one of them is a hardware id**. Make and model tell an
administrator which driver *pack* to fetch; the hardware id is the only thing
that identifies the specific device that did not come up, so a deployment that
finished with no network card could be diagnosed as far as "it is a Latitude
5490" and no further.

It is a **file rather than variables**, deliberately: a machine reports dozens of
devices with several ids each, and as engine variables that would bury the twenty
facts a rule reads under a hundred nothing matches on. This is also MDT's shape —
`ZTIDrivers.wsf` shells `Microsoft.BDD.PnpEnum.exe` and writes `PnpEnum.xml` into
its log directory for the same reason. HDT differs twice, and both are
deliberate: it is written **at gather** rather than inside the driver step, so it
survives a run that dies before drivers (MDT's does not); and it comes from
`Win32_PnPEntity` through `ICimProvider` rather than a compiled enumerator,
because that binary is an MDT dependency. Hardware ids come from **bus
enumeration**, not from a driver, so a device with no driver at all still
publishes its id — which is why the file is trustworthy in WinPE (SPIKES S19).

It deliberately records **no problem state**: WinPE's view of "this device has no
driver" is a fact about WinPE's driver set, not about the Windows being deployed,
and recording it would flag a dozen devices on every healthy machine.

Step files are **numbered in execution order**, so the directory listing itself
tells you the sequence and where it stopped — the thing you want first when a
deployment fails.

**JSONL record schema.** Every line is one object, same shape throughout:

```json
{
  "ts":        "2026-08-13T00:11:02.481Z",
  "runId":     "8f3c1a90-...",
  "seq":       417,
  "level":     "Info",
  "phase":     "WinPE",
  "clockUnsynced": true,
  "stepIndex": 3,
  "stepName":  "Apply OS",
  "stepType":  "ApplyImage",
  "component": "ImageService",
  "event":     "step.complete",
  "message":   "Applied index 1 to W:\\ in 95s",
  "durationMs": 95120,
  "data":      { "index": 1, "target": "W:\\", "wim": "...\\install.wim" }
}
```

`event` is a controlled vocabulary, so the report renderer and the console filter
on a known set rather than regexing prose. **The table below is exactly what
`Write-HDTLog`'s `ValidateSet` accepts** — the two are asserted against each
other in both directions by a test, because a "controlled" vocabulary the
document and the engine disagree about is not controlled.

**The count is deliberately not written here.** It said "thirteen" while the
table held twenty-two: the test enforces the *names*, nobody enforces a number
in a sentence, and a number in prose beside an enforced table is a number that
drifts. Count the rows.

| Event | Written when |
|---|---|
| `run.start` | a leg begins |
| `run.end` | a leg ends, whatever the outcome |
| `phase.change` | the leg's phase differs from the state document's |
| `step.start` | **each attempt** of a step begins |
| `step.complete` | a step finished successfully |
| `step.fail` | a step failed, or the loop itself did |
| `step.skip` | a step was skipped, with the reason |
| `step.progress` | a long step said how far through itself it is (`data.percent`), **or** that it is still alive when it has no percentage to give (`data.heartbeat = true`, and no `percent` — so a liveness record cannot drag a bar backwards). Every record carries one mark or the other: the absence of a field is not something a reader can filter on |
| `var.resolve` | a variable **took** a value, with its source: a rule resolution, a `SetVariable` step, or a gathered fact — one grammar, `Name = 'value' (Source)`, and `data.source` tells them apart |
| `var.unresolved` | a variable did **not**: a `%Var%` nothing supplied, a fact the machine could not determine, or a resolved value kept because the gather's answer was a non-answer |
| `native.exec` | an external command line was run |
| `reboot.arm` | autologon was armed before a restart (§4.5) |
| `reboot.resume` | the boot reconcile resumed a run |
| `reboot.teardown` | the §4.5.4 teardown checklist ran |
| `driver.group` | the driver group a rule resolved, and whether it was on the share |
| `driver.fallback` | group match did not apply, with the reason PnP matching was used instead |
| `driver.enumerate` | how many devices the machine reported hardware ids for |
| `driver.match` | a driver was chosen, with the id it matched, the rank, and the device |
| `driver.staged` | a driver package was copied to the machine, with how many files |
| `update.apply` | one Windows update was applied offline, with its KB, the release it was filed under, dism's exit code and the outcome — one record per package, never one summary for the pass |
| `console.session` | the admin console opened or closed, with its version |
| `console.action` | the console invoked a command, with its name, parameter names and duration |
| `console.error` | a console action threw, with the exception type and stack |
| `message` | the default: any `Write-HDTLog` call that names no event, which is every custom step's log line under §4.4.4 |

**The console logs to the administrator's machine, not to the share.** Its three
events go to `%LOCALAPPDATA%\Hephaestus\Logs`, in the same two formats as
everything else, because a console opens many shares, opens them read-only, and
starts before one is chosen — so a log on the share cannot record the failure to
reach the share, which is the failure most worth recording. `console.action`
records the command name, its **parameter names and never their values**, and
how long it took: the console is where the local administrator password is set,
and a log that helpfully recorded every argument would be the one place that
password came to rest in plain text.

**Why variables get two names and not one, and not four.** `var.resolve` had
three writers — `Write-HDTVariableLog`, `Invoke-HDTSetVariableStep` and
`Invoke-HDTGatherStep` — in two grammars and at two severities, and it also
carried three things that are not resolutions at all: a `%Var%` nothing
supplied, a fact the machine could not determine, and a resolved value the
gather declined to overwrite. A name that means several things cannot be
filtered on, which is the whole purpose of a controlled vocabulary.

The split is **by claim, not by writer**. A rule resolution, a step assignment
and a gathered fact all assert the same thing — *this variable took this value* —
so they keep one name, one grammar, and `data.source` (`Rule`, `Step`, `Gather`,
or one of §3.1's five prioritised sources) as the discriminator: "where did
`HDTComputerName` come from" is then one filter and one field, not three names a
consumer has to know about. Giving each writer its own name would grow the
vocabulary with every writer added and make the common question harder to ask.

The non-resolutions assert the *opposite*, so they get `var.unresolved`. That is
not pedantry: `ConvertTo-HDTReport` is the only consumer in `src/` that filters
this event and it renders `data.name`, `data.value` and `data.source` as a row of
the report's Variables table — so every one of those records, most of which
carried no `data` at all, drew a blank row in the report somebody sends on.

Severity is *not* part of the split and is deliberate on each writer: a rule
resolution is Debug (§4.4.2's "Debug adds every variable resolution with its
provenance"), a `SetVariable` step is **Info** because an authored mid-sequence
assignment is a decision somebody made rather than a derivation, and an
unexpanded `%Var%` is **Warning** so it survives a run that is not in Debug.

**Why drivers get five names of their own.** Every other step reports what it
did; `ApplyDrivers` has to report what it *decided*, because the two most common
driver complaints — "this model got no drivers" and "this machine got the wrong
one" — are questions about a choice, not about an outcome. A group that resolved
to a folder nobody created, a fallback nobody expected, and a pack that won on
version rather than specificity all look identical in a log that records only
"drivers injected". They are separate events rather than one `driver.*` with a
sub-type so that a filter can pull just the matches out of a deployment that
made two hundred of them. This is MDT's `ZTIDrivers.log` restated as structure:
the same facts, filterable rather than greppable.

`data` carries step-specific detail without polluting the top level.

`seq` is a monotonic counter that **survives reboots**, so the ordering of a
multi-leg deployment is unambiguous even when timestamps skew across a clock
change during specialize.

**`clockUnsynced`.** WinPE boots with an unsynchronised clock — measured at
`14:31` while the host running it was at `00:31`. So a WinPE-phase timestamp is
present, correctly formatted, and *wrong*, and because `ts` is written as UTC a
reader cannot tell it is unreliable. Worse, the CMTrace `date` field inherits
the same skew, so a deployment's WinPE leg can appear on the wrong day entirely.

Every record therefore carries a boolean `clockUnsynced`, true while the engine
has no evidence the clock is trustworthy — set in WinPE, cleared once the full
OS has synchronised. `ConvertTo-HDTReport` marks those rows rather than
presenting them as fact.

**The CMTrace log announces it once, and does not repeat it.** The first build
suffixed `(clock unsynced)` to every message, and because WinPE's clock is
unsynchronised for the *whole* of the WinPE leg that fired on 93 records out of
93 on a real machine — a column of noise down the log rather than a marker, and
a log materially harder to read for it. So `Write-HDTLog` writes one entry of
its own, `Clock not synchronised: the timestamps that follow are WinPE's own,
not the deployment's - ordering comes from seq`, at the point the answer first
becomes true, and a matching `Clock synchronised: …` entry if it ever clears —
so a reader knows exactly which stretch of the log is suspect. It is a
**warning**, which is how CMTrace colours it.

Three properties of that announcement are load bearing:

- **The JSONL is untouched.** Every record still carries the boolean, which is
  the surface a filter wants, and the reason the CMTrace line does not have to
  repeat it. The notice is a rendering, so it is written to `HDT.log` only — it
  is not a record, consumes no `seq`, and appears in no JSONL stream.
- **Once per file, not once per process.** `HDTSLShareDynamicLogging` resolves
  after the wizard, so the share mirror starts mid-run; the state is keyed by
  path, and the mirror gets its own notice the first time it is written to
  rather than inheriting a “already said” from a file the watcher cannot see.
- **Per-step logs get nothing.** The clock is a fact about the run, and a step
  file opening with a caveat about the run would be the same noise one directory
  down.

The engine does **not** try to fix the clock. Setting time needs a time source
that may not exist on an isolated deployment VLAN, and a toolkit that refuses to
deploy because it cannot reach an NTP server would be worse than one that logs
honestly. Ordering comes from `seq`; the timestamp is a hint, and now an
explicitly labelled one.

**CMTrace line format**, for the same entry:

```
<![LOG[Applied index 1 to W:\ in 95s]LOG]!><time="03:11:02.481-180" date="08-13-2026"
  component="ApplyImage" context="" type="1" thread="4820" file="Invoke-HDTApplyImage.ps1:142">
```

`type` maps `1`=Info, `2`=Warning, `3`=Error, giving CMTrace its colour coding
for free.

**The CMTrace line carries local wall-clock time; the JSONL carries UTC.** The
same record above is `2026-08-13T00:11:02.481Z` in `HDT.jsonl` and `03:11:02` in
`HDT.log`, because the two files have different readers. The `.jsonl` is
machine-read and UTC is unambiguous; the `.log` is read by a technician who is
correlating the deployment against Event Viewer, against `setupact.log`, or
against a user saying "it broke around half nine". A log rendered in UTC is a
log that lines up with nothing on the technician's desk, and it shipped that way
once: a Dell run wrote `time="20:43:07.612+000"` while the wall clock said
`22:43`.

**The offset field is `ActiveTimeBias` — the minutes to add to local to reach
UTC — not an ISO offset.** Its sign is therefore inverted relative to `+03:00`:
a machine three hours east of Greenwich writes `-180`, and Pacific daylight time
writes `+420`. This is Microsoft's own convention on both sides of the family.
MDT's `ZTIUtility.vbs` builds the line from `Now()` — local — and appends a
literal `+000` rather than computing the field; its `OSDEndTime.vbs` reads
`ActiveTimeBias` when it wants UTC. The ConfigMgr client fills the field in
properly, and a capture of 49,096 client lines from a UTC+3 machine carries
`-180` on every one of them.

A machine whose zone is unset — which is every WinPE boot, until something sets
it — reports UTC, so the bias renders `+000` and the line is byte-for-byte the
one MDT ships. The renderer is correct for whatever offset the machine reports
and deliberately does not second-guess it; a WinPE zone that is wrong is a
separate defect, and correcting it in two places would compound.

**The two files do not share a line terminator, and the difference is load
bearing.** `HDT.log` and every per-step log are written **CRLF**; `HDT.jsonl` is
written **LF**.

CMTrace is a line-oriented Win32 parser that breaks entries on CRLF. Handed
LF-only text it never separates one entry from the next, the per-entry
`<![LOG[...]LOG]!>` match fails, and it falls back to dumping raw text with
**Component, Date/Time and Thread blank** — every attribute correct in the bytes,
and the reader never reaching them. This is the same rule section 11 states for
the other Windows-format file the build writes, where `startnet.cmd` is "written
ASCII with CRLF and no BOM": a file a Windows tool parses gets the terminator
that tool splits on.

JSON Lines defines its separator as a bare line feed, so the `.jsonl` files
keep it. "Fix the newlines" applied to both would break the reader that works
in order to repair the one that does not.

#### 4.4.3 Per-step logs, like MDT's ZTI\*.log

Beyond the master log, **each step gets its own file**: `<step-name>.log` in
`_HDTLogPath`, mirroring how MDT splits `ZTIApplications.log`,
`ZTIDrivers.log` and so on out of `BDD.log`. A failing driver injection should
be readable without scrolling past an OS apply.

Native tool output (DISM, bcdboot, `Install-WindowsFeature`, WUA) is captured
into the step's own log rather than being interleaved into the master, with only
its summary and exit code promoted upward.

#### 4.4.4 Custom steps can log — the extensibility point

Any `PowerShell` step or user script called from `Scripts\` gets
`Write-HDTLog` in scope, writing into the same stream with the same structure:

```powershell
Write-HDTLog "Checking vendor BIOS level"                 # Info by default
Write-HDTLog "BIOS below baseline, updating" -Severity Warning
Write-HDTLog "Vendor tool failed: $err" -Severity Error -Component 'BiosUpdate'
```

Entries carry the step name automatically, so a custom step's output is
attributable without the author doing anything. `-Component` subdivides further
for a step that does several things.

Additionally, a step may declare its own log file:

```yaml
- name: Vendor BIOS Update
  type: PowerShell
  script: Scripts\Update-VendorBios.ps1
  log: BiosUpdate.log        # own file in _HDTLogPath, in addition to the master
```

Anything a user script writes to the standard streams is captured too, so an
existing script that only uses `Write-Host` still lands in the log without
modification — a hard requirement, since real fleets carry years of such scripts.

#### 4.4.5 Verbosity

`LogLevel` (`Error` | `Warning` | `Info` | `Debug`) is settable in
`workspace.yaml`, per sequence, and per step; the most specific wins. `Debug`
adds every variable resolution with its provenance and every native command
line executed in full — the two things most often needed to explain a
deployment that went wrong, and the two things MDT makes hardest to get.

**One exception, and it is MDT's.** `InstallApplications` writes its
`change directory:` and `run command:` pair at **`Info`**, redacted.
`ZTIApplications.wsf` writes both with `LogTypeInfo` (lines 412 and 441), so an
admin reading a *default* MDT log sees the command that ran; the command line is
the one line that makes a failure reproducible by hand, and requiring a whole
deployment to be re-run at a raised level to recover it is a cost paid after the
machine has already been rebuilt. The secret in it is answered by redaction — a
switch or MSI property whose name reads as a credential keeps its name and loses
its value — rather than by hiding the line. Everything else the step learns
(which detection rule was evaluated and what it found, which configured exit
code matched) stays at `Debug`.

The same step **captures the installer's own stdout and stderr** and writes them
one record per line, in MDT's `StandardConsoleProcessing` shape: `  console > `
for stdout, `  console # ` for stderr. The *level* follows the exit code rather
than the stream — `Debug` when the code was accepted, `Warning`/`Error` when it
was not — so a failing install explains itself at the default level while a
chatty install that succeeded costs the share nothing. It is a tail, capped at
40 lines per stream on success and 200 on a failure, and a truncation always
names how many lines were dropped.

#### 4.4.6 Live monitoring

The engine writes a small `status.json` heartbeat to `<share>\Logs\_active\<RunId>.json`
each step. The console tails that directory. No web service, no SQL, no MDT
Monitoring dependency.

### 4.5 The deployment account and autologon

**Decision: HDT resumes in the full OS via autologon as the local
Administrator, the same model as MDT.** A running task sequence needs an
interactive session — not as a convenience, but because a meaningful share of
deployment work requires one:

- Installers that are not silent-friendly, or that fail or hang under a
  non-interactive SYSTEM context.
- Anything touching `HKCU`, the user profile, or COM objects that need a desktop.
- The on-screen progress the technician watches. A deployment that proceeds
  invisibly behind a logon screen is worse in the field, not better.
- Failure handling: `PauseOnError` drops to a PowerShell prompt *on a desktop
  the technician is already sitting in front of* (§4.3).

A SYSTEM scheduled task avoids a stored credential but gives all of that up.
The credential is the cheaper problem to solve.

#### 4.5.1 Mechanism

1. **First logon** is configured by the unattend applied in `ApplyUnattend`:
   the `oobeSystem` pass sets `AdministratorPassword` and an `AutoLogon` block
   (`Username`, `Password`, `Enabled`, `LogonCount`). The staged
   `unattend.xml` is deleted from the target volume once Setup consumes it.

   **`LogonCount` is 999, matching MDT.** All four MDT/PSD unattend templates
   use it, and `PSDFinal.ps1` then sets `AutoLogonCount` to `0` at the end —
   which is the point: **the count was never MDT's safety mechanism, cleanup
   was.** 999 exists so the allowance cannot run out mid-deployment.

   That matters because Windows reboots itself during specialize and OOBE, and
   S8 proved the count decrements *before* a session starts. A small value can
   therefore be spent on an intermediate boot, leaving the machine at a logon
   prompt with the engine never reaching control — a failure that is silent and
   indefinite, with no error and no timeout. A sample carrying `LogonCount 1`
   stranded a real deployment exactly this way.

   HDT does not rely on that 999 for long: step 2 replaces it.
2. **Subsequent reboots** are configured by the engine writing the Winlogon
   values before each `Restart` step: `AutoAdminLogon`, `DefaultUserName`,
   `DefaultDomainName`, and `AutoLogonCount` under
   `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`.

   The engine arms this **when it needs a reboot**, not proactively. The
   unattend's 999 covers everything until then, and teardown (§4.5.4) disarms
   the lot at the end.

   **Deliberately not doing more.** An earlier draft had the engine re-arm on
   its first full-OS leg to replace 999 with a bounded count, narrowing the
   window in which an abandoned deployment keeps autologging on. That is a
   hardening, not a requirement, and it buys a smaller exposure than the two
   backstops already in place — teardown in `finally`, and the boot-time
   reconcile (§4.5.2) that disarms on any boot where the state document says the
   run is finished, failed or missing. MDT has lived with the same residual
   exposure for years. Revisit in a later version if it ever proves to matter;
   until then the mechanism stays simple enough to reason about.
3. **The engine is launched at logon** by a `RunOnce` entry re-registered each
   leg, pointing at `C:\HDT\Start-HDTResume.ps1`, which loads `state.json` and
   continues at the next step.

   **`RunOnce`, and not MDT's Startup shortcut, on purpose.** MDT — and PSD
   after it, in `PSDStart.ps1` — puts a `PSDStartup.lnk` in the all-users
   Startup folder and uses `RunOnce` only as a fallback, when `HideShell` is set
   or the OS is Server Core and there is no shell to run a Startup item. HDT
   takes the fallback as its only path — a deliberate divergence, recorded in
   §14 with the rest of them, and these are the reasons:

   - **A shortcut persists; a `RunOnce` entry is consumed before it runs.** A
     machine that crashes mid-leg with a shortcut in Startup boots, logs on and
     runs the deployment AGAIN — the "loop nobody is watching" that §4.5 already
     refuses when it shuts a failed run down rather than restarting it. With
     `RunOnce` the crashed leg simply stops, and the next boot's reconcile
     (§4.5.2) disarms the machine as abandoned. The two mechanisms disagree
     about what a crash means, and HDT has already chosen.
   - **It needs no shell.** Server Core and a hidden shell resume on the same
     path as everything else, rather than on a second one that only those
     machines ever take — and a path only some machines take is a path nobody
     tests.
   - **It is verified.** `.planning/SPIKES.md` records three real autologons
     driven leg by leg, with the `RunOnce` entry consumed and re-registered each
     time and the registry `DefaultPassword` absent throughout.

   The cost is the one thing the shortcut buys: no automatic retry after a crash
   inside a leg. That is not a loss here, because HDT does not want one.

#### 4.5.2 Four differences from MDT

These are the reasons to reimplement rather than copy:

- **The administrator sets the password; HDT does not invent one.**
  `HDTAdminPassword` is configured — in a rule, a per-machine override, or the
  wizard's admin password page — and that is the password the deployed machine
  ends up with.

  **The workspace-wide default is the fallback rule in `rules.yaml`**, which is
  MDT's `[Default]` section exactly. An earlier draft of this paragraph said
  `workspace.yaml`; that was wrong, and §3.1 is the reason — `workspace.yaml`
  holds share identity and boot-image configuration, and is not one of the six
  variable sources. A default that lived there would resolve through no
  precedence and record no provenance, which is the opposite of what §3.1 exists
  to guarantee. Putting it in the fallback rule means it loses to a per-machine
  override and to the wizard exactly as any other variable does, and the log says
  it came from the rules.

  An earlier draft generated a random per-deployment password and rotated it at
  the end. That is better in isolation and worse in practice: when a deployment
  fails halfway, the machine is sitting there with a password nobody knows, at
  exactly the moment a technician needs to log in and look at it. A toolkit
  whose failure mode is "you cannot get into the broken machine" is not one
  people will keep using. Randomisation remains available —
  `HDTAdminPassword: <random>` generates one per deployment for fleets that
  pair it with LAPS — but it is opt-in, not the default.

- **It is stored as clear text, exactly as MDT stores `AdminPassword`.**
  `HDTAdminPassword` sits in `workspace.yaml`, `rules.yaml` or a per-machine
  override as a readable value, and the unattend carries it with
  `PlainText="true"`.

  **This is a deliberate decision, not an oversight.** An earlier draft
  specified AES with `Protect-HDTSecret`/`Unprotect-HDTSecret`. It was dropped
  because the encryption could not have been a security boundary: WinPE must
  decrypt with no human present, so the key has to ship inside the boot image,
  and anyone holding the media recovers both. It would have bought obfuscation
  against a casual `Get-Content` while adding a key-management surface, a second
  failure mode during deployment, and a false impression that boot media is safe
  to hand out.

  **The real control is the same one that governs the share credential (§6.3):
  treat boot media and the workspace as credentials.** Restrict who can read
  them, and give the account a password worth only what a freshly-built machine
  is worth — then rotate it, hand off to LAPS, or disable the account with the
  tools that own those jobs. That is how MDT has been operated for fifteen
  years, and it is honest about where the trust actually sits. HDT builds no
  keyword for it: see §4.5.4 on why `HDTAdminPasswordPolicy` was cut.

  **But clear text in the CONFIGURATION is not clear text in the OUTPUT.** The
  files above are ones an administrator authors, restricts and treats as
  credentials. The files a deployment *produces* — `HDT.jsonl`, `HDT.log`,
  `state.json`, `Gather\provenance.json`, `Gather\facts.json` and the HTML
  report — are none of those things: SLShare copies them to the deployment
  share, which every machine being deployed can read, and the finish action
  moves them to `C:\Windows\Logs\HDT` on the deployed machine, which
  authenticated users can read. A password written there is readable by any
  local user of the machine it administers, which is privilege escalation
  rather than disclosure. It happened: a real run put `HDTAdminPassword` in
  clear in the first three of those files while the fourth, written from the
  same resolution seconds earlier, correctly said `(set, not shown)`.

  So every writer of a name-and-value pair asks one shared helper —
  `Test-HDTSecretVariable` classifies, `Protect-HDTSecretValue` substitutes —
  and the name, source, rule and file all survive while only the value is
  replaced. Which names count is `Get-HDTVariableMap`'s `IsSecret` column
  unioned with a name pattern: the column covers what HDT ships, the pattern
  covers the `HDTJoinPassword` a customer invents. MDT solved the same problem
  more bluntly — `ZTIUtility.vbs` replaces any log message containing the word
  "password" with `<Message containing password has been suppressed>`, losing
  the line rather than the value.

  **The registry adapter answers the same question, with its own classifier and
  the same visible substitution.** `New-HDTRegistryService.SetValue` logs the
  value it wrote. It did not, once: it logged the name, the type and the length
  and never the value, so that this guarantee could not depend on a future
  caller remembering — and that bought one password at the price of every
  readable registry write in the engine. A real run's tattoo said
  `registry value 'Make' ... was written as String (9 character(s))`, which
  answers nothing about a machine that came back wrong.

  So the blanket silence is an enforced guarantee instead, in three parts:

  - `Test-HDTSecretRegistryValue` classifies the **value name**. An explicit
    deny-list — `DefaultPassword`, `DefaultPasswordEncrypted` — unioned with
    `Test-HDTSecretVariable`'s pattern, so a name a site invents through a
    Tattoo step's `values:` block is caught on the first run. The deny-list does
    not depend on §4.5.2's LSA storage staying correct: a guarantee that holds
    only while the code around it is right is not a guarantee.
  - `SetValue` takes an optional fifth argument, **`Sensitive`**, so a caller
    writing a secret under a name no classifier would recognise can say so. It
    marks a value; nothing un-marks one the classifier refused. The fake carries
    the same overload, because a double that rejects a call the adapter accepts
    is the double being wrong.
  - `Format-HDTRegistryLogValue` substitutes, and **the redaction is visible** —
    `<redacted, 12 character(s)>`, never a blank, because a blank cannot be told
    from a value that was empty or never set, and those mean opposite things
    about the machine. The length survives: a password of the wrong length is a
    different fault from no password at all. A value over 512 characters is
    truncated with its full length reported, and redaction happens *before*
    truncation so no prefix of a long secret is ever shown.

  The decision lives in those two helpers rather than in the adapter, which
  stays branch-free because nothing unit-tests it (CLAUDE.md rule 1). The
  guarantee is asserted end to end: a realistic deployment password driven
  through the real `Set-HDTAutoLogon` arming path must appear in neither
  `HDT.jsonl` nor the CMTrace `HDT.log`, and the `DefaultPassword` value name
  is written through both the real adapter and the fake in
  `RegistryService.Contract.Tests.ps1`.

  **A consequence, and it is load-bearing.** A leg that resumes after a reboot
  rehydrates its variable bag from `state.json`, so it sees the redaction where
  a secret was. `HDTAdminPassword` is recovered from the autologon LSA secret,
  which is admin-only and holds the same value by construction. Any *other*
  secret consumed by a full-OS step after a reboot has no such recovery — see
  the note below.

  **Open, and named here rather than left to be rediscovered.**
  `HDTBitLockerPin`, `HDTProductKey` and `HDTDomainAdminPassword` are read from
  the variable bag by their steps. The unattend is applied in WinPE and the
  EnableBitLocker step's PIN is authored in the sequence rather than resolved
  across a leg, so neither of the first two regresses today. The durable answer
  is an LSA-carried secret bag written alongside each checkpoint, which is the
  same mechanism this section already chose for the autologon password; it is
  not built.

  **`JoinDomain` reached it first, on 2026-09-01, and it is no longer
  hypothetical.** The step joins online in the full OS — §4.2, and §4.1's own
  example sequence puts it in State Restore — so it runs in the leg *after* a
  restart and is handed `(set, not shown)` where the password was. **It refuses
  rather than attempting the join**, and that refusal is not a nicety: trying a
  redacted value is one wrong-password attempt per machine against the one
  account that can join anything to the directory, so a lab of forty deployed
  overnight would trip a lockout policy forty times on it. Until the secret bag
  exists, an unattended domain join needs `HDTDomainAdminPassword` set in the
  leg that runs the step.

  It is worth saying why the obvious escape is not one: **the join is not moved
  into the unattend to dodge this.** MDT's `Microsoft-Windows-UnattendedJoin`
  component would have the password available in WinPE where the wizard
  collected it — and would write it in clear into a file that stays on the
  deployed disk and rides inside any image captured from it, while turning a
  failed join into a silent one. The redaction is a problem to solve; a
  credential in an answer file is a problem to avoid.
- **It is stored as an LSA secret, not registry cleartext.** Winlogon reads
  `DefaultPassword` from LSA private data as well as from the registry; this is
  the mechanism Sysinternals' `Autologon.exe` uses. Same behavior, no plaintext
  string sitting in a registry hive that any local read can lift, and no
  plaintext in a registry backup or a captured image.

  **Verified (SPIKES.md S7, and again in S8).** Windows itself does exactly
  this: a machine deployed with an unattend `<AutoLogon>` block autologs on with
  `AutoAdminLogon=1`, `DefaultUserName=Administrator` and `AutoLogonCount=3` in
  the registry while **`DefaultPassword` is absent** from it. S8 then drove
  three further autologons on that same machine with the registry
  `DefaultPassword` still absent and the LSA secret the only password store, so
  the secret is demonstrably what Winlogon reads. LSA-secret storage and
  `AutoLogonCount` coexist natively — this is the supported path, not a
  workaround, and **no registry-storage fallback is required**.
- **`AutoLogonCount` bounds it.** The engine sets the count to exactly the
  number of legs remaining. Windows decrements it per autologon and tears down
  `AutoAdminLogon` when it reaches zero — so an abandoned or failed deployment
  stops autologging-on by itself rather than staying open forever.

  **Observed (SPIKES.md S8).** Armed offline with `AutoLogonCount=3` and a
  `RunOnce` entry re-registered per leg, a Windows 11 machine autologged on
  three times and read the count as `2`, `1`, `0` — so Windows decrements it
  **before** handing the session over, and a count of *n* buys exactly *n*
  autologons. On the fourth boot no autologon happened, and Windows had itself
  set `AutoAdminLogon=0`, deleted `AutoLogonCount` entirely, and blanked the
  `DefaultPassword` LSA secret to zero length. The third backstop works as
  designed, and `-RemainingLeg` therefore means literally "how many more
  autologons", with no off-by-one.

  It stays the **third** backstop behind `finally` teardown and the boot-time
  reconcile: it only disarms after the legs are spent, so an abandoned run still
  autologs on for up to *n* boots before Windows closes it. Teardown and the
  reconcile are what make that window short.
- **Teardown is a failsafe, not a step.** MDT's cleanup is a task sequence step,
  so a failure before it leaves autologon armed. In HDT teardown runs from
  `finally` around the sequence, *and* `Start-HDTResume.ps1` reconciles on every
  boot: if the state document says the run is finished, failed, or missing, it
  clears autologon, the LSA secret, the `RunOnce` entry, and `C:\HDT\state.json`
  before doing anything else. `AutoLogonCount` is the third backstop behind both.

#### 4.5.3 Autologon identity across a domain join

A sequence that joins a domain raises a question the mechanism above does not
answer on its own: after the join, **who does the machine log on as** for the
remaining legs?

**Default: the local Administrator, unchanged.** `DefaultDomainName` stays `.`
— the local machine — exactly as MDT's unattend template does
(`<AutoLogon><Domain>.</Domain>`). Domain credentials
(`HDTDomainAdmin`, `HDTDomainAdminDomain`, `HDTDomainAdminPassword`) are used
**for the join operation and nothing else**. They are never written to Winlogon
and never stored as the autologon secret.

That separation is the point. A domain account used for autologon has its
password sitting in the LSA secret of every machine being built, on the bench,
often on a VLAN with weak physical control — and if that account is the one with
rights to join machines to the domain, recovering it is a privilege escalation
across the whole estate. The join needs those rights for a few seconds; the
autologon does not need them at all.

**The option, for fleets that need it:**

```yaml
autoLogon:
  account: local          # local (default) | domain
  # when account: domain
  domain: CONTOSO
  user: svc-hdt-build     # NOT the domain-join account
```

When `account: domain`, the engine rewrites `DefaultDomainName` and
`DefaultUserName` **after** the `JoinDomain` step succeeds and before the next
`Restart` — the values are meaningless until the machine is actually a member,
so writing them earlier would strand the deployment at a logon prompt it cannot
satisfy. Validation refuses `account: domain` in a sequence with no `JoinDomain`
step, for the same reason.

If it is used, it should name a **dedicated low-privilege build account**, not
the join account and not a domain admin. HDT warns when the autologon user and
the domain-join user are the same.

**A failure mode worth naming, because it is silent.** After a domain join,
Group Policy may disable the built-in Administrator or deny it interactive
logon. Autologon then fails and the machine sits at a logon screen with the
sequence unfinished — no error, the same indefinite stall as an exhausted
`LogonCount`. Fleets whose policy does that are the reason `account: domain`
exists. HDT cannot detect the policy before it applies, so this is documented
rather than guarded.

#### 4.5.4 Teardown checklist

At sequence end — success or failure — the engine clears: `AutoAdminLogon`,
`DefaultUserName`, `DefaultDomainName`, `DefaultPassword` (registry *and* LSA
secret), `AutoLogonCount`, the `RunOnce` entry, the staged unattend, and the
protected password from `state.json`.

**The Administrator password itself is not changed at teardown.** It is the one
the administrator configured (§4.5.2), so the deployed machine keeps it and a
technician can log in — including into a machine whose deployment failed, which
is the case that matters. What teardown removes is the *autologon*, not the
account.

~~A sequence may still declare a different end state~~ —
**`HDTAdminPasswordPolicy` IS CUT (user, 2026-08-25), not deferred.**

**HDT supplies the Administrator password as clear text, exactly as MDT does.**
`HDTAdminPassword` resolves through the ordinary rules engine — MDT's
`AdminPassword` in `CustomSettings.ini` — and the deployed machine keeps it.
That is the whole model, it is the one an MDT admin already operates, and it is
what the paragraph above describes as the honest place for the trust to sit.

`rotate`, `laps` and `disable` were a fourth thing to configure, a local-account
service to build and three more end states to test, in service of a policy MDT
never had. A site that wants LAPS installs LAPS; a site that wants the account
rotated runs a step that rotates it. Neither needs a keyword in this engine.

This checklist is a test in M2, asserted against a fake registry and LSA
provider, and again in M3's integration layer against a real VM: after a
deployment — and after a *deliberately failed* deployment — none of these
artifacts remain.

---

## 5. Boot image

`Update-HDTBootImage` builds the boot image from the installed Windows ADK +
WinPE add-on. Like MDT's `Update-MDTDeploymentShare`, **one build produces two
artifacts from the same source**:

| Artifact | Purpose |
|---|---|
| `Boot\HDTPE_x64.wim` | Imported into WDS as a boot image; the PXE path (§6.1) |
| `Boot\HDTPE_x64.iso` | Mount into a VM, burn, or attach over IPMI/iDRAC/iLO; the debugging path (§5.2) |

Both come from a single mount/inject/commit cycle. They are never built
separately, so the ISO you debug with is byte-for-byte the WinPE you PXE boot —
which is the entire point of having it.

### 5.1 Contents

**The optional-component list is configuration, not a constant.** MDT lets an
admin pick Windows PE features per boot image, and HDT must too — a fleet with
an unusual NIC, a WinRE workflow, or a scripting dependency will need components
this project never anticipated. `workspace.yaml` declares them:

```yaml
bootImage:
  optionalComponents:            # merged with the required set below, order preserved
    - WinPE-EnhancedStorage
    - WinPE-WDS-Tools
  extraContent:                  # arbitrary files copied into the image
    - source: Modules\MyVendorTools
      destination: \HDT\Modules\MyVendorTools
  drivers: boot-critical         # driver group injected into the boot image
  entryCommand: >-                # what startnet.cmd runs; omit for deployment
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTProbe.ps1
```

`Update-HDTBootImage -OptionalComponent` overrides per invocation.

**`entryCommand` is what makes a diagnostic image possible without a keyboard.**
Omitted — the normal case — `startnet.cmd` launches `X:\HDT\Start-HDTDeployment.ps1`
and the image deploys. Declared, it launches that command instead, which is how
an image whose job is to probe, repair or report is built without the engine
having to pretend it is deploying.

The value is written into `startnet.cmd` verbatim, so it is validated for the two
things that would make the written file mean something other than what the
document says: it may not be empty, and it may not contain a line break — a break
is a second command running inside WinPE that no reader of `workspace.yaml` would
see as one. What the command *does* is not validated; that is the admin's.

Pair it with `extraContent` to put the script inside the image. That pairing is
the point: content staged into the image lands under `X:`, the WinPE RAM disk,
whose letter is fixed. A script staged on a data disk instead has no guaranteed
letter, which is what forces the `for %d in (C D E F G)` scan that HDT does not
write into `startnet.cmd` and no longer types at a prompt either.

**Required set, in dependency order — verified working (SPIKES.md S1):**

```
WinPE-WMI -> WinPE-NetFx -> WinPE-Scripting -> WinPE-PowerShell
  -> WinPE-StorageWMI -> WinPE-DismCmdlets
```

Plus, by default: `WinPE-SecureStartup` (BitLocker), `WinPE-EnhancedStorage`,
`WinPE-WDS-Tools`. Each component's matching `en-us` pack is applied
immediately after it, where one exists — some components (e.g. `WinPE-FMAPI`)
have none, so the builder must probe rather than assume.

Note the cab is `WinPE-NetFx.cab` — lowercase `x`. An earlier draft of this
document said `WinPE-NetFX` and listed `WinPE-FMAPI` in the default set; neither
matched what was actually built and verified. The list above is the one that
booted.

**What this set does and does not give you.** Verified by inspection inside a
running WinPE (SPIKES.md S1):

| Available | Not available |
|---|---|
| `Storage` (Get-Disk, New-Partition, Format-Volume) | `NetTCPIP` (New-NetIPAddress, Get-NetIPAddress) |
| `SmbShare`, `Dism`, `CimCmdlets`, `BitsTransfer` | `NetAdapter` (Get-NetAdapter) |
| `Microsoft.PowerShell.*`, `PSReadLine` | `DnsClient` (Resolve-DnsName) |

**There is no optional component that adds the `Net*` modules.** Consequently
the engine configures and inspects networking through `netsh` and
`Win32_NetworkAdapterConfiguration` (CIM), never through `Get-NetAdapter` /
`New-NetIPAddress`. This is also what `PSDGather.ps1` does, for the same reason.
The `Storage` module *is* present, so §9 disk work uses the storage cmdlets
normally.

Injecting the `NetTCPIP` module by hand via `extraContent` is possible but
unsupported: those modules depend on CIM providers and MOF registrations absent
from WinPE, and the arrangement breaks across ADK releases. `extraContent`
exists for self-contained payloads, not for reconstructing Windows components.

Also injected: network and storage drivers (from a designated boot driver group
— boot images should never get the whole driver store), the HDT engine module
under `X:\HDT\`, and a `startnet.cmd` that runs `wpeinit` then launches
`X:\HDT\Start-HDTDeployment.ps1`.

**What lands where inside the image** (settled in 05-04):

| Path in the image | What |
|---|---|
| `X:\HDT\bootstrap.json` | where the content is and which provider reaches it (§6, read by `Get-HDTBootstrapConfiguration`) |
| `X:\HDT\Start-HDTDeployment.ps1` | the WinPE entry point |
| `X:\HDT\Start-HDTResume.ps1` | staged **from** the boot image **to** the target for the full-OS leg |
| `X:\HDT\Modules\Hephaestus` | the engine, **excluding `Payload\`** — those two scripts live at `X:\HDT\`, and a second copy would be a second answer to "which one is running" |
| `X:\HDT\Modules\powershell-yaml` | the parser the whole engine rests on in WinPE (SPIKES S9.1) |
| `X:\Windows\System32\startnet.cmd` | five lines, below |

`startnet.cmd` is five lines and no more, written ASCII with CRLF and no BOM:

```
@echo off
rem Written by Update-HDTBootImage. Do not edit inside the image; edit HDT.
set HDT_LAUNCHED_BY=startnet
wpeinit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\HDT\Start-HDTDeployment.ps1
```

`HDT_LAUNCHED_BY` is recorded into `RESULT.json`, which is how an end-to-end test
proves the engine was launched by the image rather than typed at the prompt.
`wpeinit` runs **before** PowerShell because it is what brings networking up.
`X:` is written literally and is the only drive letter allowed here — the RAM
disk is the one letter WinPE guarantees (SPIKES S9.1). There is no drive scan.

`deployRoot` and `contentMarker` are carried into `bootstrap.json` **verbatim**,
including the volume-relative form (`\Share`). A builder that expanded that to
the drive letter it sees on the build host would bake in the one value that is
certainly wrong.

The build is **deterministic and repeatable**: mount, apply components, inject,
commit, export (`/Compress:max`), and record a manifest of exactly what went in.
Boot image drift — where nobody remembers what's in the WIM — is a real MDT
operational problem.

The scratch path the build mounts and stages in **must contain no space** — see
§5.2 and SPIKES S2 — and must not be inside the workspace or inside the
repository. A build that writes into the share it is reading is how a deployment
share ends up with a `mount` folder in it forever.

`Update-HDTBootImage -SkipIso` omits ISO generation, matching MDT's per-platform
ISO checkbox. During iteration on a WDS-based lab you often don't need it.

**Corrected in 05-04 by measurement: generating the ISO is _not_ the slow half.**
An earlier draft of this paragraph said it was. On this host a full build takes
**123 s** and the same build with `-SkipIso` takes **120 s** — `oscdimg` writes a
550 MB ISO from an already-staged media tree in about **two seconds**. The
fifteen-minute figure this plan budgeted for never appeared either. What the
build actually spends its time on is mounting the WIM, applying eighteen cabs
(nine components and nine language packs), and `Export-WindowsImage
-CompressionType Max`. So `-SkipIso` is worth having for the artifact it does not
produce, not for the time it saves, and **nothing should be optimised on the
assumption that the ISO is expensive.**

### 5.2 The ISO, and `-NoPromptForKey`

The ISO is a first-class debugging artifact, not a byproduct. Mounting it into a
VM is the fastest loop for testing a sequence: no PXE stack, no DHCP scope, no
WDS. It carries the same `Bootstrap`-equivalent settings as the WIM, so it
connects back to the same deployment share and runs the same sequences.

**`New-HDTBootIso -NoPromptForKey`** removes the *"Press any key to boot from CD
or DVD…"* pause. That prompt is a real obstacle to automation: an unattended VM
that reboots into a still-attached ISO will sit at the prompt until it times
out, and a lab run that reboots three times wastes minutes and can silently boot
the wrong device.

Mechanism — `oscdimg` with a `-bootdata` entry per firmware target:

- **UEFI:** use `efisys_noprompt.bin` in place of `efisys.bin`. **Verified
  location on ADK 10.1.26100.2454 (24H2):**
  `…\Assessment and Deployment Kit\Deployment Tools\<arch>\Oscdimg\`, alongside
  `oscdimg.exe` and `etfsboot.com` — *not* under the WinPE add-on's `Media\EFI\`
  tree, which holds the bootloader files but not the El Torito boot images. The
  folder also ships `efisys_EX.bin` / `efisys_noprompt_EX.bin` variants for
  oversized boot images. `Get-HDTAdkPath` resolves these rather than hardcoding,
  since the layout has moved between ADK releases.
- **BIOS:** `etfsboot.com` has the prompt in its boot sector code and Microsoft
  ships no no-prompt variant. **A BIOS-bootable ISO will still prompt.** HDT
  states this rather than pretending otherwise; `-NoPromptForKey` with
  `-Firmware BIOS` emits a warning, and with `-Firmware Both` it suppresses the
  prompt on the UEFI path only.

Since Hyper-V Gen2 and every modern physical machine boot UEFI, the UEFI-only
case covers essentially all debugging. `-Firmware UEFI` is the default;
`-Firmware Both` produces a dual-boot ISO for legacy hardware.

Defaults chosen for the debugging use case: `-NoPromptForKey` is **on** for
`New-HDTBootIso` invoked by `Update-HDTBootImage`, because a boot image you
mount to test something should just boot.

**`-bootdata:` cannot take a quoted path, and the ADK path has spaces in it**
(SPIKES S2, verified). A quoted path arrives doubled and `oscdimg` answers
`ERROR: Could not open boot sector file ""C:\Program Files (x86)\...""` /
`Error 123`. So `New-HDTBootIso` **stages** the one or two El Torito images it
needs into a space-free directory first and builds the argument unquoted;
`Get-HDTBootIsoArgument` **refuses** a boot-bit path containing a space, so the
staging cannot be quietly removed later. `Update-HDTBootImage` refuses a scratch
path with a space for the same reason — `<scratch>\bootbits` is what it hands
`New-HDTBootIso`, and a space-free staging directory underneath a path with a
space solves nothing.

**The ISO is built from the exported WIM copied into the media tree**, not from
a second export (05-04). `Update-HDTBootImage` exports once to
`Boot\<name>.wim` and copies that file to `<media>\sources\boot.wim`; the WinPE
`Media\` template ships no `sources\` folder, so the build creates it. One file,
two homes, same bytes — which is what makes §6.1.1 a fact rather than a hope,
and the manifest records `isoBootWimSha256` so an operator can check it without
the test suite.

---

## 6. Transport: PXE and standalone media

Content access is abstracted behind a **provider** interface with three
operations: `Resolve-Content`, `Copy-Content`, `Test-Content`. Steps never
touch UNC paths directly. Three providers in v1:

| Provider | Used by | Notes |
|---|---|---|
| `Smb` | PXE / network deploy | Mapped to a drive letter with per-run credentials, read-only |
| `Local` | Standalone media | Content on the USB/ISO itself |
| `Http` | *stub in v1* | Interface exists so a cloud transport can land later without touching step code |

The `Smb` provider **maps the share to a drive letter** — the first free one
from `Z:` downward, as MDT did — and `Connect()` answers with that drive rather
than the UNC path. This is not cosmetic: `cmd.exe` refuses a UNC working
directory. Started in one it prints "UNC paths are not supported", moves itself
to `%SystemRoot%`, and an application whose install command names its own
installer relatively — `msiexec /i AcroRead.msi`, which is what every vendor
documents — then runs in `C:\Windows` and cannot find it. `InstallApplications`
runs each command through `%ComSpec% /c` in the application's `source` folder,
so that folder has to be a path `cmd.exe` can stand in.

A path already under the share resolves through the mapping too: it names the
same files, and a caller holding the UNC form is the normal case rather than an
odd one.

### 6.1 PXE — the MDT model

**HDT does not ship or replace a PXE server.** It produces a boot WIM; WDS
serves it. This is exactly MDT's division of labor, and it is the right one:
WDS is a supported Windows Server role that already handles DHCP option
coordination, architecture detection, and — critically — **Secure Boot**, which
most fleets cannot disable.

The workflow mirrors MDT's:

1. `Update-HDTBootImage` produces `Boot\HDTPE_x64.wim`.
2. `Import-HDTBootImageToWds` adds or replaces it as a WDS boot image
   (a thin wrapper over `Import-WdsBootImage`, plus replace-in-place semantics
   so an update doesn't accumulate stale images).
3. Machines PXE boot, get HDTPE, and the engine connects back to the share.

For sites with an existing TFTP/HTTP stack instead of WDS,
`New-HDTPxePayload` stages `bootmgr`, `bootmgfw.efi`, `boot.sdi`, the BCD, and
the boot WIM into a directory to point that server at.

**iPXE is not a v1 path.** It is faster for large images and needs no WDS role,
but the stock binary is not Secure Boot signed, and chasing a signed shim chain
is a poor use of v1 effort when WDS works. Revisit post-v1 if a real need
appears. This resolves what was open question §14.2.

### 6.1.1 Debugging without PXE

The ISO from §5.2 exists so that PXE is not on the critical path for
development. The intended loop:

| Situation | Boot from |
|---|---|
| Developing or testing a sequence | ISO mounted to a VM (`-NoPromptForKey`) |
| Reproducing a reported failure | ISO, same build as the failing PXE boot |
| Real deployments | PXE via WDS |
| Remote/lights-out hardware | ISO attached over iDRAC/iLO/IPMI |

Because both artifacts come from one build (§5), a bug reproduced from the ISO
is a bug in the PXE path. That equivalence is what makes the ISO worth
generating every time, and it is asserted by a test in M4: the WIM inside the
ISO and the standalone WIM have identical hashes.

### 6.2 Standalone media

`New-HDTMedia` takes a workspace and **a selection profile**, then produces a
self-contained bootable ISO carrying what that profile names. The engine running
from media is **the same engine** with the `Local` provider — not a parallel code
path. This is the constraint that makes the "share + standalone" dual model
tractable: media generation is a content projection plus a provider swap.

**The selection profile IS the projection, which is MDT's model and already
half-built here.** MDT's media object has one Selection Profile and defaults it
to Everything; HDT ships `everything` and `all-drivers` as built-ins, and
`Expand-HDTSelectionProfile` says in its own header that it answers "what
`Update-HDTBootImage` will hand `Add-WindowsDriver`, and what media will copy".
It does not recurse, deliberately — the consumer does, with
`Copy-HDTContentTree`. So there is no second projection engine to write and no
second place for the answer to differ from the boot image's.

**The workspace's own documents are not content and travel regardless.**
`rules.yaml` in particular is the CONTENT MARKER `Resolve-HDTDeployRoot` hunts
for, so a disc without it cannot be found at all — no profile may omit it.
Neither may `workspace.yaml`, which is the one file media rewrites (§6.2.1).
The profile governs `Applications\`, `OperatingSystems\`, `Drivers\`,
`TaskSequences\` and `Scripts\`; it does not govern whether the disc is a
workspace.

**A profile that includes an application but not what it depends on is warned
about at build time.** `Resolve-HDTApplicationOrder` already computes that graph.
MDT would copy the profile and let the machine fail on the bench; HDT says so
while the ISO is being built, because that is hours earlier and in front of the
person who can fix it. Observed for real on 2026-09-03: a hand-built disc carried
TightVNC without the Acrobat package its `app.yaml` names, and the deployment got
to step 11 of 15 before finding out.

**An ISO, and never a disk HDT partitions itself. Decided 2026-09-03.** An
earlier draft of this section also described writing a USB layout directly — a
small FAT32 boot partition for UEFI plus an NTFS content partition, the split
existing only because a >4 GB image will not fit on FAT32. HDT does not do that
and will not:

- **UDF removes the reason.** `New-HDTBootIso` already burns `-u2 -udfver102`,
  so a 5 GB WIM on one filesystem is not a problem to solve. The two-partition
  layout was a workaround for a limit an ISO does not have.
- **Writing a stick is destructive and HDT has no business guessing which one.**
  Partitioning a removable disk chosen by an admin at a console is the one
  operation in this toolkit whose worst case is somebody's photographs. It is
  also the same refusal `DiskPartition` already makes about an ambiguous target
  (rule 6).
- **It costs nothing, because an ISO already IS the USB path.** Rufus or `dd`
  writes a UEFI ISO to a stick, the stick boots, and `Resolve-HDTDeployRoot`
  finds the content by marker on whatever letter it lands on - `Removable` and
  `CDRom` are both candidate drive types for exactly this reason. The
  technician keeps the tool they already trust for the destructive half.

So there is one output, one code path, and one artifact to hash.

### 6.3 Share credentials

**Decision: the deployment account credential is embedded in the boot image**,
the `Bootstrap.ini` model. PXE-booted machines connect to the share and start
deploying with no operator input — that is the point of PXE, and prompting at
every bare-metal boot defeats it.

Configured in `workspace.yaml` and written into the boot image by
`Update-HDTBootImage`:

```yaml
# workspace.yaml - the file an admin hand-edits and commits. USERNAME ONLY.
deployRoot: \\server\HdtShare
credential:
  username: CONTOSO\svc-hdt-deploy
```

```
Control\share-credential.json   <- written by Set-HDTShareCredential, gitignored
{ "schemaVersion": 1, "username": ..., "password": <obfuscated>, "warning": ... }
```

`Set-HDTShareCredential` writes it; the value never appears in a file an admin
hand-edits, so it does not end up in git. **The secret is in a second file for
exactly that reason** — an earlier draft of this section showed a `password:` key
inside `workspace.yaml` and then said in the next line that the value never
appears in a file an admin hand-edits, and both could not be true of the same
document. `Assert-HDTWorkspaceDocument` now rejects a `password:` key there,
naming this command (05-01), and `Set-HDTShareCredential` is the only writer of
the secret (05-02). The setup steps are in `docs/share-account.md`.

**The exposure is real and is the same one MDT has:** anyone who can read the
boot WIM or a USB stick can recover that account's password. It is not
solvable while a PXE-booted WinPE has no machine identity to authenticate with.
What HDT does is make the account worth as little as possible:

- **Least privilege is the mitigation, and it is enforced, not just documented.**
  `Test-HDTShareAcl` verifies the account is read-only on the workspace, has
  write access to `Logs\` and `Captures\` only, and holds no rights elsewhere.
  `Update-HDTBootImage` runs this check and **warns loudly** when the account is
  over-privileged — a domain admin credential in a boot image is a
  domain compromise, and that is the failure worth catching.
- The account should have **deny interactive logon** and no local admin rights
  anywhere. The setup docs give the exact `net` / GPO steps, because "use a
  restricted account" without instructions is how people end up using
  Administrator.
- **SMB signing and encryption** are used where the server supports them; the
  engine refuses guest fallback and refuses to fall back to unencrypted SMB1.
- **Obfuscation is not claimed as security.** The stored value is not written as
  plain text, but the boot image contains everything needed to reverse it, so
  the docs say so plainly rather than implying the image is safe to hand out.
- **Boot media is treated as a credential.** The docs state that ISOs, USB
  sticks, and the `Boot\` folder carry the account's password and should be
  handled accordingly.

`Update-HDTBootImage -PromptForCredential` builds an image with no embedded
credential for cases where the extra friction is wanted — a shared lab, a media
build going offsite. It is available, not the default.

---

## 7. Driver management

MDT's "Total Control" method — a folder per `%Make%\%HDTModel%`, selected by a rule
— works, and HDT keeps it as the primary path. What it adds is a fallback so an
unrecognized model still gets a usable machine.

- **Import** (`Import-HDTDriver`) puts a vendor pack on the share and expands it
  — a Dell `.cab` through `expand.exe`, a Dell Update Package with `/s /e=`, an
  HP SoftPaq with `/s /e /f`. The `.inf` count is taken from the files on disk
  afterwards, because a vendor installer's exit code is not evidence.

  **There is no `driver-index.json`, and this section used to say there was.**
  The index was specified so that matching at deploy time could be a dictionary
  lookup, and it was not built: the `.inf` files **are** the index, and a
  generated file beside them is a second answer about the share that can go
  stale against the first. Every command reads the `.inf` files.

  What that costs, measured on a real 211-file store rather than argued:
  reading the whole store is **2.5 s**, and the PnP fallback's device query
  is **0.5 s** — so the matching an index would have saved is about three
  seconds, once, on the one path that runs when no group matched. The console,
  which re-reads a folder every time an administrator selects one, keeps a
  cache in the window instead: it dies with the window and every entry is keyed
  on the file's own last-write time, so unlike an index it cannot disagree with
  the disk.
- **Group match (primary).** `ApplyDrivers` with a `group` resolves to a folder
  and stages it wholesale to `<OSVolume>\Drivers`.
- **PnP match (fallback).** If no group matches, the engine enumerates present
  hardware IDs from WinPE, ranks the store against them — by hardware-ID
  specificity, then version, then date — and stages only the matching packages.
- **Boot-critical drivers** (storage/network) are tracked separately and are the
  only ones eligible for boot image injection.
- **Reporting.** `Get-HDTDriverCoverage` answers "which models in this fleet
  have no driver group?" before a deployment fails at 3 a.m.

**Drivers are copied onto the machine, not injected into it.** `ApplyDrivers`
copies each matched package to `<OSVolume>\Drivers`, and the answer file
declares that folder in `Microsoft-Windows-PnpCustomizationsNonWinPE`'s
`DriverPaths` so Windows installs what it needs during **`offlineServicing`**.
This is MDT's model: `ZTIDrivers` stages to the OS volume and lets PnP choose.

The pass matters, and this paragraph named the wrong one until 2026-08-29.
`Microsoft-Windows-PnpCustomizationsNonWinPE` is documented for `auditSystem`
and `offlineServicing` only — Windows Setup refuses the **whole** answer file
over a component in a pass that does not accept it, so `specialize` was not a
harmless imprecision in prose but a defect in the shipped template, and it cost
a deployment at step 10 of 11. Both authorities put it in `offlineServicing`:
MDT's own `Templates\Unattend_x64.xml:168` and PSD's `:124`.

`offlineServicing` is processed when the answer file is applied to an **offline
image**, which is not something first boot does — Setup reading `Panther` runs
`specialize` and `oobeSystem`. So `ApplyUnattend` stages the document and then
applies it, through `IImageService.ApplyUnattend`
(`dism.exe /Image:<osvolume>\ /Apply-Unattend:<staged> /ScratchDir:…`), which is
what MDT does at `LTIApply.wsf:1021-1043` and PSD through `Use-WindowsUnattend`.
Staging without applying leaves the declaration inert — drivers on the disk that
nothing installs, every step green. `tests/contract/UnattendTemplate.Contract.Tests.ps1`
asserts the staged folder and the declared path are the same folder by running
the staging step, because the two silently disagreeing is the failure mode.

The declared `Path` is `\Drivers`, with no drive letter, because it is relative
to the image root DISM is given — the OS volume — and it stays correct once that
volume is `C:` at boot.

MDT additionally writes `DevicePath` in the offline `SOFTWARE` hive
(`ZTIDrivers.wsf:527`); its sibling `UpdateOEMPath` (`:446`) writes
`OemPnPDriversPath` into a `sysprep.inf`, which is the XP-era text answer file
and downlevel only. HDT uses the answer file alone — the mechanism MDT's own
comment on the DISM line credits with driver injection.

This replaced offline `Add-WindowsDriver` injection, and the reason is measured
rather than aesthetic. Every `Add-WindowsDriver` call opens the offline image,
adds one package and **commits** it, so a per-driver loop pays that round trip
once per driver: on a Latitude 5490 on 2026-08-28, 82 drivers took 649 seconds —
a median of **9.0 s each**, almost none of it the driver. A technician watching
the progress window saw eleven minutes of the same dismount repeating. Copying
the same packages is seconds.

The paragraph this replaces claimed offline injection was "matching MDT's
behavior". That was wrong, and it is what justified the design: MDT copies.

It is also the destination a driver **WIM** would be expanded to, which is where
the driver store is going — so the source can change later without moving the
step, and per-driver injection is the shape that would not have survived it.

Boot images are the exception and stay injected: WinPE must carry its NIC and
storage drivers *inside* the WIM, because it has to see the disk and reach the
share before any folder on either exists.

---

### 7.5 Windows updates — offline injection

**Added 2026-09-01.** This is MDT's **Packages** node in HDT's shape: an
administrator downloads a `.msu`, imports it into the share, and a sequence
injects it into the applied volume before the machine has ever booted. It
reverses the "no offline servicing pipeline" half of §15's open question 4 — see
the note there for what changed and what did not.

**It is not §10.1.** That step is online, full-OS, and talks to WSUS through the
Windows Update Agent; it is deferred to v2. This one needs no network, no server
and no reboot loop.

#### 7.5.1 The `.msu` is a WIM, and that killed MDT's mechanism

MDT's `ZTIPatches.wsf` reads a package by running
`expand <file>.cab -F:update.mum` and parsing the `assemblyIdentity` out of
`update.mum`. That cannot work on a current package. Both packages this was
built against begin `4D 53 57 49 4D` — `MSWIM` — and `expand.exe` answers
"Can't open input file". DISM's own `/Get-PackageInfo` is no better: on these it
returns `Package Identity : OnePackage~~~~0.0.0.0` with every other field blank.

A modern `.msu` is a WIM holding, among other things,
`onepackage.AggregatedMetadata.cab`, which holds one **CompDB** XML per package
inside — the cumulative update, and the servicing stack update bundled with it.
That is what HDT reads.

**Reading it costs a tenth of a second, not five gigabytes.** DISM has no
single-file extract, so the naive read unpacks the whole container — 4.76 GB for
the Windows 11 cumulative update. Instead `/List-Image` enumerates the entries
and `/Apply-Image` runs with a `/ConfigFile` exclusion list naming every entry
*except* the metadata cab. Measured 2026-09-01: **0.057 s** for the 1.88 GB
Server package, **0.123 s** for the 4.76 GB Windows 11 one.

#### 7.5.2 What the package states, and what it cannot

Read out of the CompDB, authoritative:

| Field | Source |
|---|---|
| KB | `Feature/@FeatureID` |
| kind | `Feature/@Type` — `CumulativeUpdate` or `ServicingStackUpdate` |
| architecture | `@BuildArch` |
| baseline build | `@OSVersion` — what it expects to find |
| target build | `@TargetOSVersion` — what it produces |
| package identity | the `Package/@ID` it installs |
| bundled SSU | the second CompDB's KB and build |

**And what it cannot: which product it is for.** `@Product` reads `Desktop` for
the Windows **Server** package exactly as it does for the client one. The
2026-06 cumulative updates for Windows 11 24H2 (KB5094126) and Windows Server
2025 (KB5094125) both arrive as `windows11.0-kb50941xx-x64_<sha>.msu`, both are
`amd64`, both expect baseline `10.0.26100.1742`, and both target build `26100`.
Nothing in either file separates them.

So **the administrator names the release at import**, choosing from
`Control\os-releases.yaml` — the share's own if it has one, the module's
`Templates\os-releases.yaml` otherwise, which is `wimscript.ini`'s fallback rule
and what stops the feature being invisible on shares created before it existed.

**A release carries `verified`, and an unverified one must not pass for a
measured one.** `verified: true` means the build number was read off real media
or a real package. `Win11-24H2` and `WS2025` are verified (both 26100, read off
the staged media and confirmed against the two packages). `Win11-25H2` is not.
`Win11-26H2` **ships with no build number at all**, deliberately: a guessed build
would silently refuse every correct import filed under it. An unverified release
still matches — the administrator's label is the authority — but the import warns,
the document records the warning, and the console marks the row.

#### 7.5.3 What is refused, and what is only warned about

| Check | Behaviour |
|---|---|
| architecture mismatch | refused — the package states it |
| major build mismatch | refused, when the release has a build to check against |
| servicing branch mismatch | **warned, never refused** |
| unverified release | warned |

The branch token (`ge_release_svc_prod1` against `lt_release_svc_prod1`) is the
only field that differs between the client and server packages, and it is an
undocumented Microsoft build-branch string seen in three samples. It also
separates a *servicing branch* rather than a product — Windows 11 LTSC reads
`lt_release` too. **For two products sharing a build, the administrator's label
is the only reliable source, and HDT does not pretend otherwise.**

#### 7.5.4 Applying: the package as downloaded, and the image as the witness

`IImageService.AddPackage` hands dism **the `.msu` itself**. The `.wim` inside it
is not a substitute — `/Add-Package` on the inner `.wim` fails `0x80070057`,
tried on both packages. So nothing is unpacked at import or at apply, and the
store is the size of the downloads.

**The exit code is evidence, not the verdict.** Measured 2026-09-01, the same
command against two mounted images:

| | result | dism exit |
|---|---|---|
| Windows 11 LTSC + KB5094126 | 26100.1742 → **26100.8655**, 85 → 159 packages | **`0xC0000409`** |
| Server 2025 + KB5094125 | 26100.1742 → **26100.32995**, 69 → 125 packages | `0` |

An `AssertExitCode` would have failed a good deployment on the first and passed
on the second. Reading dism's prose is no better — nothing pins a language. So
the step re-reads the image's package list through `GetPackage` and believes
that. (The two spellings of a package identity differ: the CompDB omits the
publisher key, DISM includes it, so `Test-HDTUpdatePackageMatch` compares the
fields that identify a package and drops the one that does not.)

#### 7.5.5 Ordering, and failure

**Ordering is read, not guessed**, and mostly dissolves. `Feature/@Type` says
exactly whether a package is a servicing stack update, so those sort first;
everything else sorts by the build it produces, ascending, which puts a
checkpoint update ahead of the update requiring it. But **both real packages
bundle their own SSU** — KB5094126 carries KB5094135, KB5094125 carries
KB5094137 — and dism applies the bundled stack itself. The ordering is for the
standalone SSU, which Microsoft still ships.

**Failure follows MDT's shape by half.** `ZTIPatches` never stops at a bad
package; it also never reports one, logging a non-zero DISM return and returning
`Success` regardless. HDT keeps the first half and rejects the second: every
package is attempted, each gets its own `update.apply` log record, and the step
fails at the end naming every package that failed. **`0x800F081E` — not
applicable to this image — is not a failure**: importing a broad set and letting
a sequence pick from it is the ordinary workflow, and treating it as an error
would make the feature unusable for its own purpose.


## 8. Applications

```yaml
schemaVersion: 1
id: 7Zip-24.09
name: 7-Zip 24.09 x64
install: msiexec.exe /i "7z2409-x64.msi" /qn
uninstall: msiexec.exe /x "{GUID}" /qn
successCodes: [0, 3010]
rebootCodes: [3010]
detect:                            # OPTIONAL
  type: msiProduct
  productCode: "{GUID}"
dependencies: [VCRedist-2015-2022]
runIn: FullOS
```

- **Detection rules** (`msiProduct`, `file`, `registry`, `script`) let the
  engine skip already-installed apps — MDT has no first-class detection, so
  reruns reinstall everything.

  **`detect:` is optional.** An `app.yaml` that declares none installs every
  time the step reaches it, which is the right behaviour for an unconditional
  installer, a script wrapper, or a payload whose "installed" state is not
  observable. Omitting it lands exactly on MDT's behaviour; declaring it is the
  improvement, not the entry fee. **The engine never infers a detection rule for
  an app that declined to declare one** — a guessed rule that reports an app
  installed when it is not is worse than no rule, because the step then silently
  skips work the sequence asked for. An app with no `detect:` is therefore not
  idempotent, and that is the author's stated choice rather than an engine
  limitation.
- **Dependencies** are topologically sorted; a cycle is a validation error at
  authoring time, not a hang at deploy time.
- **Reboot handling** is explicit: a `3010` return suspends the app list,
  reboots, and resumes at the next app.

  The mechanism is §4.3's `-Reenter`. The step checkpoints the ids it has
  installed into `_HDTApplicationInstalled` and returns
  `RebootRequested -Reenter`, so the engine records it `Pending`, the step index
  does not advance, and the next leg runs the step again — skipping what is
  already done. **The application that returned `3010` is checkpointed as
  installed**, because `3010` means "installed, reboot required"; re-running it
  would install it twice. The two ways this is normally got wrong are worth
  naming: without `-Reenter` every application after the reboot is silently
  skipped while the run reports success, and without the checkpoint the step
  reinstalls the whole list ahead of the reboot on every leg.
- **An install command is a shell line**, run through `%ComSpec% /c` exactly as
  the `CommandLine` step's `command:` is — quoting, chaining and redirection are
  routine in what a vendor documents as their silent install. The working
  directory is the application's `source\` folder, so a relative installer path
  resolves. The comspec comes from the injected `IEnvironmentProvider`.
- **A failure stops the list.** An application returning a code in neither its
  `successCodes` nor its `rebootCodes` fails the step naming the application and
  the code, and the applications after it do not run — installing software on top
  of a failed dependency is how a machine ends up subtly broken. A sequence that
  wants otherwise says so with `continueOnError` on the step, which belongs to
  the engine loop rather than to the step.
- **Selection** comes from the `Applications` variable (rules or wizard), or a
  fixed list in the step. Both resolve to the same ordered install plan, which
  is logged before execution.

---

## 9. Imaging

### 9.1 Disk layout

**Two named layouts, or one a sequence writes itself.** A `DiskPartition` step
either names a built-in or carries its own `partition:` table; declaring both is
refused, because they are two different answers to the same question about the
same disk.

The named ones cover the case that should stay one word in a document:

- `uefi-standard` — GPT: EFI System 260 MB FAT32, Windows (remainder minus
  recovery), WinRE recovery 1 GB at the end.
- `bios-standard` — MBR: System Reserved 500 MB active NTFS, Windows remainder.

**Neither declares a Microsoft Reserved partition, and that is deliberate.**
SPIKES S6: `Initialize-Disk -PartitionStyle GPT` creates the 16 MB MSR *itself*.
PSD's `PSDPartition.ps1` initialises GPT and then creates an MSR by hand a few
lines later, which is how the spike ended up with a duplicate 16 MB partition.
HDT carries the 16 MB as an **allowance** (`ReservedSizeByte`), subtracts it from
the space Windows can have, and creates no partition for it. This section
previously listed `MSR 16 MB` among the partitions to create; that was the bug.

**It creates that MSR on the host and not inside WinPE** (SPIKES S9.10, measured
both ways). On the host it is 16 759 808 bytes at offset 17 408 — which together
are *exactly* the 16 777 216 the allowance carries, so the number is right to the
byte. Inside WinPE the deployed disk ends up with ESP / Windows / Recovery and
nothing else, exactly as S6's own hand-run log recorded. Nothing about the design
turns on which happens: HDT never creates an MSR either way, the allowance is
subtracted either way, and the recovery partition carries `UseMaximumSize` so an
unused allowance lands there rather than being left unallocated.

**The disk is only cleared when there is something to clear.** `Clear-Disk`
reports *"The disk has not been initialized."* on a RAW disk (SPIKES S9.3), and a
machine that has never been deployed has exactly that — so `DiskPartition` skips
the clear when the target's partition style is `RAW` and records that it did.
S6's "the working recipe is `Clear-Disk -RemoveData -RemoveOEM` then
`Initialize-Disk`" holds for a disk that already carries a partition table.

**The ESP is created as basic data and retyped after formatting.** A partition
created directly as an EFI System partition cannot readily be given a drive
letter to format through, so a layout carries both `CreateGptType` (basic data)
and `GptType` (the ESP type), and `DiskPartition` creates, letters, formats, then
retypes. **Verified against a real disk in 04-04**, where it had been recorded as
a field recipe rather than a tested one.

**A FAT32 volume label comes back uppercased.** The layout asks for `System` on
the ESP and `Get-Volume` reports `SYSTEM`; NTFS preserves the case it was given.
Nothing downstream may match a volume label case-sensitively.

#### An authored partition table

MDT's *Format and Partition Disk* lets an administrator lay a disk out row by
row, and the commonest thing they do with it — a data volume beside Windows —
could not be said here at all. It can now:

```yaml
- name: Format and Partition
  type: DiskPartition
  wipe: true
  partition:
    - name: System    type: EFI      size: 260MB
    - name: Windows   type: Primary  size: 60%        variable: HDTOSVolume
    - name: Data      type: Primary  size: remainder
    - name: Recovery  type: Recovery size: 1GB
```

`ConvertTo-HDTDiskLayout` turns that into **the same shape `Get-HDTDiskLayout`
returns**, so `New-HDTDiskLayoutPlan` reads an authored layout and a built-in
through one door and there is never a second copy of the arithmetic to keep
right.

**A percentage is of what is left, not of the disk** — MDT's own wording is "a
percentage of remaining free space". On a 128 GB disk the two differ by more than
a gigabyte, and differ *silently*: the disk still partitions, just not as the
author meant. Percentages are floored, never rounded; rounding up hands out a
byte the disk does not have and the failure lands on whichever partition is
created last.

**`TakesRemainder` and `UseMaximumSize` are two flags because they are two
questions.** `UseMaximumSize` is where leftover slack *lands* when the partition
is created — `uefi-standard` puts it on Recovery. `TakesRemainder` is which row
gets the space nothing else claimed, which in the built-ins is Windows by role
and in an authored table is whichever row said `remainder`. Collapsing them gave
an authored layout Recovery's flag and Windows' meaning.

**The type is a word, never a GUID.** An author writes `EFI`, `Primary` or
`Recovery`; the ESP's `c12a7328-…` and the recovery type are the engine's
business, including the create-as-basic-data trick below. `Logical` and
`Extended` — which MDT's dialog offers — are refused **by name**: this engine
creates basic partitions and has never made an extended container, and accepting
the word while quietly making a Primary would produce a disk that does not match
the document.

**`quickFormat` and `bootable` come from MDT's own per-partition variables**
(`OSDPartitions<n>QUICKFORMAT`, `…BOOTABLE`, still listed in PSD's
`ZTIGather.xml`), with MDT's defaults: quick, and bootable on the first
partition. Two bootable partitions are refused — the firmware picks one, and
which one is then not the author's decision.

#### Editing that table, and the tab that shows it

MDT's dialog is five buttons over a list of volumes, so this is five commands and
a window that is their face — the console may not do anything the cmdlets cannot:

| Button | Command | What it refuses |
|---|---|---|
| New | `Add-HDTStepPartition` | a size the engine cannot read; a step that names a layout instead |
| Edit | `Set-HDTStepPartition` | the same size grammar; a row the step does not have |
| Delete | `Remove-HDTStepPartition` | the last row — a step with an empty table is not a layout |
| ▲ ▼ | `Move-HDTStepPartition` | nothing; at the ends it is a press with nowhere to go |

**Edit is its own command rather than Delete and New again**, because the order of
the table is the order on the disk: re-adding would move the volume to the bottom,
which is a change to the disk and not to the volume. It writes the **whole row** —
a merge would leave behind a filesystem the author had just cleared, and no
combination of parameters could clear it again.

**They splice lines and take a row's comments with it.** A note written above a
partition is about that partition; a move that left it behind would attach it to
whichever row slid into its place. `Get-HDTStepPartitionItem` is the shared
locator, so "which lines does `Windows` own" is answered once.

**The size is a number and a unit** — MDT's *Size* and *Size units* — and the unit
carries the format that composes it, so the window joins nothing. A percentage is
one of the units rather than a separate checkbox that then ignores the dropdown,
which is the part of MDT's dialog worth not copying.

`Get-HDTConsolePartitionRow` decides everything the tab shows, including whether
it belongs on screen: a Disk tab over `Apply OS` is a tab with nothing to say that
invites a click to find out. It shows the size **as authored** — `60%` and
`remainder` are not byte counts, and only `New-HDTDiskLayoutPlan` in front of a
real disk is entitled to say what they come to.

**Layouts live in `Get-HDTDiskLayout`'s built-ins until `workspace.yaml` exists**
(M4 introduces that document for the boot image). `Get-HDTDiskLayout -Definition`
is the hook a `diskLayouts:` block will arrive through: a supplied definition
overrides a built-in of the same name and extends the set otherwise, so nothing
has to be rewritten when M4 lands. A definition naming the role `Reserved` is
refused **by name**, so the duplicate-MSR bug cannot re-enter through the one
door it could.

The engine selects a layout by firmware unless the sequence pins one — and a
machine whose `HDTIsUEFI` was never gathered resolves to `bios-standard` **with a
warning**, rather than assuming the modern answer: an MBR disk on UEFI hardware
fails to boot loudly and immediately, while a GPT disk on a BIOS machine fails
after the image has been applied, which costs the whole deployment instead of the
first minute of it.

#### Refusing to guess which disk to wipe

`Select-HDTTargetDisk` evaluates **seven exclusion rules for every disk** and
records each reason, so a refusal prints the whole table rather than a verdict
nobody can act on. Wiping the wrong disk is the single most destructive failure
mode in this class of tool.

| # | Rule | Excludes | Overridable by `diskNumber`? |
|---|---|---|---|
| 1 | `IsSystem` or `IsBoot` | the disk this machine runs from | **Never** |
| 2 | holds a protected drive letter | the disk carrying the workspace or the log | **Never** |
| 3 | `IsReadOnly` | a disk that cannot be written | **Never** |
| 4 | `IsOffline` | a disk HDT cannot bring online | **Never** |
| 5 | existing data | a disk carrying a formatted volume | No — `wipe: true` declares it instead |
| 6 | `BusType` USB | the stick the technician booted from | Yes, with a warning |
| 7 | under the minimum size | too small to hold Windows | Yes, with a warning |

Rule 1 is absolute because the alternative — trusting the `diskNumber` an author
typed — means one wrong number in a YAML file destroys the machine running the
sequence. Rule 2 is rule 1 for the share: `DiskPartition` always passes the drive
letters of the workspace root and the log path, unconditionally. Rule 5 is
overridden by the *sequence* rather than by the number, because naming a disk
explicitly is not the same statement as declaring its contents expendable.

**No rule filters on bus type expecting a virtual value.** SPIKES S6: a
Generation 2 VM's own system disk reports `BusType = SAS`, not `SCSI` and not
`Virtual`. USB is the only bus type that excludes anything.

The `Validate` step runs the same selection with the same arguments, so a
deployment that is going to refuse refuses in the **first** step, while the
machine is still intact.

### 9.2 Apply

`DISM /Apply-Image` for WIM, `DISM /Apply-Ffu` for FFU.

**The tool, not the cmdlet, and the reason is the progress.** `Expand-WindowsImage`
writes its progress to PowerShell's *progress stream* — a console bar, not data.
Nothing in WinPE reads it and no parameter turns it into something a caller can
see, so an apply through the cmdlet is silent from the moment it starts until it
returns: on an 18 GB image that is nine minutes in which the only screen the
technician has does not change. `dism.exe` prints a percentage on stdout, which
is what MDT's LiteTouch has always driven its bar from, and §11.1 carries that
number into the log as `step.progress` — every five points, and always at 100.
`dism.exe` is also in WinPE as shipped, where the DISM *cmdlets* need the
`WinPE-DismCmdlets` optional component.

**Index selection, and its refusal.** Selectable by number, name or edition.
Each criterion is matched **independently and the results intersected**, which is
what makes `edition: ServerStandard` with `index: 2` resolve on the real Server
2025 media where the edition alone is ambiguous. `-Name` is matched **exactly
before wildcard**, because `Windows Server 2025 Standard` is both an exact name
and a prefix of another. With nothing asked for: a single-image file resolves to
that image, then a declared `defaultIndex`, and anything else is an
`HDTAmbiguousImageError` listing every index and name. **Two images matching one
request is a refusal, not a coin toss.**

`target: primary` means the `HDTOSVolume` the partition step published. A target
that resolves to nothing is a failure naming the variable and **never** a guess
at `C:`.

Post-apply, in this order:

1. **Boot files** — `bcdboot <W>:\Windows /s <S>: /f UEFI|BIOS`. This one
   failing fails the step: a machine with no boot files does not boot.
2. **The recovery image** — create `<R>:\Recovery\WindowsRE`, copy
   `<W>:\Windows\System32\Recovery\Winre.wim` into it, then
   `<W>:\Windows\System32\Reagentc.exe /setreimage /path <R>:\Recovery\WindowsRE /target <W>:\Windows`.

   **Not `reagentc /setosimage`, which this section used to say.** `reagentc /?`
   on 24H2 has no `/setosimage` verb at all, and WinPE ships no `reagentc.exe` —
   so the **applied image's own copy** is what runs (04-01's verified facts). The
   design loses to the tool. Everything about the recovery image warns and
   continues rather than failing the deployment: an image with no registered
   WinRE still boots, and 04-04 is the first thing ever to run that binary
   against an offline target from inside WinPE.
3. **The firmware boot order** —
   `bcdedit /set {fwbootmgr} displayorder {bootmgr} /addfirst`. **SPIKES S6's
   fourth finding, and a deployment is not finished without it:** a machine whose
   firmware still lists the installation media first simply reboots into WinPE,
   and the deployment appears to loop while every log says it succeeded. A
   firmware that refuses warns and continues — the machine is deployed, and the
   technician needs to be told to remove or demote the media rather than to lose
   the build.
4. **Unattend placement** — `<W>:\Windows\Panther\unattend.xml`. That is the
   location SPIKES S7 verified Setup consumes, and nothing else is verified. Its
   `oobeSystem` `AutoLogon` block configures the first logon of the deployed
   machine (§4.5.1); the `%HDTAdminPassword%` token is substituted with the run's
   deployment password, **minted at this step if nothing else made one** —
   otherwise a WinPE-half sequence with no `Restart` deploys a machine whose
   Administrator password is the literal token. Neither the document nor the
   password is written to any log at any level.

   **The computer name is validated here, and the run stops rather than the
   name being quietly changed.** The rule is `Test-HDTComputerName`, and it is
   the *only* copy of it — the wizard's computer name page (§11.2) judges every
   keystroke with the same command, so the two can never disagree about what a
   legal name is.

   | | |
   |---|---|
   | **Refused** | empty; over 15 characters; or containing `.` `\` `/` `:` `*` `?` `"` `<` `>` `\|` or a space |
   | **Warned** | anything else outside letters, digits and hyphens — legal, but not a valid DNS name |
   | **Clean** | letters, digits and hyphens, 1–15 characters |

   A refusal is `HDTConfigurationError` and stops the run. **A warning does
   not.** `HDT_01` is a legal computer name — underscore is not one of the ten
   characters NetBIOS forbids — that DNS cannot carry, so domain join and DNS
   registration may misbehave. Refusing it would stop a deployment over
   something Windows itself permits; it is recorded as a `Warning` instead, so a
   machine that later has trouble joining a domain has a log line written the
   day it was built.

   *This corrected an earlier, stricter rule that refused anything but letters,
   digits and hyphens outright.* That conflated the NetBIOS rule with the DNS
   one and refused legal names — and a wizard that refuses a name Microsoft's
   own documentation permits is arguing with the documentation in front of the
   technician reading it. The **space** is refused with the ten even though it
   is not on that list: a computer name cannot contain one, and a trailing space
   is invisible everywhere a technician would look for it.

   The 15-character limit is the half that came from a real deployment. SPIKES
   S9.11: the first real one reported `Succeeded` on all five steps and produced
   a machine called `WIN-N91191NN153`, because `rules.yaml`'s
   `PC-%HDTSerialNumber%` fallback resolved to 35 characters on a VM and
   **Windows Setup discarded it without complaint**. HDT does not truncate: a
   silently shortened name is the same failure with a different spelling. Where
   one machine needs a name the rules would not give it, that is what the
   per-machine override of §3.1 is for.

5. **Recovery registration is not what makes WinRE work.** `SetRecoveryImage`
   runs the applied image's own `Reagentc.exe /setreimage` against an offline
   target, and SPIKES S9.7 found that it **exits 0, prints "Operation
   Successful" and registers nothing** — `/info` on the same target still reports
   `Windows RE status: Disabled`. It does not refuse; it reports success. WinRE
   on the deployed machine is enabled by Setup during specialize/oobe from the
   `Winre.wim` the apply leaves in `Windows\System32\Recovery`. This is why the
   step warns and continues rather than treating the call as load-bearing.

### 9.3 Capture

A reference-image sequence: build -> customize -> `Sysprep` step -> `Restart`
step -> boot to WinPE -> `CaptureImage` step -> WIM written to `Captures\`.
`Import-HDTOperatingSystem` then promotes a capture into the OS catalog. This
closes the loop so HDT builds its own reference images rather than depending on
another tool.

1. **The `Sysprep` step runs `/quiet /generalize /oobe /quit`. Never
   `/shutdown`.**

   *Revised 2026-08-31. This section previously specified
   `/generalize /oobe /shutdown`, in six lines with no reasoning attached.* The
   switch is not a style choice, and `/shutdown` makes the step untestable by
   construction: the machine powers off inside the call, so the step never
   returns, never reports success, and cannot check anything about what sysprep
   actually did. A step whose only outcome is "the power went out" is a step
   that reports the same thing whether it worked or not.

   MDT settled this years ago and the evidence is in its own scripts.
   `LTISysprep.wsf:257` builds
   `%SystemRoot%\system32\sysprep\sysprep.exe /quiet /generalize /oobe /quit`,
   appending `/unattend:%SystemRoot%\system32\sysprep\unattend.xml` when one has
   been staged, and deleting that unattend afterwards so the answer file does
   not travel inside the captured image.

2. **The step verifies `ImageState`, because sysprep's exit code is not
   enough.** After the call returns, the step reads

   ```
   HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State\ImageState
   ```

   through `IRegistryService` and fails unless it is
   `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`. The failure message names
   `%SystemRoot%\system32\sysprep\panther\setupact.log`, which is where the
   reason actually is. `LTISysprep.wsf:272-278` does exactly this, and it is
   there because sysprep can return 0 having declined to generalize.

   This is the same failure family as §9.2's fifth note: `reagentc /setreimage`
   **exits 0, prints "Operation Successful" and registers nothing**. A tool that
   reports success is not evidence that the thing happened. Where an external
   tool leaves a readable trace of its own result, the step reads the trace, not
   the exit code.

3. **The reboot is a separate `Restart` step returning `RebootRequested`.** The
   flow above already says so - the `Sysprep` step leaves the machine running,
   the existing restart machinery of §4.3 and §4.5 takes it to WinPE, and the
   `CaptureImage` step resumes there. No new reboot path is written for capture,
   which is the whole reason `/quit` is the right switch: `/shutdown` would
   bypass the checkpoint the resume depends on.

4. **A generalized machine must not boot back into Windows.** Between the
   `Sysprep` step and the capture there is exactly one legal next boot, and it
   is the boot media. Booting the generalized installation instead runs OOBE,
   consumes one of the three rearms, and leaves an image that is no longer in
   the state it was sysprepped into - and nothing about it looks wrong
   afterwards.

   *Revised 2026-08-31. This section previously prescribed
   **`setBootOrder: false`** on the reference sequence's `ConfigureBoot` step.
   That was measured wrong on the same day: with it false the machine restarted
   at restart 1 straight back into WinPE and the run stopped at step 8 of 12 —
   SPIKES S6's fourth finding word for word, with no
   `Windows\Panther\setupact.log` on the disk afterwards, so Windows had never
   started at all. Both `Templates/reference.yaml` and the lab sequences now
   carry `setBootOrder: true` and reject the old value.*

   The mistake was reaching for the firmware order at all. A reference build
   needs **two** different next boots — restart 1 must reach Windows, because
   that is the only window in which applications install and `Sysprep` can run;
   restart 2 must reach WinPE, because a volume with Windows running on it is a
   volume being written while it is read — and one firmware-order switch cannot
   serve both. `New-HDTImageService`'s `SetBootOrderFirst`
   (`bcdedit /set {fwbootmgr} displayorder {bootmgr} /addfirst`) exists for the
   SPIKES S6 reason recorded on it, and turning it off to buy the second boot
   silently cost the first.

   So the firmware order is left alone entirely and the **Windows boot manager**
   does the work, which is MDT's answer (`LTIApply.wsf /PE /STAGE` and `/PE
   /BCD`, driven by `ZTIBCDUtility.vbs`). The `BootToWinPE` step stages a copy of
   the share's boot image to `<volume>\HDT\Boot`, points a ramdisk BCD entry at
   it, and hands that entry the **next boot and only the next boot** through
   `bcdedit /bootsequence`. `setBootOrder` goes back to `true`, so restart 1
   reaches Windows and the one-shot fires at restart 2.

   **Nothing is sealed until we know it can come back.** The `BootToWinPE` steps
   run *before* `Sysprep` and fail the sequence rather than warning: a machine
   that has been generalized and cannot reach WinPE is stranded, with no leg left
   that could fix it, and OOBE on the next boot burns one of the three rearms.

5. **`Captures\` is one of only two folders the deployment account may write,
   and the write is proved before sysprep runs.** §2.1 makes the workspace
   read-only during deployment except for `Logs\` and `Captures\`, and
   `Test-HDTShareAcl` checks exactly that pair. `CaptureImage` is the first real
   consumer of the second one.

   The check goes **before** the `Sysprep` step, not at the moment of writing.
   A reference build is hours of installing and customizing; discovering at the
   end of it that the account cannot write `Captures\` costs the whole run, and
   costs it after the machine has already been generalized and can no longer be
   picked up where it left off. The cheap test is a write probe against
   `Captures\` while the machine is still an ordinary running Windows.

   *Which means the `Sysprep` step performs it, not the `CaptureImage` step -
   an earlier draft of this note said "the capture step verifies", and the
   capture step physically cannot: it runs in WinPE, after the reboot, after the
   machine has already been sealed.* `Test-HDTCaptureTarget` is therefore a
   shared private helper that both steps call - `Sysprep` at the point of no
   return, where the answer is still cheap, and `CaptureImage` at its own start,
   because a sequence may reach a capture without having passed through a
   sysprep. One function, so the early answer and the late one cannot drift; it
   refuses the `Local` provider before probing anything, for note 6's reason.

6. **On media, capture refuses.** Under the `Local` provider the deploy root is
   a read-only disc, `Captures\` cannot be written at all, and there is no
   correction a technician could make - the same reasoning M7's carried-over
   note 3 gives for the log copy-back. The step fails with what is actually
   wrong rather than attempting a write that cannot succeed.

7. **Every capture passes an exclusion list, and HDT's own working tree is on
   it.** DISM takes `/ConfigFile:`, and MDT passes one on every capture -
   `ZTIBackup.wsf:427` resolves `<DeployRoot>\Tools\<Architecture>\wimscript.ini`
   and both the `/Capture-Image` and `/Append-Image` branches quote it in. Without
   one, a capture swallows `pagefile.sys`, `hiberfil.sys`,
   `System Volume Information` and the deployment's own scratch folders into the
   reference image.

   HDT ships its list as `Templates\Capture\wimscript.ini` inside the module, so
   it travels into every boot image with the rest of `Templates\` and there is no
   list of filenames anywhere that could disagree with the directory. A share may
   override it with `Control\wimscript.ini`; the step prefers the share's copy
   when there is one and falls back to the module's, so a share created before
   this existed still captures correctly.

   **The HDT-specific entries are the point of the file.** `\HDT` is excluded
   because HDT put it there: `Copy-HDTResumeAgent` stages the resume agent to
   `<osvolume>\HDT`, and the WinPE leg copies its log to `<osvolume>\HDT\Logs`
   before restarting. Both are on the volume being captured at the moment it is
   captured, and neither belongs in a reference image - an image carrying a
   resume agent and one machine's deployment log would re-run somebody else's
   deployment state on every machine built from it. MDT's equivalents, `\MININT`
   and `\_SMSTaskSequence`, are not carried across: rule 4.

---

## 10. Full-OS configuration steps

Three steps that run after the image is applied and the machine has rebooted
into Windows. All are `runIn: FullOS`.

### 10.1 Windows Update  ·  **DEFERRED TO v2**

> **Not the same thing as §7.5, and the names are close enough to be worth
> separating.** This section is the ONLINE step: full-OS, after the machine
> has rebooted into Windows, talking to WSUS or Windows Update through the
> Windows Update Agent COM API, looping until nothing more is applicable. It
> is still deferred.
>
> **§7.5 is offline injection** — `.msu` packages an administrator imported,
> pushed into the applied volume in WinPE before the machine has ever booted.
> It needs no network, no server and no reboot loop, it is built, and it is
> what MDT's Packages node did. The two are complementary: §7.5 gets a machine
> to the last cumulative update somebody downloaded, §10.1 would get it to
> whatever came out this morning.

> **v2, not cut.** Scheduled out of v1 on 2026-08-16 at the user's direction.
> The section is kept in full so v2 starts from a written plan rather than a
> memory, and the step type is additive — bringing it back adds files rather
> than changing them. What deferring it costs is in §1's deferred list.

**Decision: online updating during deployment**, against WSUS or Windows Update
— MDT's `ZTIWindowsUpdate` model. Machines leave the bench current without HDT
owning a servicing pipeline.

```yaml
- name: Windows Update
  type: WindowsUpdate
  server: "%HDTWSUSServer%"        # optional; omit for Windows Update / policy default
  categories: [SecurityUpdates, CriticalUpdates, UpdateRollups]
  exclude: ["*Preview*", "KB5001234"]
  maxPasses: 3
  continueOnError: true
```

- **Implementation** uses the Windows Update Agent COM API
  (`Microsoft.Update.Session`) directly — search, download, install. No
  third-party module dependency, and it is the same interface MDT uses, so its
  behavior in a deployment context is well understood. WUA is unavailable in
  WinPE; this step is full-OS only and validation rejects it elsewhere.
- **Multiple passes are the norm.** Installing one update can supersede or
  reveal another, so the step loops — search, install, reboot if required,
  search again — until a pass returns nothing applicable or `maxPasses` is hit.
  A single-pass Windows Update step is the classic MDT mistake that leaves
  machines partly patched. Reboots inside the loop use the same resume
  machinery as any other restart (§4.3, §4.5).
- **`continueOnError: true` is the recommended default.** Windows Update is the
  least predictable thing in a sequence, and a failed optional update should not
  scrap an otherwise good build. The result is recorded either way.
- **Duration is unpredictable** — this is the accepted cost of the online model.
  The step logs per-update timing so a slow deployment can be explained
  afterward, and `timeoutMinutes` bounds it.
- **Placement**: conventionally run twice — once before applications, once after
  — since app installs can pull in updatable components. The sample sequences
  do this.

### 10.2 Roles and features (Windows Server)

**Server deployment is in v1.** The `InstallRoles` step wraps
`Install-WindowsFeature`:

```yaml
- name: Install Roles
  type: InstallRoles
  features: [Web-Server, Web-Mgmt-Console, NET-Framework-45-Core]
  includeManagementTools: true
  source: "%DeployRoot%\\Sources\\SxS"   # for features needing side-by-side source
```

- Feature names are validated against the target OS **at authoring time** where
  possible and at step start otherwise — a typo'd feature name should fail fast
  with the list of valid names, not halfway through a server build.
- Some features require a source path (the classic .NET 3.5 case); `source`
  resolves through the content provider (§6) so it works identically from share
  and from standalone media.
- Reboot-required results feed the normal restart/resume path.

Consequence for the rest of the project: server images, at least one server task
sequence in `samples/`, and a Windows Server VM in the E2E matrix.

### 10.3 BitLocker

**In v1, as a full-OS step, with the encryption scope selectable.**

```yaml
- name: Enable BitLocker
  type: EnableBitLocker
  drive: C:
  scope: usedSpaceOnly            # usedSpaceOnly | full
  method: XtsAes256               # Aes128 | Aes256 | XtsAes128 | XtsAes256
  protector: tpm                  # tpm | tpmPin | tpmStartupKey
  recoveryPassword: true
  escrow: ad                      # ad | entra | none
  wait: false                     # false = let encryption continue in background
```

The `scope` option is the one that matters operationally:

- **`usedSpaceOnly`** encrypts only blocks currently in use. On a
  freshly-deployed machine this is not a security compromise — the free space
  has never held plaintext data, because the volume was created minutes ago by
  `DiskPartition`. It is dramatically faster on large disks.
- **`full`** encrypts the entire volume including free space. Correct when the
  disk was *not* freshly wiped, or when a compliance standard requires it
  regardless.

Default is `usedSpaceOnly`, since HDT only ever deploys to a volume it just
created (§1, wipe-and-load only) — the one scenario where it is unambiguously
the right choice. The doc states the reasoning so an admin choosing `full` for a
compliance reason is making an informed decision rather than guessing.

Other behavior: key escrow to AD (`Backup-BitLockerKeyProtector`) or Entra
(`BackupToAAD-BitLockerKeyProtector`) is verified before encryption starts — a
machine that encrypts without a recoverable key is worse than one that is not
encrypted. `escrow: none` is allowed but warns. With `wait: false` the step
returns once encryption is underway rather than blocking the sequence for
however long the disk takes.

WinPE pre-provisioning (encrypt-before-apply) remains post-v1; it is faster
still but needs TPM state handling in WinPE, and `usedSpaceOnly` recovers most
of the benefit for none of the complexity.

---

## 11. Technician UI, in WinPE

Two surfaces, both WPF running inside WinPE, both shipping in the boot image:
the **wizard** that collects what the deployment still needs, and the
**progress window** the technician watches while it runs. PSD demonstrates that
WPF works in WinPE, so this is a known-feasible path rather than a research
project — it needs `WinPE-NetFx`, which HDT already injects (§5.1).

Neither is optional decoration. A bare `X:\Windows\system32>` prompt is what
HDT showed before this section existed, and it tells a technician standing at a
bench nothing at all: not which machine, not which sequence, not whether it is
working or hung.

### 11.1 The progress window

**MDT's shape, on the wallpaper**, shown from the moment the engine starts
until it hands over to the full OS. It displays: computer name, task sequence
name, the current step and its group, **what the step is doing right now**,
**step N of M**, a progress bar, elapsed time, and the current phase (WinPE or
Full OS).

**The activity line is which one of the many.** "Install Applications" is one
step and eleven installers; every step that loops writes what it is on
(`installing 1 of 2: Acrobat Acrobat Reader DC`, `staging Latitude 5420: 64%`,
and a heartbeat's `… - still running after 45s`), and the card shows that
message unchanged. It is blank between steps, because a finished step's last
line under the next step's name states something that is no longer true.

**Elapsed is the CURRENT STEP's, and the window runs it against its own clock.**
It was derived from the log like everything else — summed from the records' own
timestamps — and it therefore advanced only when something wrote a record, so on
a quiet step it was frozen by construction. `Get-HDTDeploymentProgress` reports
the step's start time instead and the window subtracts it from `UtcNow` on its
repaint timer. It is the step's rather than the run's because the run cannot be
measured across the reboot: WinPE's unsynchronised clock is corrected there,
routinely backwards, whereas the step running now was stamped by the same clock
the window is reading, so the skew is on both sides and cancels.

**The card is MDT's** — LiteTouch shows a modest centred "Installation Progress"
dialog and an admin has watched it a thousand times; a full-screen takeover of
numbers reads as a kiosk rather than as a deployment.

**The backdrop it used to stand on is gone, and the reason it existed expired.**
Two earlier drafts of this section said "full-screen" outright, because behind
the window was a console the payload hid only for the wizard, and around a bare
dialog a technician would have seen the black edges of a half-drawn
`X:\Windows\system32>` prompt. `Start-HDTDeployment` now hides that console at
step 4a for the whole run, and a boot image carrying BGInfo paints the machine's
serial, model and address onto the wallpaper — so a full-screen ground had
become a sheet covering the very thing it was invented to protect anybody from
seeing. MDT solves this with a deployment wallpaper, and so, now, does HDT: the
card, centred on the wallpaper, and nothing else.

This is a property of **every** window the boot image ships, not of this one.
`HDTFailure.xaml` was full-screen for the same reason and is a card for the same
reason; the wizard, the Welcome screen and the boot status panel were already
sized. A contract iterates the boot image's markup and refuses `Maximized`
anywhere in it, rather than naming the two files that used to be.

**It is driven by the JSONL event stream, not by a parallel progress API.**
The engine already emits `step.start`, `step.complete`, `step.fail`, `step.skip`
and `phase.change` with a controlled vocabulary (§4.4.2). The UI subscribes to
that stream and renders it. There is exactly one source of truth for what the
deployment is doing, so the screen and the log can never disagree — and a step
author gets progress for free without calling a UI function.

The UI runs in its **own runspace**. The engine must never block on rendering,
and a UI fault must not take the deployment with it.

**It must degrade to the console.** If XAML fails to load — a boot image built
without the right components, an exotic display, a serial console — the engine
logs the reason and writes styled console lines instead, then carries on. A
deployment that refuses to run because it cannot draw a progress bar would be a
worse toolkit than one with no progress bar at all. A contract test asserts the
fallback path is taken when WPF is unavailable, because the fallback is exactly
the path nobody exercises until the night it matters.

`HDTSkipProgress` suppresses the window entirely for unattended runs.

### 11.2 The wizard, and skipping every page of it

The wizard collects what the rules could not supply. It follows MDT's model
exactly, because it is the model admins already know: **every page is
individually skippable.** Populate the values *and their skip variables* in
`rules.yaml` (or a per-machine `Control\machines\<UUID>.yaml`) and the
technician sees no wizard at all — the deployment goes straight to the progress
window. `Get-HDTWizardPage` is what decides, and `Get-HDTWizardSummary` prints
the exact file to paste at the end of a manual run.

**The skip variable decides, not the presence of a value.** This is MDT's
behaviour — `OSDComputerName` being set does not hide the page, `SkipComputerName`
does — and the difference is load-bearing: a *prefilled page the technician
confirms* is a real workflow, and a rule-guessed name is precisely the one worth
confirming. SPIKES S9.11's machine was named by a rule nobody checked. An earlier
draft of this section also said "a page whose values are all supplied never
appears", which contradicts the paragraph below and would have removed
confirmation entirely; the skip variable is the rule.

| Page | Collects | Skip variable | MDT |
|---|---|---|---|
| Task sequence | Which sequence to run | `HDTSkipTaskSequence` | `SkipTaskSequence` |
| Computer details ¹ | `HDTComputerName` | `HDTSkipComputerName` | `SkipComputerName` |
| ” same page ” | `HDTJoinDomain`, `HDTMachineObjectOU`, or `HDTJoinWorkgroup` | `HDTSkipDomainMembership` | `SkipDomainMembership` |
| Credentials | Share credentials, when not embedded (§6.3) | `HDTSkipCredentials` | `SkipBDDWelcome` in part |
| Applications | Which apps to install | `HDTSkipApplications` | `SkipApplications` |
| Locale and time | `HDTTimeZone`, locale | `HDTSkipTimeZone`, `HDTSkipLocaleSelection` | same names |
| ~~Admin password~~ | **NOT A PAGE.** `HDTAdminPassword` is set in the console's New Task Sequence window (MDT's placement) and resolves through the rules like any other variable. §4.5.4 | — | `SkipAdminPassword` |
| Summary | Confirm before anything destructive | `HDTSkipSummary` | `SkipSummary` |

¹ **Name and domain membership are one page**, as they are in MDT's "Computer
Details" pane — one decision about a machine's identity, and the screen an MDT
admin already knows. It keeps **both** skip variables, because MDT does: they
hide the two halves independently, through the same pane-visibility mechanism
`Get-HDTWizardSkip` already uses for the Welcome screen.

**There is no product key page either, and it needs none (user, 2026-08-25).**
`HDTProductKey` is a variable like every other — MDT's `ProductKey` in
`Get-HDTVariableMap` — so a site sets it in `rules.yaml`, per model or per
machine, or a sequence sets it with a `SetVariable` step. `ApplyUnattend`
substitutes it into `<ProductKey>` and **removes the element entirely** when it
resolves empty, which is what makes a keyless deployment work without a second
template. A page would add a screen to type by hand what a rule already knows
per model, which is the opposite of what the rules engine is for.

`HDTSkipWizard: true` skips all pages at once — the unattended case.

**The Welcome screen is not skippable from this file.** It runs *before* the
share is reachable, so `HDTSkipWelcome` lives in `bootstrap.json` inside the boot
image (§11.2's own correction, and MDT's split: `SkipBDDWelcome` is in
`Bootstrap.ini`, every other `Skip*` in `CustomSettings.ini`). A `rules.yaml`
that hides every wizard page still meets a Welcome screen unless the image was
built with a credential and without `-PromptForCredential`.

**A skipped page whose values are still missing is an error, not a prompt.**
If `HDTSkipComputerName` is set and no rule supplies `HDTComputerName`, the
deployment fails at validation with a message naming the variable and the file
that should have set it. Silently inventing a value, or quietly showing the page
anyway, both produce deployments nobody can reproduce.

Every value the wizard collects enters the variable engine as the
**command-line/wizard source** — the highest precedence in §3.1 — and is
recorded in provenance like any other, so the report can say a name was typed
rather than derived.

### 11.3 The failure screen

**A machine that failed used to tell the person standing in front of it
nothing.** The reason went into the JSONL, a `FATAL` line went into a console
the payload had hidden to put a window on screen, and five seconds later
`wpeutil` powered the machine off. Everything needed to fix it was on a share,
in a folder named after a computer that never finished being built. MDT shows a
summary dialog naming the step that failed; this is HDT's.

`Get-HDTDeploymentFailure` derives it from the same JSONL stream the progress
window reads — one source of truth, so the screen and the log cannot disagree —
and `Show-HDTDeploymentFailure` shows `HDTFailure.xaml` through the ordinary
wizard host. **The reason is never summarised:** "disk 0 carries existing data
on volume C (NTFS), D (NTFS), and the step did not declare that it may be
replaced" *contains the fix*, and shortening it to "disk error" would send a
technician to the log to read the rest.

**Three buttons on a FAILURE, and the machine obeys whichever was pressed:**

| Button | What the machine does |
|---|---|
| **Open CMD** | opens a prompt and **stays running** — the technician is going to look |
| **Restart** | `wpeutil reboot`, to try again from the top |
| **Shut down** | `wpeutil shutdown`, they are finished with this machine |

**A SUCCESS gets one, and it is Finish** — MDT's Deployment Summary. All three
above are collapsed, Open CMD included: a machine that finished has nothing left
to diagnose, and a prompt offered under a green headline invites a technician to
go looking for a problem that is not there. F8 still opens one on both screens,
because a key nobody can see is not clutter.

**It appears only when a display was opened.** A run with no window is a run
nobody is standing at, and an unattended deployment must not wait for a keypress
that will never come — the zero-keystroke E2E proof depends on it ending by
itself. A boot image without `WinPE-NetFx` cannot draw the screen at all, and
that must not become a second failure: the attempt is caught, `Shown` comes back
false, and the machine ends as it would have.

**A deployment that SUCCEEDED restarts** into what it built, which is what MDT
does and what `ConfigureBoot` has already arranged by putting the Windows Boot
Manager first. **A failed one shuts down**, because a failed run has usually not
applied an image and a restart would boot the media again and deploy for a
second time, in a loop nobody is watching.

### 11.4 What this is not

It is not the admin console (§12). That is a WPF app on an administrator's
workstation for authoring the workspace. This is three screens inside WinPE on
the machine being deployed. They share only XAML skills.

---

## 12. Admin console (WPF)

The console is a **thin client over the module**. Rule: the console may not do
anything the cmdlets can't. Every action it performs maps to a cmdlet
invocation, and the console shows that invocation — so an admin can learn the
automation surface by clicking around, and script anything they can do in the UI.

- **Stack:** WPF on .NET 8, MVVM, hosting PowerShell via the
  `Microsoft.PowerShell.SDK` runspace API. Long operations (image build, driver
  import) run on a background runspace with progress streamed to the UI.
- **Layout:** tree navigation mirroring the workspace (Operating Systems, Task
  Sequences, Applications, Drivers, Media, Monitoring) — deliberately close to
  Deployment Workbench so muscle memory transfers.
- **Task sequence editor:** a step tree with a properties pane, editing
  `sequence.yaml` in place. **Reordering is by button, not by drag-and-drop**
  (decided 2026-08-24): `Move-HDTConsoleStep` is the operation, and a drag is
  a second way to invoke it that a technician cannot see, cannot undo halfway,
  and cannot read off the footer as a cmdlet — which is the one thing every
  action on this window is required to do. Comments and key order in the YAML are
  preserved on round-trip; a UI that reformats the file breaks git review, which
  is one of the reasons config-as-code fails in practice.
- **Monitoring view:** tails `Logs\_active\`, showing in-flight deployments,
  current step, and elapsed time; opens the full report on completion.
- **Validation:** the same JSON Schemas the cmdlets use, surfaced inline.

The console ships as a separate solution in the repo and is **optional** — the
module is fully usable without it, including on a headless server.

---

## 13. Cross-cutting concerns

### 13.1 Error handling

Engine code sets `$ErrorActionPreference = 'Stop'` and wraps each step in a
single try/catch that classifies failures as `Transient` (retry per the step's
`retry` policy), `Configuration` (bad authoring — fail fast, point at the file
and line), or `Environment` (hardware/network — fail with diagnostics attached).
Native tool exit codes are checked explicitly; `$LASTEXITCODE` is never assumed
to be zero.

### 13.2 Test-driven development

**HDT is written test-first.** Pester 5 is the framework. The working loop is
red → green → refactor, at the granularity of one behavior:

1. Write a `Describe`/`It` that states the behavior in domain language
   ("resolves `HDTComputerName` from the per-machine override in preference to a
   matching rule"). Run it. Watch it fail for the right reason.
2. Write the smallest implementation that passes.
3. Refactor with the suite green.

**No production function is written before a failing test exists for it.** The
exception is thin adapters around external tools (§13.2.3), which are kept small
precisely because they can't be unit tested.

#### 13.2.1 The testability rule this imposes

A step implementation may not call DISM, CIM, the filesystem, or the network
directly. It receives those through injected service objects
(`IDiskService`, `IImageService`, `IContentProvider`, `ICimProvider`,
`IFileSystem`) that are trivially faked in a test. Concretely, this is why
§6 defines content access as a provider interface and why §4.2 gives every step
type the same `Test-Applicable` / `Invoke-Step` shape — both fall out of wanting
the logic tested without a machine attached.

The design goal is that **the entire task sequence engine can execute a full
sequence end-to-end in a Pester run** against fake services, asserting the
ordered list of operations it *would* have performed. That test is the safety
net for every refactor after it.

#### 13.2.2 The testing pyramid

| Layer | What it covers | Runs |
|---|---|---|
| **Unit** (majority) | Rule evaluation and provenance, variable precedence, driver ranking, app dependency sort, disk layout planning, condition evaluation, resume/skip logic, media content projection | Every save; seconds |
| **Contract** | Every sample YAML validates against its schema; every step type implements the step contract; every content provider satisfies the provider contract | Every push |
| **Integration** | Real DISM against a scratch VHDX, real WIM apply/capture, real driver `.inf` parsing, boot image build | Every push (Windows runner with ADK) |
| **End-to-end** | `Test-HDTDeployment` harness: provision a Hyper-V VM, PXE-boot it against a scratch workspace, run a sequence, assert the end state | Nightly + pre-release |

The E2E layer is slow and is not where correctness is established — it exists to
catch the integration seams that fakes hide. When an E2E test finds a bug, the
fix starts by reproducing it at the unit layer.

#### 13.2.3 Test doubles and boundaries

- **Fake, don't mock, the services.** Hand-written fakes (an in-memory
  filesystem, a fake disk service that records operations) produce readable
  failures. `Mock` is reserved for the adapter boundary.
- **Adapters stay dumb.** `Invoke-HDTDism`, `Get-HDTCimFact`, and friends contain
  no branching — just argument construction and exit-code checking — so the risk of
  the untested code is bounded and visible.
- **Test data lives in `tests/fixtures/`**: real `.inf` headers, real
  `Win32_ComputerSystem` shapes captured from actual hardware, sample workspaces.
  Facts are captured from real machines rather than invented, so the fakes stay
  honest.

#### 13.2.4 Definition of done

A change is done when: a test existed before the code; the full unit + contract
suite is green; new public cmdlets have comment-based help and at least one test
per documented behavior; PSScriptAnalyzer is clean; and coverage of the engine's
decision logic has not regressed. Coverage is a signal, not a target — an
untested `if` in the rule engine matters, an untested line in a DISM adapter
does not.

#### 13.2.5 CI

Unit + contract + PSScriptAnalyzer on every push (Windows runner). Integration
on every push to `main` and on PRs touching imaging or driver code. E2E nightly.
A red suite blocks merge.

### 13.3 Versioning and compatibility

Workspace content carries `schemaVersion`. The module refuses to operate on a
workspace newer than it understands and offers `Update-HDTWorkspace` for older
ones. Boot images record the engine version they contain; a version mismatch
between boot image and share is a warning at deploy time, since it is a common
cause of confusing failures.

---

## 14. What HDT deliberately does differently from MDT

| MDT | HDT | Why |
|---|---|---|
| VBScript/WSH engine | PowerShell 5.1 | Maintainable, debuggable in-place, no HTA |
| `CustomSettings.ini` + `Priority=` chains | Ordered `rules.yaml`, first-match-wins | Same power in practice; comprehensible |
| MDT SQL database | File-based per-machine overrides, pluggable provider | Removes a server dependency for the 90% case |
| Cleartext creds in `Bootstrap.ini` | Prompt by default; encrypted opt-in; least-privilege account | Narrows a known exposure |
| Autologon with a fixed cleartext password, cleanup as a step | Autologon (same model) with a per-deployment random password in an LSA secret, `AutoLogonCount` bound, teardown in `finally` + boot-time reconcile | Keeps the interactive session MDT needs; removes the cleartext reuse and the "failed deployment left it armed" hole |
| No app detection | Detection rules per app | Idempotent reruns |
| `BDD.log` in CMTrace | Structured JSONL + HTML report + provenance | Answers "why did it choose that?" |
| Separate offline media build | Media is a projection of the share | One engine, one code path |
| Opaque boot image contents | Recorded build manifest | Eliminates boot image drift |
| Resume via a `PSDStartup.lnk` in the all-users Startup folder, `RunOnce` only for Server Core / `HideShell` | `RunOnce` re-registered each leg, always | A shortcut persists, so a crash mid-leg re-runs the deployment on the next logon — the loop §4.5 already refuses. `RunOnce` is consumed before it runs, so a crashed leg stops and the boot-time reconcile disarms it as abandoned. It also needs no shell, so Core and hidden-shell machines resume on the same path as everything else. See §4.5.1 |
| Deployment logs end in `%WINDIR%\TEMP\DeploymentLogs` (`LTICleanup`) | `%WINDIR%\Logs\HDT` | `Temp` is a directory Windows itself cleans out, and these are the only record of how a machine was built. Everything else about the cleanup is MDT's: it runs on success only, the logs move before the agent folder is removed, and a failed machine keeps all of it. See `Remove-HDTResumeAgent` |
| Full-screen progress and failure screens | Cards sized to their content, on the wallpaper | The full-screen ground existed to hide a WinPE console that is now hidden for the whole run; it had become a sheet over the BGInfo the boot image paints. See §11.1 |

---

## 15. Open questions

All resolved except one.

1. ~~**Unattended PXE credentials.**~~ **Resolved:** embedded in the boot image,
   the `Bootstrap.ini` model, mitigated by an enforced least-privilege account
   check (§6.3).
2. ~~**Secure Boot + iPXE.**~~ **Resolved:** WDS is the v1 PXE path (§6.1).
   iPXE is deferred post-v1.
3. ~~**USMT scope.**~~ **Resolved:** out of scope permanently (§1). Wipe-and-load
   only.
4. ~~**Windows Update during deployment.**~~ **Resolved:** online, against WSUS
   or Windows Update, multi-pass (§10.1) — **and, since 2026-09-01, offline
   injection as well (§7.5).**

   > **This reverses a settled decision, and the sentence it reverses is kept
   > rather than deleted.** Until 2026-09-01 this line ended "No offline
   > servicing pipeline", and that was the right call for what it was
   > deciding: HDT was not going to own a *pipeline* — a scheduled
   > patch-and-recapture workflow that keeps a reference image current (open
   > question 7). It still does not.
   >
   > What changed is that the user asked for MDT's **Packages** node, which is
   > a smaller thing wearing a similar name: an administrator downloads a
   > `.msu`, imports it, and the sequence injects it into the applied volume
   > before first boot. No schedule, no recapture, no server. The online
   > §10.1 step and this are different features that happen to share a
   > subject, and §7.5 says which is which.
   >
   > The cost of *not* having it was the reason: with the online step deferred
   > to v2, a machine HDT built left the bench carrying exactly the patches
   > its source image carried — which for the staged LTSC 2024 media is
   > 10.0.26100.1742, September 2024. Offline injection closes that without
   > waiting for v2.
5. ~~**Server OS support.**~~ **Resolved:** in v1. `InstallRoles` step, server
   sample sequence, server VM in the E2E matrix (§10.2).
6. ~~**BitLocker.**~~ **Resolved:** in v1 as a full-OS step with selectable
   `scope: usedSpaceOnly | full` (§10.3). WinPE pre-provisioning is post-v1.
7. **Reference image pipeline.** *Still open.* Is capture (§9.3) enough — build
   a reference image by hand when you need one — or does HDT need a scheduled
   "patch and recapture monthly" workflow? This matters more now that updating is
   online (§10.1): a stale base image means every deployment spends longer in
   Windows Update. Deferrable — it changes nothing structural, and the answer
   gets clearer once real deployment times are measured. Revisit after M6.

---

## 16. Naming and repo conventions

### 16.1 Command naming — mandatory

**Every PowerShell command in HDT is named `Verb-HDTNoun`.** No exceptions:
public cmdlets, private helpers, adapters, test helpers, and build functions all
carry the prefix. `HDT` is uppercase, always.

```
New-HDTWorkspace        Import-HDTDriver         Invoke-HDTTaskSequence
Update-HDTBootImage     Get-HDTDriverCoverage    ConvertTo-HDTReport
New-HDTMedia            Invoke-HDTDism           Get-HDTCimFact
```

Rationale, and why it applies to private functions too: the engine runs inside
WinPE and inside a live OS alongside whatever else is loaded, and it dot-sources
extension scripts from `Scripts\` and third-party step types from `Modules\`.
An unprefixed `Get-Facts` or `Invoke-Dism` in that environment is a collision
waiting to happen, and the collision surfaces at 3 a.m. on a machine with no
debugger. A uniform prefix also makes `Get-Command *HDT*` a complete inventory
of the toolkit.

Enforcement is a **contract test**, not a review convention: the suite
enumerates every function the module defines and fails on any name not matching
`^[A-Z][a-zA-Z]*-HDT[A-Z]`, matched case-sensitively, and on any verb outside
`Get-Verb`. The verb allows interior capitals because the approved two-word verbs
(`ConvertTo`, `ConvertFrom`, `WaitFor`) contain one — `^[A-Z][a-z]+` would reject
`ConvertTo-HDTReport`, which this section blesses three lines above — so the real
constraint on the verb is membership of `Get-Verb`, checked with exact case,
rather than the character class alone.

The manifest's `DefaultCommandPrefix` is deliberately **not** used to achieve
this — it only applies on import, so the prefix would vanish when the engine
dot-sources its own files in WinPE. The prefix is written into every function
name at the source.

### 16.2 Other conventions

- Module: `Hephaestus`.
- Repo layout: `src/Hephaestus/` (the one module - engine and WPF console
  alike), `schemas/`, `tests/`, `docs/`, `samples/`.
- All public cmdlets: comment-based help, `[CmdletBinding()]`,
  `SupportsShouldProcess` on anything destructive (`DiskPartition`, workspace
  writes, media generation).
- Style: PascalCase functions, approved verbs only, singular nouns, no aliases
  in committed code, `Set-StrictMode -Version Latest` in the engine.
