# PROJECT: Hephaestus Deployment Toolkit (HDT)

## What this is

A replacement for the Microsoft Deployment Toolkit (MDT), which has been in
maintenance mode since 2019. HDT keeps MDT's operational model — deployment
share, task sequences, driver store, application catalog — and rebuilds the
engine on PowerShell instead of VBScript/WSH.

## Authoritative design documents

**These two documents are the specification. Read them before planning or
implementing anything. Do not re-derive decisions they already settle.**

- `docs/DESIGN.md` — full technical design, 15 sections
- `docs/ROADMAP.md` — milestones M0–M8 with per-milestone "Tests first" lists

## Settled decisions (do not revisit)

| Decision | Value | Ref |
|---|---|---|
| Engine language | Windows PowerShell **5.1 compatible** (runs in WinPE) | DESIGN §1 |
| Config format | YAML + JSON Schema | DESIGN §2.2 |
| MDT dependency | **NONE. Zero MDT components.** ADK and WDS only | see PSD section below |
| Development method | **Test-driven — failing Pester test before implementation, always** | DESIGN §12.2 |
| Command naming | **`Verb-HDTNoun`, uppercase HDT, every function incl. private** | DESIGN §15.1 |
| Reboot resume | Autologon as local Administrator (MDT model), LSA secret, `AutoLogonCount`, teardown in `finally` + boot reconcile | DESIGN §4.5 |
| PXE | WDS only. iPXE deferred post-v1 | DESIGN §6.1 |
| Boot artifacts | One build → `.wim` (WDS) **and** `.iso` (VM debugging), hash-identical WIM inside | DESIGN §5 |
| ISO keypress | `-NoPromptForKey` via `efisys_noprompt.bin`; UEFI only (no BIOS equivalent exists) | DESIGN §5.2 |
| Share credential | Embedded in boot image (Bootstrap.ini model) + enforced least-privilege ACL check | DESIGN §6.3 |
| USMT | **Out of scope permanently.** Wipe-and-load only | DESIGN §1 |
| Windows Update | Online (WSUS/WU), multi-pass loop | DESIGN §10.1 |
| Server OS | In v1 — `InstallRoles` step | DESIGN §10.2 |
| BitLocker | v1 full-OS step, `scope: usedSpaceOnly \| full`, escrow verified first | DESIGN §10.3 |
| Admin console | WPF/.NET 8, thin client over the module, built last | DESIGN §11 |

## Non-negotiable constraints

1. **TDD.** No production function without a failing test written first. The one
   exception is thin adapters over external tools (DISM, CIM, oscdimg), which
   must stay branch-free precisely because they are not unit tested.
2. **PowerShell 5.1 syntax only** in `src/Hephaestus/`. No `??`, `?.`, ternary,
   `ForEach-Object -Parallel`, or `using namespace System.Collections.Generic`
   patterns that break on 5.1. Verified by running the suite under
   `powershell.exe` as well as `pwsh`.
3. **`Verb-HDTNoun` naming**, enforced by a contract test from M0 onward.
4. **Steps never touch hardware directly.** They take injected services
   (`IDiskService`, `IImageService`, `IContentProvider`, `ICimProvider`,
   `IFileSystem`, `IRegistryService`, `ILsaService`) so the whole engine can run
   under Pester against fakes.
5. **Destructive operations require `SupportsShouldProcess`** and must refuse to
   act on an ambiguous target (DESIGN §9.1).

## Environment (verified 2026-08-12)

| Thing | Value |
|---|---|
| Repo | `C:\Users\Itamartz\Documents\GithubRepos\HDT` (git, branch `main`) |
| PowerShell | pwsh 7.5.8 + Windows PowerShell 5.1.26100.8655 |
| Pester | 5.7.1 |
| PSScriptAnalyzer | 1.25.0 |
| powershell-yaml | 0.4.12 |
| .NET SDK | 9.0.315 (console targets net8.0-windows) |
| ADK | 10.1.26100.2454 (24H2) — Deployment Tools + WinPE add-on |
| Hyper-V | Enabled, cmdlets available, "Default Switch" (Internal/NAT) |
| Admin rights | Yes |
| Free space | ~423 GB on C: |

## Test media — ALREADY STAGED LOCALLY, use these paths

