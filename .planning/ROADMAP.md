# ROADMAP — HDT v1

Phases map 1:1 onto the milestones in `docs/ROADMAP.md`. **That document holds
the per-phase "Tests first" lists and exit criteria — it is authoritative.**
This file is the GSD-facing index.

Milestone → phase directory mapping:

| Phase | Milestone | Directory | Depends on |
|---|---|---|---|
| 01 | M0 — Skeleton and harness | `.planning/phases/01-harness/` | — |
| 02 | M1 — Variables and rules | `.planning/phases/02-rules/` | 01 |
| 03 | M2 — Task sequence engine | `.planning/phases/03-sequence-engine/` | 01, 02 |
| 04 | M3 — Imaging | `.planning/phases/04-imaging/` | 03 |
| 05 | M4 — Boot image, ISO, PXE | `.planning/phases/05-bootimage/` | 03, 04 |
| 05.5 | **M4.5 — Technician UI (WinPE wizard + progress)** | `.planning/phases/05.5-technician-ui/` | 04, 05 |
| ~~06~~ | ~~M5 — Drivers~~ **DEFERRED TO v2** | `.planning/phases/06-drivers/` | 04 |
| 07 | M6 — Applications and full-OS steps | `.planning/phases/07-apps-fullos/` | 03, 04 |
| ~~08~~ | ~~M7 — Capture and standalone media~~ **DEFERRED TO v2** | `.planning/phases/08-capture-media/` | 04, 05, 07 |
| 09 | M8 — Admin console (WPF) | `.planning/phases/09-console/` | 02–05, 05.5, 07 |

## v1 scope

**v1 ships:** 01 harness, 02 rules, 03 sequence engine, 04 imaging, 05 boot image
and the zero-keystroke boot path, 05.5 technician UI, 07 applications and full-OS
steps, 09 admin console.

**v2:** 06 drivers, 08 capture + standalone media, and — added 2026-08-16 — the
`WindowsUpdate` step out of 07. All keep their full design and roadmap entries
below; they are scheduled out, not cut, and nothing in v1 was built in a way that
assumes they are absent.

What deferring them actually costs, stated so it is not discovered later:

- **No out-of-box driver injection.** v1 deploys with whatever drivers are inbox
  in the applied image. That is fine for VMs and for hardware Windows already
  supports; a machine needing an OEM storage or network driver will deploy and
  then be missing that device. Boot-critical driver injection into the WinPE
  image is **not** affected — it belongs to `Update-HDTBootImage` in phase 05 and
  stays in v1, so a machine that needs a NIC driver to reach the share still gets
  one.
- **No reference-image capture.** v1 applies images; it does not sysprep and
  capture its own. Images come from Microsoft media or an existing pipeline.
- **No standalone offline media.** v1 deploys from a share, over PXE or from the
  boot ISO. `New-HDTBootIso` (phase 05) still produces a bootable WinPE ISO —
  what moves to v2 is `New-HDTMedia`, the full content projection that puts the
  OS, applications and sequences on a USB stick for a site with no server.
- **No in-sequence patching.** A machine HDT builds leaves the bench with exactly
  the patches its source image carried. There is no `WindowsUpdate` step, so
  currency after deployment is whatever Windows Update does on its own schedule
  once the technician hands the machine over. The step type is additive — v2
  brings it back by adding files, not by changing them.
- **The console (09) will show Drivers and Captures nodes with nothing behind
  them** unless it hides them; it should read the workspace and omit what is not
  present rather than showing empty branches.

## Phase goals (one line each — full detail in `docs/ROADMAP.md`)

**01 — Harness.** Make it impossible to add untested code. Module skeleton,
Pester 5 harness, PSSA, CI, fakes, and the `Verb-HDTNoun` naming contract test.
*Exit:* `./build.ps1 test` green on a clean clone, under pwsh 7 **and** PS 5.1.

