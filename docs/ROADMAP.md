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

**Exit:** a VM boots the ISO unattended with no keypress, and a physical or
virtual machine PXE-boots the same image from WDS and deploys.

---

## M5 — Drivers  ·  **DEFERRED TO v2**

> **v2, not cut.** Scheduled out of v1 at the user's direction; the milestone is
> kept here in full so v2 starts from a written plan rather than a memory. See
> `.planning/ROADMAP.md` "v1 scope" for what deferring it costs.


- `Import-HDTDriver`: `.inf` parsing → `driver-index.json`.
- `ApplyDrivers` step: group match primary, PnP match fallback, ranking by
  hardware-ID specificity → version → date.
- Boot-critical driver tracking; `Get-HDTDriverCoverage`.

**Tests first:** `.inf` parsing against real fixture headers (including
malformed and multi-arch ones); ranking order for every tie-break; group match
taking precedence over PnP; empty-match behavior; coverage report correctness.

**Exit:** an unrecognized model deploys with working network and storage via
PnP fallback.

---

## M6 — Applications and full-OS steps

- `app.yaml` schema; `InstallApplications` step.
- Detection rules (`msiProduct`, `file`, `registry`, `script`).
- Dependency topological sort with cycle detection at authoring time.
- Exit-code classification, `3010` reboot-and-resume.
- **`WindowsUpdate`** (DESIGN §10.1): WUA COM API, WSUS target, category and
  exclusion filters, multi-pass loop with reboots.
- **`InstallRoles`** (DESIGN §10.2): `Install-WindowsFeature` wrapper, feature
  name validation, SxS source through the content provider.
- **`EnableBitLocker`** (DESIGN §10.3): `scope: usedSpaceOnly | full`, protector
  and method selection, AD/Entra escrow verified before encryption starts.
- **`SetAdminPassword`** — the last item of DESIGN §4.5.3's teardown checklist,
  which M2 does **not** ship: after deployment the local Administrator account is
  left holding the per-deployment random secret, and the sequence must declare
  what happens to it — rotate to a configured value, hand off to LAPS, or disable
  the account. Until this exists, a machine HDT built has a working local
  Administrator password that only the (now-deleted) state document ever knew,
  which is safe but not finished. The final state of the account is **explicit in
  the sequence**, never left as whatever deployment happened to leave behind.
- Server task sequence in `samples/`; a Windows Server VM added to the E2E
  matrix.

**Tests first (full-OS steps):** the WU loop terminating on a clean pass *and*
on `maxPasses`, and resuming correctly across a mid-loop reboot — a WU step that
runs once and declares victory is the classic MDT bug; exclusion patterns
filtering as written; WUA rejected in the WinPE phase. `InstallRoles` failing
fast on an unknown feature name with valid alternatives listed, and resolving
SxS source identically under `Smb` and `Local`. BitLocker: **escrow verified
before encryption begins** (a machine encrypted with no recoverable key is worse
than an unencrypted one — this gets a dedicated test), `scope` mapping to
`-UsedSpaceOnly`, `escrow: none` warning, `wait: false` returning without
blocking.

**Tests first (admin password):** the account left with the configured password
and not the deployment secret; LAPS hand-off leaving the account enrolled rather
than rotated; `disable` leaving it disabled; and the step refusing to run at all
when the sequence declares none of the three, because "whatever deployment left
behind" is not an outcome.

**Tests first (applications):** dependency sort determinism; cycle detected as a validation
error; detection short-circuiting an already-installed app; reboot mid-list
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

**Exit:** an admin can build and run a sequence without the command line, and
read off the equivalent cmdlets while doing it.

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