Do not mount the Dropbox ISOs; the source trees are already extracted to fast
local disk. Use these:

| Purpose | Staged path | Contents |
|---|---|---|
| Windows 11 client | `C:\HDTLab\media\Win11-LTSC-2024\` | Full source tree. `sources\install.wim` (4.02 GB). **Index 1 = Windows 11 Enterprise LTSC**, index 2 = Enterprise N LTSC |
| Windows Server 2025 | `C:\HDTLab\media\WS2025-Std\` | Full source tree. Index 1 = Standard (Core), **index 2 = Standard Desktop Experience**, 3 = Datacenter Core, 4 = Datacenter Desktop |

Original ISOs, if a fresh extract is ever needed:
`C:\Users\Itamartz\Dropbox\System\_FORWORK\SCCM\HydrationKitWS2025\ISO\`

### ADK — installed and verified

ADK **10.1.26100.2454 (24H2)**, Deployment Tools + WinPE add-on, both installed.
Verified paths (resolve these at runtime via `Get-HDTAdkPath`, do not hardcode —
the layout has moved between ADK releases):

| Asset | Path |
|---|---|
| ADK root | `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit` |
| `oscdimg.exe` | `…\Deployment Tools\amd64\Oscdimg\oscdimg.exe` |
| `etfsboot.com` (BIOS, prompts) | `…\Deployment Tools\amd64\Oscdimg\etfsboot.com` |
| `efisys.bin` (UEFI, prompts) | `…\Deployment Tools\amd64\Oscdimg\efisys.bin` |
| **`efisys_noprompt.bin`** (UEFI, no keypress) | `…\Deployment Tools\amd64\Oscdimg\efisys_noprompt.bin` |
| `winpe.wim` | `…\Windows Preinstallation Environment\amd64\en-us\winpe.wim` |
| WinPE media template | `…\Windows Preinstallation Environment\amd64\Media\` |

**Note:** the `efisys*.bin` El Torito images live under **Oscdimg**, NOT under the
WinPE add-on's `Media\EFI\` tree (which holds bootloaders only). `_EX` variants
exist for oversized boot images. `docs/DESIGN.md` §5.2 has been corrected to match.

Offline ADK installers, if a reinstall is needed:
`C:\Users\Itamartz\Dropbox\System\_FORWORK\SCCM\Downloads\ADK` and `...\ADKWinPE`

## Reference implementation: PSD (friendsOfMDT)

**Cloned locally at `C:\HDTLab\reference\PSD` — read it.** PSD (PowerShell
Deployment Extension Kit) is the closest prior art: MDT's LiteTouch rebuilt in
PowerShell, battle-tested in real fleets. **MIT licensed**, so reuse is
permitted with attribution.

Highest-value files for each phase:

| Phase | PSD file | What to learn from it |
|---|---|---|
| 02 Rules | `Scripts/PSDGather.ps1` | Which CIM classes/properties actually yield each MDT fact, and the edge cases (VMs, missing SKU, multi-NIC) |
| 02 Rules | `Scripts/PSDHelper.ps1` | Variable handling, logging patterns that work in WinPE |
| 03 Engine | `Scripts/PSDStart.ps1` | Boot-to-engine startup, share connect, reboot/resume handling, `X:\` vs `C:\` state |
| 03 Engine | `Scripts/PSDConfigure.ps1` | Unattend generation, autologon setup, the actual registry values used |
| 04 Imaging | `Scripts/PSDPartition.ps1` | Real UEFI/BIOS partitioning, recovery partition sizing, disk selection |
| 04 Imaging | `Scripts/PSDApplyOS.ps1` | DISM apply invocation, bcdboot, the ordering that actually works |
| 05 Boot image | `Install-PSD.ps1`, `Scripts/PSDExportDriversInWinPE.ps1` | Boot image build sequence, WinPE OC ordering |
| 06 Drivers | `Scripts/PSDDrivers.ps1` | Driver matching and injection in practice |
| 07 Apps/full-OS | `Scripts/PSDApplications.ps1`, `PSDWindowsUpdate.ps1`, `PSDRoleInstall.ps1` | Exit-code handling, WUA COM usage and its multi-pass loop, `Install-WindowsFeature` wrapping |
| 04/07 | `Scripts/PSDValidate.ps1` | Which pre-flight checks matter in the field |

### ⚠ HARD RULE: read PSD, depend on nothing from MDT

**MDT is deprecated. HDT must not require, install, import, or ship any MDT
component.** This is the entire reason HDT exists — a replacement that still
needs MDT installed is not a replacement.

PSD is an *extension to MDT*, not a standalone tool. Its scripts assume an MDT
deployment share, the MDT PowerShell provider, and MDT's own binaries. So when
mining PSD you WILL encounter MDT dependencies, and you must strip every one of
them rather than carrying them across.

**Banned in `src/Hephaestus/` — no exceptions:**

- `Import-Module MicrosoftDeploymentToolkit` / the `MDTProvider` PSDrive
- `Microsoft.BDD.*` anything (`Microsoft.BDD.PSSnapIn`, `Microsoft.BDD.Core.dll`,
  `Microsoft.BDD.TaskSequenceModule`, `Microsoft.BDD.Workbench.dll`)
- `ZTIUtility`, `ZTIGather.wsf`, `ZTIDiskUtility`, or any `ZTI*` / `LTI*` script
- `Bootstrap.ini` / `CustomSettings.ini` parsing as an MDT format (HDT reads its
  own `rules.yaml` — the *concept* carries over, the file format does not)
- MDT's `ts.xml`, `Control\` layout, `TaskSequences.xml`, `Applications.xml`
- The MDT database schema or its stored procedures
- Any path under `C:\Program Files\Microsoft Deployment Toolkit`
- `TSEnv:` / `Microsoft.SMS.TSEnvironment` COM object

**Allowed and expected:** the Windows ADK (DISM, oscdimg, WinPE) — that is a
supported Microsoft product independent of MDT, and it is the correct
foundation. WDS is likewise a supported Windows Server role.

**Enforce it with a contract test** (add in phase 01, extend as needed): scan
every file in `src/` for the banned identifiers above and fail the build on a
hit. A grep-based test is crude but it makes this constraint permanent instead
of relying on every future agent remembering it.

**How to use it — this matters:**

- **Mine it for mechanism, not for structure.** PSD is procedural scripts that
  call hardware directly. HDT is injected services + TDD + YAML. Copying PSD's
  shape would defeat the architecture. What PSD gives you is the hard-won
  *detail*: the exact DISM argument that works, the CIM property that is empty
  on VMs, the registry value Winlogon actually reads, the WUA search string.
- **Prefer it over guessing.** If you are about to invent a DISM command line or
  a partition layout from memory, check PSD first. It has been run on real
  hardware; your memory has not.
- **It is not authoritative over `docs/DESIGN.md`.** Where PSD and the design
  differ (autologon storage, media projection, provider abstraction, YAML vs
  INI), the design wins. PSD also carries MDT compatibility baggage HDT does not
  need.
- **Attribution is required if code is derived.** Note derivation in a comment
  on the function and add the file to `NOTICE.md` at the repo root (create it if
  absent, reproducing the MIT notice from `C:\HDTLab\reference\PSD\LICENSE`).

## Remote lab and CI host

A second Hyper-V host is available and is the right place for anything this
laptop cannot do — a clean CI environment, PXE/WDS work, or a server role.

- Host **`MS-A2`**, reached over Tailscale at **`100.117.142.13`**, via WinRM:
  `New-PSSession -ComputerName '100.117.142.13' -Credential $cred -Authentication Negotiate`
- Guests are reached by **nesting PowerShell Direct inside the host session**
  (VMBus, so no guest network is needed):
  `Invoke-Command -Session $sess { Invoke-Command -VMName <name> -Credential $using:g { ... } }`
- **Host credentials live outside this repo** — MS-A2's and its guests' are in
  the sibling project's `.secrets\` folder, described in
  `C:\Users\Itamartz\Dropbox\System\_FORWORK\SCCM\HydrationKitWS2025\CLAUDE.md`.
  Read them from there at runtime.
- **Lab-VM credentials may live in this repo's own `.secrets\`**, which
  `.gitignore` excludes — `.secrets\ms-a2-win11.txt` reaches the OSDTEST01 test
  VM (CLAUDE.md, "Test VM"). A test runner nobody can connect to is not a test
  runner, and sending the next person to another project's folder to find one
  line was worse than keeping it beside the code that uses it.
- **A credential's CONTENTS never go anywhere git tracks** — not into a doc, a
  test, a fixture, a commit message or a plan. That rule is unchanged and is the
  one that matters: `.secrets\` is excluded, everything else here is not. Read
  the file, pass the object, print neither.
- Its lab is `sadab.pri` on its own internal `HydrationLab` switch, with a
  domain controller providing AD/DNS/DHCP and a ConfigMgr server. **That lab
  belongs to the other project — read its notes, build nothing in it from
  here.** Nothing in it is registered on this host.

Vagrant is also available locally.

### GHRUNNER01 — the GitHub Actions runner, and the second Hyper-V host

`tests/e2e` needs Hyper-V, so it cannot run on a hosted runner. **`GHRUNNER01`
is a nested-virtualisation guest on MS-A2 that runs it**, registered as a
self-hosted runner for this repository with the label `hyperv-nested`. It was
itself deployed by HDT, zero-touch from `\\192.168.1.219\HDTShare`, which is why
the MAC-keyed rule for it is in that share's `rules.yaml`.

- Generation 2, **24 GB static** RAM, 8 vCPU, 120 GB dynamic VHDX,
  `C:\HyperV-Lab\` alongside MS-A2's own machines.
- **Nested virtualisation needs three settings together**, and it is silent
  about the ones you miss: `ExposeVirtualizationExtensions` on the processor,
  **dynamic memory off** (they are incompatible), and **MAC address spoofing on**
  the adapter, without which a nested guest's own MAC never reaches the wire and
  it gets no lease.
- It carries `HDT External` and `HDT Lab` switches of its own, so
  `New-HDTLabVirtualMachine`'s switch guard passes there unchanged.
- **It is deliberately not named `HDT-*`.** It is infrastructure, not a machine
  under test, and the prefix is what the harness's budget counts and what
  `Remove-HDTLabVirtualMachine` is willing to delete.
- It is **rolled back to a `clean` checkpoint** by an hourly task on MS-A2,
  which skips it while `Runner.Worker.exe` exists in the guest. The runner
  registration lives *inside* that checkpoint: runner credentials do not expire,
  so reverting restores a registered runner and **no GitHub token has to be
  stored on the lab host** — which `config.cmd --ephemeral` would have required.

**MS-A2 is on `192.168.2.0/24`, not the `192.168.1.0/24` this laptop's
`HDT External` switch sits on.** The two route to each other, which is the only
reason any of this works: a guest there matches no rule in `bootstrap-rules.yaml`
— every rule is keyed on gateway `192.168.1.1` — and falls through to the
`deployRoot` baked into the boot image, which is the right share. **Read that
before assuming a boot image built here will reach a machine over there.**

The share is 50 GB and only some of it is reproducible. Four e2e suites skip on
GHRUNNER01 for want of it: `CapturedImageDeployment`, `ReferenceCapture`,
`ApplicationRoundTrip` and `WindowsUpdate`. The first of those pins a captured
WIM by the run id `run-20260831-022805`, an artefact no fresh runner can
regenerate — it has to be copied.

Two findings from that kit's own notes, both corroborating ours and both
relevant to phase 07:

- **A blank auto-logon password makes Windows Server stall at the logon
  screen.** Set it with `PlainText="true"`. Same failure class as an exhausted
  `LogonCount`.
- **Server VMs need ≥4 GB *static* RAM.** 2 GB fails the DISM apply of a full
  WS2025 Desktop-Experience image with error 1450, because WinPE does not
  balloon dynamic memory.

## ⚠ Paths that must never be deleted

**`C:\Users\Itamartz\Documents\GithubRepos\HDT` — the repository root — is never
a delete target.** Not by a test, not by a cleanup block, not by a build task,
not with `-Recurse`. Nor is any parent of it.

Also never: `C:\HDTLab` itself, `C:\HDTLab\media` (staged Windows sources, ~11 GB,
slow to rebuild), `C:\HDTLab\Share`, `C:\HDTLab\reference`, or anything under
`C:\Users\Itamartz\` outside `C:\HDTLab`.

**Permitted deletes, and only these:** `out/` via `build.ps1 -Task clean`; a temp
or staging directory this process created in this run; a scratch VHDX or VM
folder this test created under `C:\HDTLab\scratch\` or `C:\HDTLab\vms\` matching
`HDT-*`.

Delete by explicit `-LiteralPath` to a specific thing you created. Never build a
delete target by enumerating a parent, and never pass a variable to
`Remove-Item -Recurse` without first asserting it is one of the permitted
locations.

Enforced by `tests/contract/ProtectedPath.Contract.Tests.ps1`, which scans every
`.ps1`/`.psm1`/`.psd1` outside fixtures, ignores comments so the rule can be
discussed in prose, and is itself proven to bite on a deliberate violation.

## ⚠ Hyper-V lab safety rules — READ BEFORE TOUCHING ANY VM

This machine hosts the user's **own work**. Damaging it is worse than failing a
test.

**PROTECTED — never stop, modify, delete, checkpoint-revert, reconfigure, or
change the networking of any VM this repository did not create.** The protected
set is defined by a prefix, not by a list: **everything not named `HDT-*`**.

**This used to be a two-name list — `CM01` and `DC01` — and those machines were
retired on 2026-08-29.** They are gone from this host; `Get-VM` returns only
`HDT-*`. The list is not being refreshed with today's names, because a list of
names is what failed: the E2E lab-safety assertion went on snapshotting two VMs
that no longer existed, compared an empty array with an empty array, and passed
while checking nothing. **Do not restore those names from an old commit, and do
not write new ones in their place.** Enumerate what is not `HDT-*` and leave it
alone.

### Rules

1. **HDT test VMs are named `HDT-*`.** Only ever act on VMs matching that
   prefix. Before any destructive Hyper-V call, filter explicitly — never
   `Get-VM | Remove-VM` or any unfiltered pipeline.
2. **THE NETWORK IS `192.168.1.0/24`. NEVER USE ANOTHER SUBNET WITHOUT ASKING
   THE USER FIRST.** No new IP on a vSwitch, no static address outside that
   range, no new virtual switch with its own range. Ask, then act.

   **It moved on 2026-08-28.** It used to be `192.168.2.0/24`; it is
   `192.168.1.0/24` now, gateway `192.168.1.1`. A rule keyed on a `192.168.2.1`
   gateway therefore matches nothing, which is exactly how zero-touch stopped
   firing and the wizard ran instead. Old plans, old logs and old fixtures still
   carry the `.2` — that is staleness, not a correction.

   Why: a `10.10.10.0/24` segment was invented for an isolated switch and
   **`10.10.10.1` was already taken by the user's VMware VMnet2**. It was caught
   only because the assignment errored. This host also runs VMnet1/2/3/4/8,
   Tailscale, Ethernet and Wi-Fi — ranges that look free are not.

   `HDT Lab` carries `172.30.30.1` from before this rule. It has no DHCP server
   and no VM attached to it. Do not extend it without asking.

   **Two switches, chosen by what the test needs.** Never `Default Switch` —
   it is Hyper-V's own shared NAT switch, `172.25.16.1/20` on this host, which
   is not the deployment subnet.

   | Switch | Use it for | Why |
   |---|---|---|
   | **`HDT External`** (Wi-Fi, 192.168.1.0/24) | **SMB deployment, share access, anything needing DHCP or the host** | The host is reachable on this subnet, but **its octet is this lab's own wiring — read it before building a boot image**, do not quote it here. DHCP comes from the real LAN, and SPIKES S6 proved a WinPE VM maps the host's `HDTShare` and applies a 4 GB WIM over it in 95 s |
   | **`HDT Lab`** (internal, isolated, 172.30.30.0/24) | **A VM that has to be off the LAN entirely and needs neither a lease nor the host** | No DHCP server and no VM attached: anything here lands on APIPA and cannot reach the host share (SPIKES S6), which is also why it cannot host a PXE test |

   An earlier version of this rule sent *every* test VM to the isolated switch.
   That was over-constrained: it has no DHCP, so VMs land on APIPA and cannot
   reach the host share — which is why every deployment in phases 04 and 05 used
   `provider Local` from an attached content disk, and why HDT's primary model,
   share-based deployment, went unproven end to end. Use `HDT External` — PXE
   included, see rule 3.
3. **PXE/WDS testing happens on the `HDT External` switch**, the real
   `192.168.1.0/24` LAN. WDS has been live there since 2026-09-02 —
   `HDT-WDS-01`, Server 2025 standalone, `C:\RemoteInstall`, its address a DHCP
   lease like any other on this subnet —
   and on 2026-09-10 a client took its bootloader off that wire and was reading
   the share 28 seconds after power-on (SPIKES S27, the first network boot in
   this project). DHCP comes from the household router at `192.168.1.1`; WDS
   answers PXE alongside it, with no DHCP options 66/67 set anywhere and no
   prestaged clients. That is a deliberate operator decision, and it works.

   `HDT Lab` cannot host a PXE test: no DHCP server on that segment, so a
   client there never gets an address and never gets as far as asking. Never
   `Default Switch` either — Hyper-V's shared NAT segment, which anything on
   this host may be placed on.

   The responder answers **every** machine on `192.168.1.0/24`: answer clients
   yes, answer only known clients no, response delay 0, `NoPrompt` for known
   and new clients alike, bound to all interfaces. A machine that network-boots
   goes zero-touch — `rules.yaml` sets `HDTSkipWizard: true` and `PNP-TEST` off
   the `192.168.1.1` gateway — into a sequence that partitions disk 0 with
   `wipe: true` on any machine carrying a disk of 60 GB or more. S27's client
   stopped at step 2, `Validate`, only because it was deliberately diskless.
4. **Memory budget: keep the HDT VMs this harness creates under 32 GB
   combined.** Host has 63.7 GB and the free figure moves with whatever else is
   running. Use 4 GB per test VM and shut them down when a test finishes.

   **It counts only VMs the harness created, and it knows which those are
   without a list.** `New-HDTLabVirtualMachine` stamps a marker into the `Notes`
   field of every VM it makes; the budget counts stamped, running VMs and
   nothing else. So a WSUS or WDS server somebody built by hand is `HDT-*`, is
   protected from teardown by the same stamp, and does not eat the budget for
   the machines under test. **This is deliberately not a list of names** — the
   section above this one records what a name list already cost.

   The number lives in exactly one file,
   `tests/helpers/HDTTestTools/tools/Get-HDTLabMemoryBudget.ps1`, and
   `tests/contract/LabMemoryBudget.Contract.Tests.ps1` fails the build if a
   second file grows a copy. It was 12 GB, in six places, until 2026-09-06 —
   five of them e2e suites that each re-implemented the same running total — and
   raising it meant finding all six.
5. **VM files go to `C:\HDTLab\vms\`**, not the host default `C:\HyperVVMs`
   where the user's VMs live.
6. Test VMs are **Generation 2** (UEFI + Secure Boot) — that is what HDT
   targets, and it is required to exercise the UEFI disk layout and the
   `-NoPromptForKey` UEFI ISO path.

### Consequence: domain join has no live DC to test against

**There is no domain controller on this host** — the lab's one was retired on
2026-08-29 — and the `HDT Lab` switch is isolated in any case. Therefore:

- `JoinDomain` is verified **against a fake** at the unit level (its command
  construction, error handling, OU targeting, retry).
- Real domain-join E2E is **out of scope** unless the user later asks for it,
  in which case the answer is a throwaway `HDT-*` controller this repository
  builds on the isolated switch and removes afterwards.
- Sample sequences default to workgroup join so they run end-to-end in the lab.

State this gap plainly in phase verification rather than implying JoinDomain was
proven end-to-end.

## Scratch areas (never commit these)

- `C:\HDTLab\` — deployment share under test, VHDXs, VM files, mounted WIMs
- `C:\HDTLab\Share` — the scratch workspace integration tests build against

## Repo layout

```
src/Hephaestus/        PowerShell module (the engine and the WPF console)
schemas/               JSON Schemas for every YAML file type
tests/unit/            Pester unit tests (majority)
tests/contract/        Schema + naming + provider contract tests
tests/integration/     Real DISM/VHDX/ADK tests
tests/e2e/             Hyper-V end-to-end
tests/fixtures/        Real .inf headers, captured CIM shapes, sample workspaces
samples/               Example workspaces and sequences
docs/                  DESIGN.md, ROADMAP.md
```

## Definition of done (every milestone)

A test existed before the code. Full unit + contract suite green under **both**
pwsh 7 and Windows PowerShell 5.1. PSScriptAnalyzer clean. New public commands
have comment-based help. Samples and docs updated. Milestone exit criteria in
`docs/ROADMAP.md` met and demonstrated.
