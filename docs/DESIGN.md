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
  rather than reaching for hardware and UNC paths mid-function. See §12.2.

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
| **Driver** | Out-of-Box Drivers | `.inf` set + derived `driver-index.json` |
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
  Drivers\
    Dell\Latitude 7450\
      <inf tree>
    driver-index.json         # generated: PnP ID -> driver path map
  Scripts\                    # user extension points (.ps1)
  Modules\                    # engine payload staged to clients
  Logs\                       # per-deployment logs, if logging to share
  Captures\                   # sysprepped WIMs land here
  Control\
    machines\                 # per-machine variable overrides, <UUID>.yaml (optional)
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

1. **Command line / media prompt** — what the technician typed.
2. **Per-machine override** — `Control\machines\<UUID>.yaml`, if present. This is
   the MDT-database equivalent, but file-based; a SQL or REST provider can be
   plugged in later behind the same interface.
3. **Rules** — `rules.yaml`, first-match-wins per variable (§3.3).
4. **Gathered facts** — hardware, firmware, network (§3.2).
5. **Sequence defaults** — declared in `sequence.yaml`.

Higher entries win. Every variable resolution records *which* source set it,
and that provenance is written to the log — the single biggest debugging pain in
MDT is not knowing why `HDTComputerName` ended up as it did.

### 3.2 Naming: HDT takes MDT's variable set, under its own prefix

HDT provides **the same variables MDT does, meaning for meaning**, so an admin's
existing knowledge and runbooks carry over. But every one is **prefixed `HDT`**:

| Prefix | Meaning | Writable? |
|---|---|---|
| `_HDT*` | Set by the engine | **No** — assigning one is a validation error |
| `HDT*` | Deployment variables: rules, sequences, wizard, per-machine overrides | Yes |

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
| `HDTComputerName` | `HDTComputerName` | `Make` | `HDTMake` |
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
| `_SMSTSLogPath` | `_HDTLogPath` | `TimeZoneName` | `HDTTimeZoneName` |

HDT-specific additions with no MDT equivalent: `HDTSecureBootEnabled`,
`HDTTPMVersion`, `HDTBootMode` (`PXE` | `Media`), `HDTDiskLayout`.

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
  OSImage: Win11-24H2-Ent
  DiskLayout: uefi-standard
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
        os: Win11-24H2-Ent
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
    condition: "%_HDTPhase%" == "OS"
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

### 4.2 Step types (v1)

`Validate`, `DiskPartition`, `ApplyImage`, `CaptureImage`, `ApplyDrivers`,
`ApplyUnattend`, `ConfigureBoot`, `Restart`, `PowerShell`, `CommandLine`,
`InstallApplications`, `InstallRoles`, `JoinDomain`, `SetVariable`,
`WindowsUpdate`, `Sysprep`, `EnableBitLocker`.

Each step type is a PowerShell class/function pair implementing
`Test-Applicable`, `Invoke-Step`, and `Get-StepDescription`. Third-party step
types can be dropped into `Modules\` — the engine discovers them by convention,
so extending HDT does not mean forking it.

Common properties on every step: `name`, `condition`, `continueOnError`,
`timeoutMinutes`, `runIn` (`WinPE` | `FullOS` | `Any`), `retry`.

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
- Every step is **idempotent or checkpointed**. On resume the engine skips
  completed steps by index and re-runs the interrupted one only if the step
  declares `resumable: true`.
- Failure ends the sequence, writes a failure report, and — if
  `PauseOnError` — drops to a PowerShell prompt with the state loaded, so the
  technician can inspect `$HDTState` on the machine that failed. This is the
  MDT `LTISuspend` idea, generalized.

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

Copy-back happens **on failure too** — a deployment that dies is exactly when
the logs matter, and MDT's habit of stranding them on a wiped machine is a real
operational problem.

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

Both are **UTF-8**. (A spike wrote UTF-16 by accident via `Tee-Object`'s default
encoding and the result was unreadable in half the tooling — the log writer sets
encoding explicitly.)

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
  Native\
    dism-<timestamp>.log      raw tool logs, unparsed
    setupact.log              collected from the target where relevant
```

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

`event` is a controlled vocabulary — `run.start`, `run.end`, `phase.change`,
`step.start`, `step.complete`, `step.fail`, `step.skip`, `var.resolve`,
`native.exec`, `reboot.arm`, `reboot.resume` — so the report renderer and the
console filter on a known set rather than regexing prose. `data` carries
step-specific detail without polluting the top level.

`seq` is a monotonic counter that **survives reboots**, so the ordering of a
multi-leg deployment is unambiguous even when timestamps skew across a clock
change during specialize.