**Plans:** 4 plans, executed in order (each depends on the one before it).

- [x] `01-01-PLAN.md` — module skeleton + loader, `HDTTestTools` helper module,
      `build.ps1` (build/test/lint/ci), Pester 5 configuration, `PSScriptAnalyzerSettings.psd1`
- [x] `01-02-PLAN.md` — the three enforcement contract tests (`Verb-HDTNoun`
      naming, PowerShell 5.1 syntax, no-MDT-dependency) and the AST tooling they rest on
- [x] `01-03-PLAN.md` — first hand-written fakes (`FakeFileSystem`, `FakeCimProvider`),
      their service contract tests, captured CIM fixtures, and the fake conventions
- [x] `01-04-PLAN.md` — harness self-proof (a deliberately failing test fails),
      GitHub Actions CI on a Windows runner for both engines, clean-clone exit verification

Phase 01 is **complete**. `./build.ps1 -Task test` exits 0 from a `git clone --local`
of the committed state under pwsh 7 and Windows PowerShell 5.1. The one documented
exception is `-Task ci` under 5.1 *on the development machine*, where the `lint`
step fails because PSScriptAnalyzer is not importable by that edition; CI installs
it for both editions. GitHub-side CI has not been observed green because the
repository has no remote yet — see the `user_setup` block in `01-04-PLAN.md`.

**02 — Rules.** Replace `CustomSettings.ini` + `ZTIGather`. Fact gathering behind
`ICimProvider`, `rules.yaml`, five-source precedence, `%Var%` expansion, and
provenance for every resolved variable.
*Exit:* given fixture facts + rules, the engine produces the expected variables
and explains every value.

**Plans:** 3 plans, executed in order (each depends on the one before it).

- [x] `02-01-PLAN.md` — CIM/registry/environment/script services (fakes, contracts,
      real adapters), the remaining captured CIM fixtures, and `Get-HDTMachineFact`
- [x] `02-02-PLAN.md` — `Get-HDTVariableMap`, pointed configuration errors, the YAML
      adapter, `schemas/rules.schema.json` + `machine.schema.json`, and
      `Import-HDTRuleDocument` with thirteen fixture documents
- [x] `02-03-PLAN.md` — the resolution engine: five-source precedence, wildcard and
      multi-key `when`, `%Var%` expansion with cycle detection, `setFrom:` rules,
      provenance, the sample workspace, and the M1 exit demonstration

Phase 02 is **complete**. The M1 exit criterion is met and demonstrated twice: by
`tests/unit/GatherAndResolve.EndToEnd.Tests.ps1` over the captured CIM fixtures
and the sample workspace, and by a live run against this machine's real facts in
which `HDTComputerName` resolves to `PC-<serial>` with `Source = Rule`,
`Rule = Fallback`. Final counts: 863 passed / 0 failed / 9 skipped under pwsh
7.5.8 with lint clean across 79 files and selfcheck 4/4; 831 passed / 0 failed /
41 skipped under Windows PowerShell 5.1. What DESIGN 4.4's `Gather\` still owes —
`facts.json` and the `var.resolve` JSONL events — belongs to phase 03 and is
recorded in `02-03-SUMMARY.md`.

**03 — Sequence engine.** Sequencing, conditions, retry, reboot-resume, and the
autologon lifecycle — all against fakes, touching nothing real. Includes the
`SetVariable` / `PowerShell` / `CommandLine` / `Restart` steps and JSONL logging.
*Exit:* a multi-group sequence with reboots runs to completion in a Pester run.

**Plans:** 5 plans, executed in order (each depends on the ones before it).
M2 is the largest milestone in the project — it encodes the execution model every
later phase plugs into — so it is split by subsystem rather than compressed.

- [x] `03-01-PLAN.md` — the shared fake operation journal, `IClock`, the real
      `New-HDTFileSystem` with `AppendAllText`, DESIGN 4.4 structured logging
      (JSONL + CMTrace + `status.json` + `facts.json`), and DESIGN 4.3's
      `state.json` with its schema
