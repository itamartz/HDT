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

## Test media available

| Purpose | Path |
|---|---|
| Windows 11 client | `C:\Users\Itamartz\Dropbox\System\_FORWORK\SCCM\HydrationKitWS2025\ISO\Windows 11 Enterprise LTSC 2024\SW_DVD9_WIN_ENT_LTSC_2024_64-bit_English_MLF_X23-70046.ISO` |
| Windows Server 2025 | `C:\Users\Itamartz\Dropbox\System\_FORWORK\SCCM\HydrationKitWS2025\ISO\Windows Server 2025 Standard\SW_DVD9_Win_Server_STD_CORE_2025_24H2_64Bit_English_DC_STD_MLF_X23-*.ISO` |
| ADK offline installers | `C:\Users\Itamartz\Dropbox\System\_FORWORK\SCCM\Downloads\ADK` and `...\ADKWinPE` |

## Scratch areas (never commit these)

- `C:\HDTLab\` — deployment share under test, VHDXs, VM files, mounted WIMs
- `C:\HDTLab\Share` — the scratch workspace integration tests build against

## Repo layout

```
src/Hephaestus/        PowerShell module (the engine)
src/HDT.Console/       WPF console (M8, last)
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