**CMTrace line format**, for the same entry:

```
<![LOG[Applied index 1 to W:\ in 95s]LOG]!><time="00:11:02.481+000" date="08-13-2026"
  component="ApplyImage" context="" type="1" thread="4820" file="Invoke-HDTApplyImage.ps1:142">
```

`type` maps `1`=Info, `2`=Warning, `3`=Error, giving CMTrace its colour coding
for free.

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
2. **Subsequent reboots** are configured by the engine writing the Winlogon
   values before each `Restart` step: `AutoAdminLogon`, `DefaultUserName`,
   `DefaultDomainName`, and `AutoLogonCount` under
   `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`.
3. **The engine is launched at logon** by a `RunOnce` entry re-registered each
   leg, pointing at `C:\HDT\Start-HDTResume.ps1`, which loads `state.json` and
   continues at the next step.

#### 4.5.2 Four differences from MDT

These are the reasons to reimplement rather than copy:

- **The password is a per-deployment random secret.** The Administrator
  password used during deployment is generated at run start (high entropy,
  stored only in the state document on the machine being built), *not* a fixed
  corporate password reused across the fleet. If it leaks it is worth one
  machine, mid-build. The real password — or LAPS enrollment — is set by a
  cleanup step at the end.
- **It is stored as an LSA secret, not registry cleartext.** Winlogon reads
  `DefaultPassword` from LSA private data as well as from the registry; this is
  the mechanism Sysinternals' `Autologon.exe` uses. Same behavior, no plaintext
  string sitting in a registry hive that any local read can lift, and no
  plaintext in a registry backup or a captured image.
- **`AutoLogonCount` bounds it.** The engine sets the count to exactly the
  number of legs remaining. Windows decrements it per autologon and tears down
  `AutoAdminLogon` when it reaches zero — so an abandoned or failed deployment
  stops autologging-on by itself rather than staying open forever. *(Behavior
  note: `AutoLogonCount` interacts with where `DefaultPassword` lives. M2
  verifies the LSA-secret + count combination empirically on each supported
  Windows build before it is relied on; if the combination does not hold, the
  fallback is registry storage plus explicit teardown, and this document is
  updated with the finding.)*
- **Teardown is a failsafe, not a step.** MDT's cleanup is a task sequence step,
  so a failure before it leaves autologon armed. In HDT teardown runs from
  `finally` around the sequence, *and* `Start-HDTResume.ps1` reconciles on every
  boot: if the state document says the run is finished, failed, or missing, it
  clears autologon, the LSA secret, the `RunOnce` entry, and `C:\HDT\state.json`
  before doing anything else. `AutoLogonCount` is the third backstop behind both.

#### 4.5.3 Teardown checklist

At sequence end — success or failure — the engine clears: `AutoAdminLogon`,
`DefaultUserName`, `DefaultDomainName`, `DefaultPassword` (registry *and* LSA
secret), `AutoLogonCount`, the `RunOnce` entry, the staged unattend, and the
deployment password from `state.json`. It then applies the final Administrator
password policy: rotate to the configured value, hand off to LAPS, or disable
the account — whichever the sequence declares. The final state of the account is
**explicit in the sequence**, never left as whatever deployment happened to
leave behind.

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
```

`Update-HDTBootImage -OptionalComponent` overrides per invocation.

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

The build is **deterministic and repeatable**: mount, apply components, inject,
commit, export (`/Compress:max`), and record a manifest of exactly what went in.
Boot image drift — where nobody remembers what's in the WIM — is a real MDT
operational problem.

`Update-HDTBootImage -SkipIso` omits ISO generation, matching MDT's per-platform
ISO checkbox. Generating the ISO is the slow half of the build, and during
iteration on a WDS-based lab you often don't need it.

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

---

## 6. Transport: PXE and standalone media

Content access is abstracted behind a **provider** interface with three
operations: `Resolve-Content`, `Copy-Content`, `Test-Content`. Steps never
touch UNC paths directly. Three providers in v1:

| Provider | Used by | Notes |
|---|---|---|
| `Smb` | PXE / network deploy | Mapped with per-run credentials, read-only |
| `Local` | Standalone media | Content on the USB/ISO itself |
| `Http` | *stub in v1* | Interface exists so a cloud transport can land later without touching step code |

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

`New-HDTMedia` takes a workspace, a set of task sequence IDs, and a selection
profile, then produces a self-contained ISO or a bootable USB layout containing
only the content those sequences reference. The engine running from media is
**the same engine** with the `Local` provider — not a parallel code path. This
is the constraint that makes the "share + standalone" dual model tractable:
media generation is a content projection plus a provider swap.

USB layout uses a small FAT32 boot partition (UEFI requirement) plus an NTFS
content partition, so images larger than 4 GB work without splitting.

### 6.3 Share credentials

**Decision: the deployment account credential is embedded in the boot image**,
the `Bootstrap.ini` model. PXE-booted machines connect to the share and start
deploying with no operator input — that is the point of PXE, and prompting at
every bare-metal boot defeats it.

Configured in `workspace.yaml` and written into the boot image by
`Update-HDTBootImage`:

```yaml
deployRoot: \\server\HdtShare
credential:
  username: CONTOSO\svc-hdt-deploy
  password: <set by Set-HDTShareCredential>
