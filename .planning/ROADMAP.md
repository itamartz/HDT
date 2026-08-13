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
| 06 | M5 — Drivers | `.planning/phases/06-drivers/` | 04 |
| 07 | M6 — Applications and full-OS steps | `.planning/phases/07-apps-fullos/` | 03, 04 |
| 08 | M7 — Capture and standalone media | `.planning/phases/08-capture-media/` | 04, 05, 07 |
| 09 | M8 — Admin console (WPF) | `.planning/phases/09-console/` | 02–08 |

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
      the DESIGN 4.5.3 teardown checklist, the boot-time reconcile, and the S8 spike
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

- **The final Administrator password policy** (DESIGN 4.5.3's last item) is M6.
  A machine HDT builds is left holding the per-deployment secret, which is safe —
  the state document that knew it is gone — but not finished.
- **`timeoutMinutes` is not pre-emptive** and **`PauseOnError` does not prompt**;
  both are now documented in DESIGN 4.3 rather than implied.
- **`New-HDTPowerService` has never been executed** and whether WinPE needs
  `wpeutil reboot` rather than `shutdown.exe` is a phase 05 question.
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

- [ ] `04-01-PLAN.md` — `IDiskService` and `IImageService`: real adapters over the
      Storage module, DISM, `bcdboot`, `bcdedit` and `reagentc`, hand-written fakes
      (the disk fake models the MSR `Initialize-Disk` creates), two contracts, and
      captured disk and WIM fixtures
- [ ] `04-02-PLAN.md` — the decisions, all pure logic: `Select-HDTTargetDisk` and
      DESIGN 9.1's refusal to guess (the most-tested unit in the phase), the
      `uefi-standard` / `bios-standard` layouts and their partition arithmetic,
      firmware selection, index resolution, and the `os.yaml` catalog with its schema
- [ ] `04-03-PLAN.md` — the five steps (`Validate`, `DiskPartition`, `ApplyImage`,
      `ApplyUnattend`, `ConfigureBoot`), the `DEMO-M3` sample, and the M3 benchmark:
      a whole WinPE deployment leg against fakes asserting the exact ordered
      operation list
- [ ] `04-04-PLAN.md` — the first real runs: `build.ps1 -Task integration` and
      `-Task e2e`, a real apply to a scratch VHDX, the engine's first start inside
      WinPE, and **the M3 exit criterion** — a Gen2 VM on the isolated `HDT Lab`
      switch deployed by a sequence run through the engine, booting into Windows 11

**05 — Boot image / ISO / PXE.** `Update-HDTBootImage`, `New-HDTBootIso` with
`-NoPromptForKey`, build manifest, WDS import, SMB content provider.
*Exit:* a VM boots the ISO with no keypress; a VM PXE-boots the same image.

**05.5 — Technician UI.** Two WPF surfaces inside WinPE (DESIGN 11): the
full-screen progress window driven by the JSONL event stream, and the wizard
whose every page is individually skippable via `HDTSkip*` in MDT's model. Must
degrade to styled console when XAML is unavailable.
*Exit:* a deployment with a fully populated `rules.yaml` shows no wizard at all
and a live progress window; removing one value surfaces exactly that page.

**06 — Drivers.** `.inf` parsing into an index, group match primary, PnP fallback
ranked by specificity → version → date, coverage reporting.
*Exit:* an unrecognized model deploys with working network and storage.

**07 — Apps and full-OS steps.** Application catalog with detection and
dependencies, plus `WindowsUpdate` (multi-pass), `InstallRoles`, `EnableBitLocker`.
*Exit:* a dependency chain installs across a reboot, idempotently; a Server 2025
VM deploys with roles.

**08 — Capture and media.** Sysprep + capture back into the OS catalog;
`New-HDTMedia` content projection to ISO/USB.
*Exit:* media built from the share deploys a machine with no network.

**09 — Console.** WPF thin client over the module, comment-preserving YAML
round-trip, monitoring view.
*Exit:* an admin can build and run a sequence without the command line.

## Sequencing notes

- 02 and 03 encode the model; everything later plugs into them. Spend the test
  effort there.
- 04 before 05 deliberately — proving imaging with local content iterates faster
  than debugging through PXE.
- 09 is last and optional. If it slips, v1 still ships.
