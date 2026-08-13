---
phase: 05-bootimage
plan: 01
subsystem: bootimage-decisions
tags: [adk, winpe, optional-components, workspace-document, json-schema, dependency-table, pester, tdd, powershell-5.1]

# Dependency graph
requires:
  - phase: 01-foundations
    provides: the module skeleton, New-HDTErrorRecord, the naming / 5.1 / no-MDT contract tests
  - phase: 02-rules
    provides: the four-file document shape (schema, validator, contract test, fixtures), ConvertFrom-HDTYaml, Test-HDTSchemaVersion
  - phase: 04-imaging
    plan: 02
    provides: Assert-HDTOperatingSystemDocument and Import-HDTOperatingSystem as the exact shape this plan's document work copies
provides:
  - "Get-HDTAdkPath: twelve ADK assets resolved at runtime from KitsRoot10 through an injected IRegistryService, existence-checked through an injected IFileSystem, refused by name"
  - "workspace.yaml as the fifth HDT document type: schemas/workspace.schema.json, Assert-HDTWorkspaceDocument, Import-HDTWorkspaceDocument, WorkspaceSchema.Contract.Tests.ps1, tests/fixtures/workspace/"
  - "samples/workspace/workspace.yaml, the lab's real share, with the three deployRoot forms explained in its own comments"
  - "Get-HDTBootImageComponent: SPIKES S1's verified order merged with the admin's declaration, dependency-validated, cab-existence-checked, language-pack probed"
  - "Get-HDTBootImageComponentDependency: six rows, every one transcribed from the component's own update.mum inside the ADK cab, every one carrying its citation"
  - "tests/fixtures/adk/: this host's real ADK layout and its real WinPE_OCs listing"
affects: [05-02-share-credential, 05-03-deploy-root-and-launcher, 05-04-update-bootimage, 05-05-iso-and-wds, 06-drivers]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "An external toolchain resolved through an injected registry service, so the whole resolution is provable on a machine with none of it installed"
    - "A closed ValidateSet read BACK by the test that counts -All's rows, so the table and the parameter cannot drift apart"
    - "A dependency table whose every row cites the file and the XPath it was transcribed from, with a test that asserts the citation exists"
    - "Injection used to prove a RULE against rows nobody has to believe, while the shipped TABLE is proven separately by its provenance"
    - "Unset and set-to-nothing kept distinguishable end to end - an absent optionalComponents key takes the design defaults, an explicit [] means none"
    - "The validator's own required-key list read out of its source by AST and compared with the schema's required array"

key-files:
  created:
    - src/Hephaestus/Public/Get-HDTAdkPath.ps1
    - src/Hephaestus/Public/Import-HDTWorkspaceDocument.ps1
    - src/Hephaestus/Public/Get-HDTBootImageComponent.ps1
    - src/Hephaestus/Private/Assert-HDTWorkspaceDocument.ps1
    - src/Hephaestus/Private/Get-HDTBootImageComponentDependency.ps1
    - schemas/workspace.schema.json
    - samples/workspace/workspace.yaml
    - tests/fixtures/adk/adk-layout-10.1.26100.2454.json
    - tests/fixtures/adk/winpe-ocs-amd64.json
    - tests/fixtures/workspace/ (13 files)
    - tests/unit/Get-HDTAdkPath.Tests.ps1
    - tests/unit/Assert-HDTWorkspaceDocument.Tests.ps1
    - tests/unit/Import-HDTWorkspaceDocument.Tests.ps1
    - tests/unit/Get-HDTBootImageComponent.Tests.ps1
    - tests/contract/WorkspaceSchema.Contract.Tests.ps1
  modified:
    - src/Hephaestus/Hephaestus.psd1
    - tests/fixtures/README.md
    - tests/contract/ProtectedPath.Contract.Tests.ps1