```

`Set-HDTShareCredential` writes it; the value never appears in a file an admin
hand-edits, so it does not end up in git.

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

- **Import** (`Import-HDTDriver`) parses each `.inf`, extracting hardware IDs,
  class, provider, version, and date into `driver-index.json`. Importing is
  where the cost is paid; matching at deploy time is then a dictionary lookup.
- **Group match (primary).** `ApplyDrivers` with a `group` resolves to a folder
  and injects it wholesale via `Add-WindowsDriver -Path W:\ -Recurse`.
- **PnP match (fallback).** If no group matches, the engine enumerates present
  hardware IDs from WinPE, looks each up in the index, and injects only matching
  packages — ranked by hardware-ID specificity, then version, then date.
- **Boot-critical drivers** (storage/network) are tracked separately and are the
  only ones eligible for boot image injection.
- **Reporting.** `Get-HDTDriverCoverage` answers "which models in this fleet
  have no driver group?" before a deployment fails at 3 a.m.

Injection is offline (`DISM /Image:`) against the applied OS volume, matching
MDT's behavior. Online injection during the full-OS phase is available for
post-apply fixes.

---

## 8. Applications

```yaml
schemaVersion: 1
id: 7Zip-24.09
name: 7-Zip 24.09 x64
install: msiexec.exe /i "7z2409-x64.msi" /qn
uninstall: msiexec.exe /x "{GUID}" /qn
successCodes: [0, 3010]
rebootCodes: [3010]
detect:
  type: msiProduct
  productCode: "{GUID}"
