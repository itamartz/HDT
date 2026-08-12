# CLAUDE.md — Hephaestus Deployment Toolkit (HDT)

A replacement for the Microsoft Deployment Toolkit (MDT), which has been in
maintenance mode since 2019. Same operational model — deployment share, task
sequences, driver store, application catalog — rebuilt on PowerShell instead of
VBScript/WSH.

## Specification — read before changing anything

| Document | What it holds |
|---|---|
| `docs/DESIGN.md` | Full technical design, 15 sections. Authoritative. |
| `docs/ROADMAP.md` | Milestones M0–M8, each with a "Tests first" list and exit criteria |
| `.planning/PROJECT.md` | Settled decisions, environment, lab safety rules, staged media, ADK paths |
| `.planning/SPIKES.md` | **Verified-by-execution environment findings.** Read before writing anything that touches WinPE, oscdimg, Pester imports, or Hyper-V — it records traps already hit and the working fixes |

These already settle nearly every design question. **Do not re-derive or
contradict them.** If you believe one is wrong, say so and update the document —
don't quietly diverge in code.

## Commands

```powershell
./build.ps1 test        # unit + contract suites
./build.ps1 lint        # PSScriptAnalyzer
./build.ps1 ci          # what CI runs
Invoke-Pester tests/unit -Output Detailed          # one suite
Invoke-Pester tests/unit/Rules.Tests.ps1           # one file
```

Always verify under **both** shells before calling something done:

```powershell
pwsh -NoProfile -Command "./build.ps1 test"
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "./build.ps1 test"
```

## Hard rules

These are enforced by contract tests. Breaking one is a defect, not a style
preference.

1. **TDD.** A failing Pester test exists before the implementation it covers.
   Every time. The sole exception is thin adapters over external tools (DISM,
   CIM, oscdimg, registry) — and those must stay branch-free *because* they are
   not unit tested.

2. **Windows PowerShell 5.1 syntax** in `src/Hephaestus/`. The engine runs inside
   WinPE, which has no `pwsh`. Forbidden: `??`, `?.`, ternary, `ForEach-Object
   -Parallel`, `$PSStyle`, `clean` blocks, `ConvertFrom-Json -AsHashtable`.

3. **`Verb-HDTNoun`, uppercase HDT** — public cmdlets, private helpers, adapters,
   test helpers, build functions alike. Approved verbs (`Get-Verb`), singular
   nouns. The engine dot-sources user scripts from `Scripts\` and third-party
   step types from `Modules\`, so an unprefixed `Invoke-Dism` is a live
   collision risk in WinPE.

4. **Zero MDT dependencies.** MDT is deprecated; a replacement that needs it
   installed isn't a replacement. No `MicrosoftDeploymentToolkit` module,
   `MDTProvider` drive, `Microsoft.BDD.*` assembly, `ZTI*`/`LTI*` script,
   `ts.xml`, MDT `Control\` layout, or MDT database schema. **ADK and WDS are
   fine** — they're independent Microsoft products.

5. **Engine logic never touches hardware directly.** Steps take injected
   services (`IDiskService`, `IImageService`, `IContentProvider`,
   `ICimProvider`, `IFileSystem`, `IRegistryService`, `ILsaService`) so the whole
   engine runs under Pester against hand-written fakes. The benchmark test is a
   full multi-group sequence with reboots executing end-to-end against fakes and
   asserting the exact ordered operation list.

6. **`SupportsShouldProcess` on anything destructive**, and refuse ambiguous
   targets. `DiskPartition` must not guess which disk to wipe.

7. `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` in
   engine code.

## Architecture in one paragraph

A **workspace** (deployment share) is a directory tree of YAML plus content.
`rules.yaml` resolves variables from five prioritised sources and records
*provenance* for each one. A `sequence.yaml` is an ordered tree of **steps**;
the engine executes them against injected services, checkpointing to `state.json`
so it survives reboots — including the one where the OS changes underneath it.
Resume in the full OS uses autologon as the local Administrator (MDT's model)
with a per-deployment random password in an LSA secret, bounded by
`AutoLogonCount`, torn down in a `finally` plus a boot-time reconcile. One boot
image build emits both a `.wim` (for WDS/PXE) and a hash-identical `.iso` (for
VM debugging). Standalone media is a *content projection* of the share with the
provider swapped, not a second code path.

## Reference implementation

`C:\HDTLab\reference\PSD` — friendsOfMDT/PSD, MIT licensed. The closest prior
art: MDT's LiteTouch rebuilt in PowerShell, proven on real hardware.

**Mine it for mechanism, not structure.** It gives you the exact DISM argument
that works, the CIM property that's empty on VMs, the registry value Winlogon
actually reads. It is procedural and calls hardware directly — copying its shape
would defeat rule 5. It is also an *MDT extension*, so every MDT dependency in it
must be stripped, not carried across (rule 4). Where PSD and `docs/DESIGN.md`
disagree, the design wins. Derived code needs a comment on the function and an
entry in `NOTICE.md`.

## ⚠ Hyper-V lab safety

This host runs the user's **live lab**. Damaging it is worse than failing a test.

- **Never touch `CM01`** (SCCM server, runs a PXE responder) **or `DC01`**
  (domain controller). Both on `Default Switch`, 192.168.25.0/24.
- HDT test VMs: named `HDT-*`, **Generation 2**, on the isolated **`HDT Lab`**
  switch only, files in `C:\HDTLab\vms\`, under 12 GB combined.
- **PXE/WDS testing only on `HDT Lab`** — on `Default Switch` it would collide
  with CM01's PXE, breaking their lab or silently invalidating the test.
- Never run an unfiltered Hyper-V pipeline. Filter to `HDT-*` explicitly.

## Lab assets (already staged — don't re-extract)

| Asset | Path |
|---|---|
| Windows 11 Ent LTSC 2024 source | `C:\HDTLab\media\Win11-LTSC-2024\` (index 1) |
| Windows Server 2025 source | `C:\HDTLab\media\WS2025-Std\` (index 2 = Desktop Experience) |
| ADK 10.1.26100.2454 | `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit` |
| `oscdimg` / `efisys_noprompt.bin` | `…\Deployment Tools\amd64\Oscdimg\` — **not** the WinPE `Media\EFI\` tree |
| WinPE OCs | `…\Windows Preinstallation Environment\amd64\WinPE_OCs\` |

Resolve ADK paths at runtime via `Get-HDTAdkPath`; the layout has moved between
ADK releases.

## Repo layout

```
src/Hephaestus/     PowerShell module — the engine
src/HDT.Console/    WPF console (last, optional)
schemas/            JSON Schema per YAML file type
tests/unit/         Majority of tests — pure logic against fakes
tests/contract/     Schema, naming, no-MDT, PS5.1-syntax, provider contracts
tests/integration/  Real DISM/VHDX/ADK
tests/e2e/          Hyper-V
tests/fixtures/     Real .inf headers, captured CIM shapes, sample workspaces
.planning/          GSD phase plans, research, verification reports
.claude/workflows/  hdt-phase.js — the per-phase build pipeline
```

## Conventions

- Fixtures come from **real captured data** (`Get-CimInstance` on actual
  hardware, real `.inf` headers), never invented shapes.
- Fakes are **hand-written**, not `Mock` — readable failures. `Mock` is reserved
  for the adapter boundary.
- Atomic commits, one logical unit each.
- Comment-based help on every public cmdlet.