key-decisions:
  - "DESIGN 6.3 CORRECTED: a password: key under credential: in workspace.yaml is a validation error naming Set-HDTShareCredential. 6.3 showed the password in that file and said in the next line that the value never appears in a file an admin hand-edits; both cannot be true of the same document. The secret lives in Control\\share-credential.json, written by 05-02"
  - "The default boot image name is HDTPE_x64 for architecture amd64, not HDTPE_amd64. The plan said HDTPE_<arch>; DESIGN 2.1 and DESIGN 5 both name the artifacts HDTPE_x64.wim and HDTPE_x64.iso, and the design wins over the plan"
  - "The dependency table is transcribed from each cab's own update.mum package manifest inside the ADK, not from memory and not from a doc page this session could not open. Six components declare a parent that is itself an optional component; the three Microsoft-Windows-*-Package parents are WinPE itself and are deliberately not rows"
  - "WinPE-PowerShell requires WinPE-NetFx ALONE, per its manifest - not WMI and Scripting as the plan's illustrative row supposed. Transcribing rather than remembering changed the answer, which is the whole argument for the rule"
  - "WinPE-Setup-Client -> WinPE-Setup is the one shipped row where both sides are optional, so it is the only refusal the shipped table can produce unaided. The RULE is still proven against an injected table, as the plan required"
  - "Get-HDTAdkPath has no fallback to a literal kit path, not even as a documented example: the check for that rule is a grep, and prose that trips it teaches people to ignore it"
  - "Assert-HDTWorkspaceDocument checks credential.password BEFORE the generic unknown-key message, and never echoes the value - a validator that quotes the secret it is refusing has just written it to the log"

patterns-established:
  - "The Get-HDTAdkPath asset names, which 05-04 and 05-05 resolve every ADK path through"
  - "The Import-HDTWorkspaceDocument projection and its defaults, which 05-02, 05-03 and 05-04 read"
  - "The component row shape (Order, Name, Required, CabPath, LanguageCabPath), which 05-04 applies row by row"
  - "The dependency table shape @{ Requires; Source } and its no-citation-no-row rule"

# Metrics
duration: 150min
completed: 2026-08-13
---

# Phase 05 Plan 01: ADK Resolution, workspace.yaml and the Component Plan Summary

**Every decision the boot image build makes before it mounts anything — where the ADK is, what the share says, and which cabs go in in what order — decided against fakes in three seconds instead of fifteen minutes into an elevated DISM run.**

## Performance

- **Duration:** ~150 min
- **Tasks:** 3 of 3
- **Files created:** 27 · **Files modified:** 3
- **Suite:** **3997 passed / 0 failed / 54 skipped** under pwsh 7.5.8 (`build.ps1 -Task ci`, exit 0); **3852 passed / 0 failed / 199 skipped** under Windows PowerShell 5.1.26100.8655 (`build.ps1 -Task test`, exit 0).
- PSScriptAnalyzer: **0 diagnostics across 282 files.**

New tests, counted per file under pwsh 7:

| File | Tests |
|---|---|
| `tests/unit/Get-HDTAdkPath.Tests.ps1` | 41 |
| `tests/unit/Assert-HDTWorkspaceDocument.Tests.ps1` | 45 |
| `tests/unit/Import-HDTWorkspaceDocument.Tests.ps1` | 25 |
| `tests/unit/Get-HDTBootImageComponent.Tests.ps1` | 29 |
| `tests/contract/WorkspaceSchema.Contract.Tests.ps1` | 31 (skipped under 5.1 — `Test-Json` does not exist there) |
| **Total** | **171** |

## Task Commits

1. **Task 1: `Get-HDTAdkPath`** — `28f3356` (test, 39 failing) → `e41971a` (feat)
2. **Task 2: the workspace document** — `1b229a6` (test, 98 failing) → `4371be7` (feat)
3. **Task 3: the component plan** — `072e6f0` (test, 28 failing) → `4cd9c62` (feat)