dependencies: [VCRedist-2015-2022]
runIn: FullOS
```

- **Detection rules** (`msiProduct`, `file`, `registry`, `script`) let the
  engine skip already-installed apps — MDT has no first-class detection, so
  reruns reinstall everything.
- **Dependencies** are topologically sorted; a cycle is a validation error at
  authoring time, not a hang at deploy time.
- **Reboot handling** is explicit: a `3010` return suspends the app list,
  reboots, and resumes at the next app.
- **Selection** comes from the `Applications` variable (rules or wizard), or a
  fixed list in the step. Both resolve to the same ordered install plan, which
  is logged before execution.

---

## 9. Imaging

### 9.1 Disk layout

Named layouts in `workspace.yaml`, not hardcoded:

- `uefi-standard` — GPT: EFI System 260 MB FAT32, MSR 16 MB, Windows
  (remainder minus recovery), WinRE recovery 1 GB at the end.
- `bios-standard` — MBR: System Reserved 500 MB active NTFS, Windows remainder.

The engine selects a layout by firmware unless the sequence pins one, and
**refuses to guess** when the disk is unexpected (multiple disks, existing data
volumes, USB source disk in range). `DiskPartition` requires either an
unambiguous target or an explicit `diskNumber`. Wiping the wrong disk is the
single most destructive failure mode in this class of tool.

### 9.2 Apply

`Expand-WindowsImage` for WIM, `DISM /Apply-Ffu` for FFU. Index selectable by
number, name, or edition. Post-apply: recovery partition setup
(`reagentc /setosimage`), boot files (`bcdboot`), unattend placement.

### 9.3 Capture

A reference-image sequence: build → customize → `Sysprep` step
(`/generalize /oobe /shutdown` with an unattend) → reboot to WinPE →
`CaptureImage` step → WIM written to `Captures\`. `Import-HDTOperatingSystem`
then promotes a capture into the OS catalog. This closes the loop so HDT builds
its own reference images rather than depending on another tool.

---

## 10. Full-OS configuration steps

Three steps that run after the image is applied and the machine has rebooted
into Windows. All are `runIn: FullOS`.

### 10.1 Windows Update

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

## 11. Admin console (WPF)

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
- **Task sequence editor:** drag-and-drop step tree with a properties pane,
  editing `sequence.yaml` in place. Comments and key order in the YAML are
  preserved on round-trip; a UI that reformats the file breaks git review, which
  is one of the reasons config-as-code fails in practice.
- **Monitoring view:** tails `Logs\_active\`, showing in-flight deployments,
  current step, and elapsed time; opens the full report on completion.
- **Validation:** the same JSON Schemas the cmdlets use, surfaced inline.

The console ships as a separate solution in the repo and is **optional** — the
module is fully usable without it, including on a headless server.

---

## 12. Cross-cutting concerns

### 12.1 Error handling

Engine code sets `$ErrorActionPreference = 'Stop'` and wraps each step in a
single try/catch that classifies failures as `Transient` (retry per the step's
`retry` policy), `Configuration` (bad authoring — fail fast, point at the file
and line), or `Environment` (hardware/network — fail with diagnostics attached).
Native tool exit codes are checked explicitly; `$LASTEXITCODE` is never assumed
to be zero.

### 12.2 Test-driven development

**HDT is written test-first.** Pester 5 is the framework. The working loop is
red → green → refactor, at the granularity of one behavior:

1. Write a `Describe`/`It` that states the behavior in domain language
   ("resolves `HDTComputerName` from the per-machine override in preference to a
   matching rule"). Run it. Watch it fail for the right reason.
2. Write the smallest implementation that passes.
3. Refactor with the suite green.

**No production function is written before a failing test exists for it.** The
exception is thin adapters around external tools (§12.2.3), which are kept small
precisely because they can't be unit tested.

#### 12.2.1 The testability rule this imposes

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

#### 12.2.2 The testing pyramid

| Layer | What it covers | Runs |
|---|---|---|
| **Unit** (majority) | Rule evaluation and provenance, variable precedence, driver ranking, app dependency sort, disk layout planning, condition evaluation, resume/skip logic, media content projection | Every save; seconds |
| **Contract** | Every sample YAML validates against its schema; every step type implements the step contract; every content provider satisfies the provider contract | Every push |
| **Integration** | Real DISM against a scratch VHDX, real WIM apply/capture, real driver `.inf` parsing, boot image build | Every push (Windows runner with ADK) |
| **End-to-end** | `Test-HDTDeployment` harness: provision a Hyper-V VM, PXE-boot it against a scratch workspace, run a sequence, assert the end state | Nightly + pre-release |

The E2E layer is slow and is not where correctness is established — it exists to
catch the integration seams that fakes hide. When an E2E test finds a bug, the
fix starts by reproducing it at the unit layer.

#### 12.2.3 Test doubles and boundaries

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

#### 12.2.4 Definition of done

A change is done when: a test existed before the code; the full unit + contract
suite is green; new public cmdlets have comment-based help and at least one test
per documented behavior; PSScriptAnalyzer is clean; and coverage of the engine's
decision logic has not regressed. Coverage is a signal, not a target — an
untested `if` in the rule engine matters, an untested line in a DISM adapter
does not.

#### 12.2.5 CI

Unit + contract + PSScriptAnalyzer on every push (Windows runner). Integration
on every push to `main` and on PRs touching imaging or driver code. E2E nightly.
A red suite blocks merge.

### 12.3 Versioning and compatibility

Workspace content carries `schemaVersion`. The module refuses to operate on a
workspace newer than it understands and offers `Update-HDTWorkspace` for older
ones. Boot images record the engine version they contain; a version mismatch
between boot image and share is a warning at deploy time, since it is a common
cause of confusing failures.

---

## 13. What HDT deliberately does differently from MDT

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

---

## 14. Open questions

All resolved except one.

1. ~~**Unattended PXE credentials.**~~ **Resolved:** embedded in the boot image,
   the `Bootstrap.ini` model, mitigated by an enforced least-privilege account
   check (§6.3).
2. ~~**Secure Boot + iPXE.**~~ **Resolved:** WDS is the v1 PXE path (§6.1).
   iPXE is deferred post-v1.
3. ~~**USMT scope.**~~ **Resolved:** out of scope permanently (§1). Wipe-and-load
   only.
4. ~~**Windows Update during deployment.**~~ **Resolved:** online, against WSUS
   or Windows Update, multi-pass (§10.1). No offline servicing pipeline.
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

## 15. Naming and repo conventions

### 15.1 Command naming — mandatory

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

### 15.2 Other conventions

- Module: `Hephaestus`.
- Repo layout: `src/Hephaestus/` (module), `src/HDT.Console/` (WPF),
  `schemas/`, `tests/`, `docs/`, `samples/`.
- All public cmdlets: comment-based help, `[CmdletBinding()]`,
  `SupportsShouldProcess` on anything destructive (`DiskPartition`, workspace
  writes, media generation).
- Style: PascalCase functions, approved verbs only, singular nouns, no aliases
  in committed code, `Set-StrictMode -Version Latest` in the engine.