- [x] `03-02-PLAN.md` — `sequence.yaml` schema, validator, import and flattening;
      the closed condition grammar; the step contract, its discovery convention and
      the three dispatchers; `IProcessService` / `IPowerService`; and the five steps
      `NoOp`, `SetVariable`, `PowerShell`, `CommandLine`, `Restart`
- [x] `03-03-PLAN.md` — the autologon lifecycle: the `IRegistryService` write half,
      `ILsaService`, the per-deployment password, arming bounded by `AutoLogonCount`,
      the DESIGN 4.5.4 teardown checklist, the boot-time reconcile, and the S8 spike
      settling the `AutoLogonCount` decrement
- [x] `03-04-PLAN.md` — the execution loop: ordering, `runIn`, conditions,
      `continueOnError`, retry with backoff, timeout, checkpointing,
      reboot-and-resume, the `finally` teardown, and `Start-HDTResume.ps1`
- [x] `03-05-PLAN.md` — `ConvertTo-HDTReport`, **the DESIGN 12.2.1 headline test**
      (a multi-group sequence with two reboots, end to end against fakes, asserting
      the exact ordered operation list), the `DEMO-M2` and `STD-CLIENT` samples, the
      DESIGN corrections this phase forced, and the live M2 exit demonstration

Phase 03 is **complete**. The M2 exit criterion is met and demonstrated twice: by
`tests/unit/TaskSequence.EndToEnd.Tests.ps1`, which runs the `DEMO-M2` sample
across three legs and two reboots against fakes and asserts the exact ordered
list of the 31 operations it would have performed on a machine — plus every step
accounted for exactly once, a continuous JSONL `seq`, an empty autologon
checklist and a rendered report, in about three seconds; and by a live run of the
same sequence at `C:\HDTLab\scratch\m2demo` against the real filesystem, clock,
process service and script invoker (power, registry and LSA stayed fake, because
a demonstration may not reboot the developer's machine) whose `report.html` was
opened in a browser. Final counts: 2838 passed / 0 failed / 24 skipped under pwsh
7.5.8 with lint clean across 201 files and selfcheck 4/4; 2752 passed / 0 failed
/ 110 skipped under Windows PowerShell 5.1.26100.8655.

Four defects were found by writing the headline test and then reading the report
it produced, each fixed with a test first: `Start-HDTResume.ps1` restarted the
JSONL `seq` at every boot, so DESIGN 4.4.2's "seq survives reboots" was not true
on a real machine; `New-HDTRunState` read `Group` off a flattened step when the
flattener emits `GroupPath`, so the state document's group array was empty on
every real run; the report left every `Restart` step reading `Running` for ever,
because a Restart step never logs a `step.complete`; and `-Timestamp` threw under
`Set-StrictMode`.

What M2 does **not** cover, recorded here so a later phase picks it up:

- **The final Administrator password policy** (DESIGN 4.5.4's last item) is M6.
  A machine HDT builds is left holding the per-deployment secret, which is safe —
  the state document that knew it is gone — but not finished.
- **`timeoutMinutes` is not pre-emptive** and **`PauseOnError` does not prompt**;
  both are now documented in DESIGN 4.3 rather than implied.
- ~~**`New-HDTPowerService` has never been executed** and whether WinPE needs
  `wpeutil reboot` rather than `shutdown.exe` is a phase 05 question.~~
  **ANSWERED in 05-06, and it was a defect rather than a preference:**
  `shutdown.exe` is not in the WinPE image at all, so a `Restart` step there
  would have called a command that does not exist. `New-HDTPowerService` has now
  executed, in WinPE, powering the smoke VM off. See SPIKES S13.
- **`powershell-yaml` is a hard runtime dependency of the engine and nothing yet
  asserts it will be inside the WinPE boot image** — the third carried-forward
  item from `02-VERIFICATION.md`, and phase 03 has made it worse rather than
  better: the engine now reads `sequence.yaml` in WinPE too, so the boot image
  build in **phase 05** must stage that module and prove it imports there.

**04 — Imaging.** The destructive parts, guarded. Disk layouts, apply, unattend,
boot config, OS import. Target-disk ambiguity must refuse to proceed.
*Exit:* a Hyper-V VM boots into Windows 11 from a real sequence run.

**Plans:** 4 plans in 4 waves (each depends on the one before it — the services
before the decisions, the decisions before the steps, the steps before anything
real is touched).

- [x] `04-01-PLAN.md` — `IDiskService` and `IImageService`: real adapters over the
      Storage module, DISM, `bcdboot`, `bcdedit` and `reagentc`, hand-written fakes
      (the disk fake models the MSR `Initialize-Disk` creates), two contracts, and
      captured disk and WIM fixtures
- [x] `04-02-PLAN.md` — the decisions, all pure logic: `Select-HDTTargetDisk` and
      DESIGN 9.1's refusal to guess (the most-tested unit in the phase), the
      `uefi-standard` / `bios-standard` layouts and their partition arithmetic,
      firmware selection, index resolution, and the `os.yaml` catalog with its schema
- [x] `04-03-PLAN.md` — the five steps (`Validate`, `DiskPartition`, `ApplyImage`,
      `ApplyUnattend`, `ConfigureBoot`), the `DEMO-M3` sample, and the M3 benchmark:
      a whole WinPE deployment leg against fakes asserting the exact ordered
      operation list
- [x] `04-04-PLAN.md` — the first real runs: `build.ps1 -Task integration` and
      `-Task e2e`, a real apply to a scratch VHDX, the engine's first start inside
      WinPE, and **the M3 exit criterion** — a Gen2 VM on the isolated `HDT Lab`
      switch deployed by a sequence run through the engine, booting into Windows 11

Phase 04 is **complete**. The M3 exit criterion is met and demonstrated: a
Generation 2 VM on the isolated `HDT Lab` switch was deployed by a five-step
sequence run through the engine inside WinPE, and booted into Windows 11 **with
the WinPE media still attached and the firmware boot order untouched** — so
`ConfigureBoot`'s `SetBootOrderFirst` works, and it had never run anywhere
before, because it edits the boot order of the machine it runs on. SPIKES S9
records the whole run, including four things the fakes had wrong. The most
important is S9.3: `Clear-Disk` **refuses a RAW disk**, which is every machine
`DiskPartition` exists for, and the entire unit suite was green over code that
could not partition a factory-fresh disk. The most dangerous is S9.11: Windows
Setup **silently discards a `ComputerName` over 15 characters** and names the
machine itself, on a deployment that reports `Succeeded`.

**05 — Boot image / ISO / PXE.** `Update-HDTBootImage`, `New-HDTBootIso` with
`-NoPromptForKey`, build manifest, WDS import, SMB content provider — **and the
boot path itself**: `startnet.cmd` plus `Start-HDTDeployment.ps1`, so a machine
deploys with nobody at the keyboard.
*Exit:* a VM boots the ISO **HDT built** and deploys Windows 11 with **zero
keystrokes**; the same image PXE-boots from WDS. (There is no WDS on this host,
and PROJECT.md forbids standing one up beside `CM01`'s PXE responder — so the WDS
import is proven against a fake and `New-HDTPxePayload`'s staging completeness is
demonstrated instead. That gap is stated, not worked around.)

**Plans:** 6 plans in 6 waves (each depends on the ones before it — the pure
logic before the providers, the providers before the entry point, the entry point
before the image that carries it, the image before the machine that boots it, and
the machine before the question only a machine could answer).

- [x] `05-01-PLAN.md` — the foundations, none of which mounts anything:
      `Get-HDTAdkPath` (runtime resolution, refused by name when absent),
      `workspace.yaml` with its schema and sample, and `Get-HDTBootImageComponent`
      — SPIKES S1's verified order merged with what the admin declared,
      dependency-validated, language packs probed rather than assumed
- [x] `05-02-PLAN.md` — DESIGN 6's content provider: `Local`, `Smb`, one contract
      all three implementations satisfy, the refusal to fall back to guest auth,
      `Set-HDTShareCredential` / `Test-HDTShareAcl`, and **closing the seam 04-02
      marked at the resolved image path**
- [x] `05-03-PLAN.md` — `Start-HDTDeployment.ps1`, **the WinPE entry point**,
      proven by AST to do nothing a step would do; `bootstrap.json`; and DESIGN
      4.4.1's `_HDTLogPath` relocation, which phase 04 deferred and which is why
      WinPE-phase logs currently do not survive the reboot
- [x] `05-04-PLAN.md` — `Update-HDTBootImage` and `New-HDTBootIso`: the
      `IBootImageService` adapter and its fake, the seventeen-step build asserted
      from a journal, the manifest, SPIKES S2's space-free `-bootdata` staging —
      then the real ADK run proving **WIM/ISO equivalence by hash** and reading
      `startnet.cmd` back out of a mounted image
- [x] `05-05-PLAN.md` — `Import-HDTBootImageToWds` (replace-in-place),
      `New-HDTPxePayload`, `DEMO-M4`, and **the exit criterion**: a VM boots HDT's
      own ISO and deploys with zero keystrokes, proven three ways — the test sends
      nothing (asserted by parsing it), the guest reports `launchedBy startnet`,
      and a run that did not start itself would time out rather than pass
- [x] `05-06-PLAN.md` — **the phase's own unanswered question**: ROADMAP M2 asked
      whether WinPE needs `wpeutil reboot` rather than `shutdown.exe` and named
      phase 05 as the owner. `shutdown.exe` is **not in WinPE at all**, so the
      adapter's default could never have worked; `Get-HDTPowerCommand` now makes
      the decision, `New-HDTPowerService -Environment` is mandatory, and the
      smoke VM is powered off by the real adapter — the first time it has ever
      executed

Phase 05 is **complete, with two named gaps that are refusals rather than
omissions.** ROADMAP M4's **first** exit clause is met and demonstrated: a
Generation 2 VM booted an ISO `Update-HDTBootImage` produced and deployed Windows
11 to completion with **zero keystrokes sent to it** — `RESULT.json` reports
`status Succeeded`, `launchedBy startnet`, `deployRootSource Discovered`,
`endedWith "wpeutil shutdown"` (SPIKES S12). The **second** clause, PXE boot from
WDS, is **NOT met**: this host is Windows 11 Pro with no WDS, and PROJECT.md
rule 3 forbids standing one up beside CM01's PXE responder, so no WDS import has
ever executed anywhere in this repository. No VM deployed over SMB either, for
the reason SPIKES S6 records about the isolated switch. `05-VERIFICATION.md`
states both, and `docs/ROADMAP.md` M4 states them in the same words.

Final counts after 05-06: **4907 passed / 0 failed / 42 skipped** under pwsh
7.5.8 and **4762 passed / 0 failed / 187 skipped** under Windows PowerShell
5.1.26100.8655, lint clean across 344 files. And, for the first time in this
repository, the slow suites under **5.1** as well as pwsh: `-Task integration`
**138 passed / 0 failed**, `-Task e2e` **98 passed / 0 failed**. Getting there
cost three defects nobody had seen, because nobody had run them there
(SPIKES S13).

**05.5 — Technician UI.** Two WPF surfaces inside WinPE (DESIGN 11): the
full-screen progress window driven by the JSONL event stream, and the wizard
whose every page is individually skippable via `HDTSkip*` in MDT's model. Must
degrade to styled console when XAML is unavailable.
*Exit:* a deployment with a fully populated `rules.yaml` shows no wizard at all
and a live progress window; removing one value surfaces exactly that page.

**06 — Drivers.** `.inf` parsing into an index, group match primary, PnP fallback
ranked by specificity → version → date, coverage reporting.
*Exit:* an unrecognized model deploys with working network and storage.

**07 — Apps and full-OS steps.** Application catalog with **optional** detection
and with dependencies, plus `InstallRoles`, `EnableBitLocker`, and the
`HDTAdminPasswordPolicy` half of DESIGN 4.5.4. `WindowsUpdate` is **deferred to
v2** (2026-08-16), and no Server VM joins the E2E matrix — `InstallRoles` still
ships with a server sample sequence.
*Exit:* a dependency chain installs across a reboot, idempotently.

**Plans:** 6 plans in 6 waves.

- [x] `07-01-PLAN.md` — the application catalog, all pure logic: `app.schema.json`,
      `Assert-HDTApplicationDocument`, `Get-HDTApplication`, the four detection
      rules behind `Test-HDTApplicationDetection`, and `Resolve-HDTApplicationOrder`
      (topological sort, cycle detection at authoring time)
- [x] `07-02-PLAN.md` — the `InstallApplications` step: selection from the
      `Applications` variable or a fixed list collapsing to one logged plan,
      exit-code classification, `3010` suspending and resuming at the next app
- [x] `07-03-PLAN.md` — `InstallRoles` and `IFeatureService`: fail fast on an
      unknown feature name listing valid alternatives, SxS `source` through the
      content provider with `Local`/`Smb` operation-list equality
- [x] `07-04-PLAN.md` — `EnableBitLocker` and `IBitLockerService`: escrow verified
      before encryption begins, `scope` mapping, `escrow: none` warning,
      `wait: false`
- [x] `07-05-PLAN.md` — the default `HDTAdminPassword`, in the fallback rule of
      `rules.yaml` (MDT's `[Default]`). **`HDTAdminPasswordPolicy` is NOT built:**
      `keep` is the default and needs no code, which is what v1 does; `rotate`,
      `laps` and `disable` need a local-account service and are outstanding
- [x] `07-06-PLAN.md` — wiring and samples: manifest exports, console step
      catalog, a server sequence and two applications in `samples/`

Phase 07 is **complete**, on `feat/apps-fullos`. Three new step types
(`InstallApplications`, `InstallRoles`, `EnableBitLocker`), two new services
(`IFeatureService`, `IBitLockerService`), an eleventh `IFileSystem` method
(`GetVersion`), and one engine change: `New-HDTStepResult -Reenter`, without
which an `InstallApplications` step that hit a 3010 halfway down its list would
have silently skipped everything after it while reporting success.

Two things it does NOT ship, both deliberate and both recorded above:
`WindowsUpdate` (v2) and `HDTAdminPasswordPolicy`'s `rotate`/`laps`/`disable`
(needs a local-account service). No Windows Server VM joined the E2E matrix, so
`STD-SERVER` is proven by import, schema validation and console round-trip rather
than by a Hyper-V run.

**08 — Capture and media.** Sysprep + capture back into the OS catalog;
`New-HDTMedia` content projection to ISO/USB.
*Exit:* media built from the share deploys a machine with no network.

**09 — Console.** WPF thin client over the module, comment-preserving YAML
round-trip, monitoring view.
*Exit:* an admin can author a sequence and get it deployed without a shell —
edit, build the boot image and ISO, then watch it in Monitoring. **The console
never starts a deployment**; the target machine boots into WinPE and runs it
there, exactly as MDT's Workbench and LiteTouch divide the work.

## Sequencing notes

- 02 and 03 encode the model; everything later plugs into them. Spend the test
  effort there.
- 04 before 05 deliberately — proving imaging with local content iterates faster
  than debugging through PXE.
- 09 is last and optional. If it slips, v1 still ships.