Plus `d933436` (a fix to somebody else's red contract test, below) and `b21532a` (a refactor that keeps two grep checks usable).

Every RED commit was **watched failing for the right reason** before its GREEN.

---

## What 05-02, 05-03 and 05-04 are written against

### `Get-HDTAdkPath` — the asset names and what they resolve to on this ADK

```
Get-HDTAdkPath -Asset <closed set> [-Architecture amd64|arm64] [-Language en-us]
               [-Root <string>] [-Registry <obj>] [-FileSystem <obj>] [-SkipExistenceCheck]
Get-HDTAdkPath -All [-Architecture …] [-Root …] [-Registry …] [-FileSystem …]
```

All twelve report `Exists True` on this host. Paths below are under
`C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit` — resolved,
never written down in source:

| Asset | Resolves to (relative to the ADK root) |
|---|---|
| `Root` | *(the ADK root itself)* |
| `DeploymentTools` | `Deployment Tools\amd64` |
| `OscdimgDirectory` | `Deployment Tools\amd64\Oscdimg` |
| `Oscdimg` | `…\Oscdimg\oscdimg.exe` |
| `EtfsBoot` | `…\Oscdimg\etfsboot.com` |
| `EfiSys` | `…\Oscdimg\efisys.bin` |
| `EfiSysNoPrompt` | `…\Oscdimg\efisys_noprompt.bin` |
| `WinPeRoot` | `Windows Preinstallation Environment\amd64` |
| `WinPeWim` | `…\amd64\en-us\winpe.wim` (340 134 390 bytes) |
| `WinPeMedia` | `…\amd64\Media` |
| `WinPeOptionalComponent` | `…\amd64\WinPE_OCs` |
| `WinPeOptionalComponentLanguage` | `…\amd64\WinPE_OCs\en-us` |

- Root resolution: `-Root`, then `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots\KitsRoot10`, then the 32-bit view of the same key. **No literal fallback**, and the trailing separator `KitsRoot10` carries is trimmed.
- A miss is `HDTDependencyError` naming the asset, the path, and **which ADK feature installs it** — `Deployment Tools` or `Windows PE add-on`, because they are separate downloads and separately forgettable.
- `-All` never throws for a missing asset; it reports `Exists $false`. That is what the build manifest records and what an operator runs when a build fails.
- `-SkipExistenceCheck` performs **no** `TestPath` at all, asserted from the fake's journal.

**One arm64 fact worth knowing before 05-05 builds an arm64 ISO:** the ADK ships **no `etfsboot.com` under `Deployment Tools\arm64\Oscdimg`** (there is no BIOS boot on arm64). `Get-HDTAdkPath -Asset EtfsBoot -Architecture arm64` will therefore refuse, correctly, and `-All -Architecture arm64` reports it `Exists False` rather than throwing.

### `Import-HDTWorkspaceDocument` — the projection and every default it applies

```
Import-HDTWorkspaceDocument -Path <file> -FileSystem <obj>
  ->
  SchemaVersion  [int]
  Id, Name, DeployRoot, LogLevel, Path   [string]
  Credential  -> { Username }   or $null when there is no credential block
  BootImage   -> { Name, Architecture, Language, ScratchSpaceMB,
                   OptionalComponent [string[]],
                   ExtraContent [rows of { Source, Destination }],
                   Drivers }
```

| Default | Value | Applied when |
|---|---|---|
| `LogLevel` | `Info` | key absent |
| `BootImage.Architecture` | `amd64` | key absent |
| `BootImage.Language` | `en-us` | key absent |
| `BootImage.ScratchSpaceMB` | `512` | key absent |
| `BootImage.Name` | **`HDTPE_x64`** for amd64, `HDTPE_arm64` for arm64 | key absent |
| `BootImage.OptionalComponent` | `WinPE-SecureStartup`, `WinPE-EnhancedStorage`, `WinPE-WDS-Tools` | key **absent**; an explicit `[]` yields none |
| `BootImage.Drivers` | `''` | key absent |

`BootImage` is **never `$null`** — an absent `bootImage:` block yields the whole
defaults object, because "the admin did not say" and "the admin said nothing
unusual" are the same build.

**`deployRoot` is projected verbatim, all three forms.** UNC (`\\server\HdtShare`),
rooted local (`C:\HDTLab\Share`) and **volume-relative (`\Share`)**. Nothing in
this plan resolves the third: `Resolve-HDTDeployRoot` (05-03) does that inside
WinPE by probing every ready drive for the workspace marker, because SPIKES S9.1
recorded WinPE handing the content disk `C:` while the RAM disk was `X:`.

### `Get-HDTBootImageComponent` — the row shape and the merge

```
Get-HDTBootImageComponent [-OptionalComponent <string[]>] -ComponentRoot <string>
                          [-Language <string>] [-FileSystem <obj>] [-Dependency <hashtable>]
  -> Order [int] · Name [string] · Required [bool] · CabPath [string] · LanguageCabPath [string]
```

The default plan against the real ADK, verified by hand — nine rows, every one
with a language cab:

```
1 WinPE-WMI            Required     6 WinPE-DismCmdlets     Required
2 WinPE-NetFx          Required     7 WinPE-SecureStartup
3 WinPE-Scripting      Required     8 WinPE-EnhancedStorage
4 WinPE-PowerShell     Required     9 WinPE-WDS-Tools
5 WinPE-StorageWMI     Required
```

Adding `WinPE-FMAPI` produces a tenth row with `LanguageCabPath` **empty** and
**exactly one warning** — the verified probe case, never an error.

### The dependency table, as shipped

`Get-HDTBootImageComponentDependency`, six rows, **case-insensitive keys**:

| Component | Requires | Source |
|---|---|---|
| `WinPE-PowerShell` | `WinPE-NetFx` | `WinPE-PowerShell.cab` → `update.mum` → `//package/parent/assemblyIdentity[@name="WinPE-NetFx-Package"]` |
| `WinPE-DismCmdlets` | `WinPE-PowerShell` | same shape, `WinPE-DismCmdlets.cab` |
| `WinPE-StorageWMI` | `WinPE-WMI` | same shape, `WinPE-StorageWMI.cab` |
| `WinPE-PmemCmdlets` | `WinPE-PowerShell` | same shape, `WinPE-PmemCmdlets.cab` |
| `WinPE-SecureBootCmdlets` | `WinPE-PowerShell` | same shape, `WinPE-SecureBootCmdlets.cab` |
| **`WinPE-Setup-Client`** | **`WinPE-Setup`** | same shape, `WinPE-Setup-Client.cab` |

All read from **ADK 10.1.26100.2454, amd64**. A component not in the table is
allowed with no dependencies and no warning.

---

## What transcribing instead of remembering changed

The plan's illustrative row said `WinPE-PowerShell` requires
`WinPE-WMI, WinPE-NetFx, WinPE-Scripting`. **Its manifest declares `WinPE-NetFx`
alone.** Had that row been typed from memory, HDT would today refuse a perfectly
buildable boot image — in the name of a dependency Microsoft does not declare.
That is precisely the failure the plan's "a dependency this repo cannot cite is
OMITTED, never guessed" rule exists to prevent, and it fired on the first row.

**Where the citation came from.** The Microsoft Learn documentation tool was not
available in this session, so a doc page could not be opened and quoted. Rather
than fall back on memory, the table was transcribed from Microsoft's own package
metadata **on this machine**: every `WinPE_OCs\*.cab` contains an `update.mum`
declaring the packages it is a child of, and it is re-derivable in six lines
(recorded in `tests/fixtures/README.md` and in the function's own help). Three
parents — `Microsoft-Windows-WinPE-Package`, `-Foundation-Package`,
`-ServerCore-Package` — are WinPE itself and are deliberately **not** rows: they
are present before any optional component is applied, so a row for them could
only ever refuse a build that was fine.

**A bonus the transcription bought:** a test now asserts that SPIKES S1's
boot-verified order already satisfies every declared dependency, *and in order*.
It does. An order arrived at by booting a machine and an order declared in
Microsoft's manifests agree, which neither source alone could have told us.

**And an asymmetry recorded rather than tidied:** `WinPE-Setup-Client` declares
`WinPE-Setup` as its parent while `WinPE-Setup-Server` and `WinPE-Setup-ASZ`
declare nothing. That is what the manifests say.

---

## The DESIGN 6.3 correction

DESIGN 6.3 shows this:

```yaml
credential:
  username: CONTOSO\svc-hdt-deploy
  password: <set by Set-HDTShareCredential>
```

and says in the very next line that the value *"never appears in a file an admin
hand-edits, so it does not end up in git"*. **Both cannot be true of the same
document** — `workspace.yaml` is the file an admin hand-edits and commits.

Resolved in favour of the sentence, not the sample:

- `credential:` carries a **username and nothing else**; the schema sets
  `additionalProperties: false` on it and the validator checks `password`
  **before** the generic unknown-key message, so the sentence an admin reads is
  the one that says where the secret goes.
- The message names `Set-HDTShareCredential` and `Control\share-credential.json`,
  and **does not echo the value back** — a validator that quotes the secret it is
  refusing has just written it to the log the admin is about to paste somewhere.
  There is a test for that specifically.
- `Import-HDTWorkspaceDocument`'s `Credential` object has exactly one property,
  `Username`. There is nowhere for a password to arrive.
- `samples/workspace/workspace.yaml` says it in a header comment, and a contract
  test greps the sample for `password:`.

**05-02 owns the other half:** `Set-HDTShareCredential` writes
`Control\share-credential.json`. DESIGN 6.3 should be updated to drop the
`password:` line from its example.

---

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 1 — Bug] `tests/contract/ProtectedPath.Contract.Tests.ps1` was red, and green for the wrong reason before that**

- **Found during:** Task 3's full-suite run. The file arrived mid-session in a
  concurrent commit (`5f98a9c`), not from this plan.
- **Issue:** SPIKES **S9.15**, again. `$script:scanFile` was built in
  `BeforeDiscovery` and read inside `It` bodies. Under `./build.ps1`'s StrictMode
  that throws (`the variable cannot be retrieved`) and both real assertions went
  red; under a bare `Invoke-Pester` it is `$null`, `@($null).Count` is **1**, so
  *"scans at least one PowerShell file"* **passed while the scan covered
  nothing**.
- **Fix:** moved the enumeration into `BeforeAll`. Nothing in the file is
  expanded at discovery — there is no `-ForEach` — so the run phase is the only
  place it belongs. Comment records why.
- **Commit:** `d933436`

**2. [Rule 1 — Bug] the component fixture was read with the 5.1 `ConvertFrom-Json` trap**

- **Found during:** Task 3's Windows PowerShell 5.1 leg — 23 red, and green under
  pwsh 7.
- **Issue:** `@(Get-Content … | ConvertFrom-Json)` yields **one element that is
  the whole `Object[]`** under 5.1 (the trap commit `fb51df2` already recorded).
  `$row.Name` then returned all 33 names at once and the fake was seeded with
  `C:\Adk\WinPE_OCs\System.Object[].cab`.
- **Fix:** parse first, enumerate through the pipeline. Comment records why.
- **Commit:** `4cd9c62`

### Deliberate divergences from the plan text

**3. The default boot image name is `HDTPE_x64`, not `HDTPE_amd64`.** The plan's
`<engine_semantics>` said "default `HDTPE_<arch>`", which for architecture
`amd64` reads `HDTPE_amd64`. DESIGN 2.1 and DESIGN 5 both name the artifacts
`HDTPE_x64.wim` / `HDTPE_x64.iso`. The design wins; the ADK's *folder* name is
`amd64` and the *artifact* name is `x64`, and the projection maps between them.
`arm64` is both.

**4. Two comment rewrites so the plan's own grep checks stay usable**
(`b21532a`). Verification items 4 and 5 grep `src/` for a literal kit path and
for the capitalised `WinPE-NetFX`. Both were matching **prose in comment-based
help that was explaining those very rules**. A check with a documented exception
is a check people learn to ignore, so the prose now says the same thing without
writing either string down. Both greps return **0**.

**5. The Microsoft Learn documentation tool was not available**, so the
dependency table is cited to the ADK's own `update.mum` manifests rather than to
a doc page — see *What transcribing instead of remembering changed*. This is a
stronger citation, not a weaker one: it is machine-readable, version-stamped, and
re-derivable on any machine with the ADK.

---

## Verification

| Plan check | Result |
|---|---|
| 1. `pwsh -File ./build.ps1 -Task ci` | **exit 0** — 3997 passed / 0 failed / 54 skipped |
| 2. `powershell.exe -File ./build.ps1 -Task test` | **exit 0** — 3852 passed / 0 failed / 199 skipped |
| 3. a `test(05-01)` commit before every `feat(05-01)` | yes, three pairs |
| 4. no literal kit path in `src/Hephaestus` | **0 hits** |
| 5. no capitalised `WinPE-NetFX` in `src/`; `WinPE-NetFx` present | **0** / **9** hits |
| 6. `Get-HDTAdkPath -All` reports `Exists True` for all twelve | yes, by hand |
| 7. `tests/fixtures/adk/*.json` labelled **captured**, with the capture commands | yes, in `tests/fixtures/README.md` |
| 8. every dependency row cites a source | yes, asserted by a test as well as by inspection |
| Nothing runs DISM, oscdimg, or touches a WIM | correct — no integration or e2e test was added by this plan |

### Integration and E2E — **blocked, and reported rather than tidied away**

Both were attempted through `./build.ps1` (never a bare `Invoke-Pester`), from an
elevated session. Both refused at the same precondition:

```
BUILD FAILED: The 'integration' task needs the staged Windows 11 media at
'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
```

**`C:\HDTLab\media\` does not exist at all** — both staged source trees
(`Win11-LTSC-2024`, `WS2025-Std`) are gone. `C:\HDTLab\Share`, `\scratch`
(including SPIKES S1/S3's WinPE media and both ISOs), `\reference` and `\vms`
survive.

Observed, without claiming a cause:

- The media was **present** during this plan's earlier full-suite runs and
  **absent** by the later ones — the `IImageService` contract's real-adapter row
  went from running to skipping mid-session (42 → 54 skipped), which is that
  guard doing its job and printing a warning rather than failing.
- Nothing in this plan's work touches `C:\HDTLab`. Its only deletes were of two
  scratch folders under `%TEMP%` used to expand cab manifests.
- The developer independently added
  `tests/contract/ProtectedPath.Contract.Tests.ps1` and a PROJECT.md rule in the
  same window (`5f98a9c`, `7a5f146`), which suggests the loss was already known.

**`CM01` and `DC01` were checked by name and are both `Off` and untouched.** No
Hyper-V VM was created, started or removed by this plan.

**Consequence for 05-04 and 05-05:** they build a boot image from the ADK, which
is intact, so they are not blocked. **ROADMAP M4's end-to-end demonstration is**,
until the Windows media is restaged from
`C:\Users\Itamartz\Dropbox\System\_FORWORK\SCCM\HydrationKitWS2025\ISO\`.

---

## Tests that passed on their first run, and were strengthened

- **`refuses an asset outside the closed set`** passed while `Get-HDTAdkPath` did
  not exist — any exception satisfied `Should -Throw`. Now asserts
  `ParameterArgumentValidationError`, so only a real `ValidateSet` satisfies it.
- **`spells NetFx with a lowercase x`** was written with `Should -Contain`, which
  compares **without regard to case** — it would have accepted the very spelling
  the test exists to refuse. Now uses `-ceq`, and additionally asserts the cab
  path it will look for.
- **`reports Exists false rather than throwing`** assigned `$row` **inside** a
  `Should -Not -Throw` scriptblock, which runs in a child scope; the assertions
  after it were reading `$null`. Assignment moved out.

## What is not proven

- **Nothing here has applied a cab or mounted a WIM.** That the nine planned
  components actually install, in this order, into a real `winpe.wim` is 05-04's
  claim to make. SPIKES S1 did it by hand once; the point of 05-04 is that the
  *code* does it.
- **`arm64` is proven only as path construction.** No arm64 WinPE has been built
  or booted, and this ADK ships no `etfsboot.com` for it.
- **`extraContent` is validated and projected, never copied.** The copy is
  05-04's.
- **The volume-relative `deployRoot` is accepted, never resolved.** 05-03 owns
  resolution, and only inside WinPE can it be shown to work.

## Self-Check: PASSED

Every file and every commit hash this summary names was verified to exist, and
the four plan artifacts with a `min_lines` requirement were measured:

| Artifact | Lines | Minimum |
|---|---|---|
| `src/Hephaestus/Public/Get-HDTAdkPath.ps1` | 271 | 150 |
| `src/Hephaestus/Private/Assert-HDTWorkspaceDocument.ps1` | 408 | 150 |
| `src/Hephaestus/Public/Get-HDTBootImageComponent.ps1` | 231 | 140 |
| `src/Hephaestus/Public/Import-HDTWorkspaceDocument.ps1` | 206 | 80 |

`tests/fixtures/workspace/` holds 13 files, as claimed. Eight commits
(`28f3356`, `e41971a`, `1b229a6`, `4371be7`, `072e6f0`, `4cd9c62`, `d933436`,
`b21532a`) are all in `git log`.
