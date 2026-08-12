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

- [ ] `02-01-PLAN.md` — CIM/registry/environment/script services (fakes, contracts,
      real adapters), the remaining captured CIM fixtures, and `Get-HDTMachineFact`
- [ ] `02-02-PLAN.md` — `Get-HDTVariableMap`, pointed configuration errors, the YAML
      adapter, `schemas/rules.schema.json` + `machine.schema.json`, and
      `Import-HDTRuleDocument` with thirteen fixture documents
- [ ] `02-03-PLAN.md` — the resolution engine: five-source precedence, wildcard and
      multi-key `when`, `%Var%` expansion with cycle detection, `setFrom:` rules,
      provenance, the sample workspace, and the M1 exit demonstration

**03 — Sequence engine.** Sequencing, conditions, retry, reboot-resume, and the
autologon lifecycle — all against fakes, touching nothing real. Includes the
`SetVariable` / `PowerShell` / `CommandLine` / `Restart` steps and JSONL logging.
*Exit:* a multi-group sequence with reboots runs to completion in a Pester run.

**04 — Imaging.** The destructive parts, guarded. Disk layouts, apply, unattend,
boot config, OS import. Target-disk ambiguity must refuse to proceed.
*Exit:* a Hyper-V VM boots into Windows 11 from a real sequence run.

**05 — Boot image / ISO / PXE.** `Update-HDTBootImage`, `New-HDTBootIso` with
`-NoPromptForKey`, build manifest, WDS import, SMB content provider.
*Exit:* a VM boots the ISO with no keypress; a VM PXE-boots the same image.

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
