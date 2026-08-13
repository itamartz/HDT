---
phase: 05-bootimage
plan: 03
subsystem: winpe-entry-point
tags: [bootstrap, deploy-root, log-relocation, state-mirror, payload, ast-proof, winpe, pester, tdd, powershell-5.1]

# Dependency graph
requires:
  - phase: 02-rules
    provides: Get-HDTMachineFact, Get-HDTMachineOverride, Import-HDTRuleDocument, Resolve-HDTVariable
  - phase: 03-engine
    provides: Invoke-HDTTaskSequence, New-HDTLogContext, Get-HDTLogPath, Copy-HDTLog, Save-HDTRunState, New-HDTServiceCatalog, New-HDTExecutionContext
  - phase: 04-imaging
    plan: 03
    provides: Invoke-HDTDiskPartitionStep publishing HDTOSVolume, and its help saying the relocation belongs to phase 05
  - phase: 04-imaging
    plan: 04
    provides: tests/e2e/payload/Start-HDTLabDeployment.ps1 and its AST test, the shape this plan copies
  - phase: 05-bootimage
    plan: 01
    provides: workspace.yaml, Get-HDTWorkspacePath's closed folder set
  - phase: 05-bootimage
    plan: 02
    provides: IContentProvider, New-HDTLocalContentProvider, New-HDTSmbContentProvider, Protect-/Unprotect-HDTShareSecret, the catalog's Content service
provides:
  - "Get-HDTBootstrapConfiguration: the read half of the boot image's bootstrap.json, with eight refusals and a credential that is never a property"
  - "New-HDTContentProvider: the one place a provider NAME becomes a provider, so no caller carries a switch"
  - "Resolve-HDTDeployRoot: SPIKES S9.1's six rules - the caller enumerates volumes, this decides, and no drive letter is written in the file"
  - "Set-HDTLogPath: DESIGN 4.4.1's relocation, as a mirror that never throws"
  - "The loop's four-condition trigger, and with it the state mirror and the status heartbeat following the log to the target volume"
  - "src/Hephaestus/Payload/Start-HDTDeployment.ps1: THE WinPE ENTRY POINT - what startnet.cmd runs"
  - "tests/unit/StartHDTDeploymentPayload.Tests.ps1: 40 AST assertions that it does nothing a step would do"
  - "The fake filesystem knows a copy is a write, so a mirror onto a full disk is provable"
affects: [05-04-update-bootimage, 05-05-iso-and-wds, 06-drivers, 07-apps]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "The caller enumerates, the function decides - Resolve-HDTDeployRoot takes candidate volumes rather than finding them, exactly as Select-HDTTargetDisk takes disks"
    - "A secret closed over by GetNewClosure and exposed only through a method, so the object can be serialised into RESULT.json and into log records without carrying it"
    - "A mirror rather than a move, and a failure that warns through the OLD context and returns the old path - because losing the logs is not an acceptable price for moving the logs"
    - "One decision point in the loop, gated on four conditions, replacing three callers each having to remember"
    - "A payload proven by PARSING it, over a comment-free token stream, so the header may explain in prose the rule the assertion enforces"
    - "A poll loop that is also the gather: one Get-HDTMachineFact in the whole entry point, because HDTIPAddress is one of the 18 facts (SPIKES S9.2)"

key-files:
  created:
    - src/Hephaestus/Public/Get-HDTBootstrapConfiguration.ps1
    - src/Hephaestus/Public/New-HDTContentProvider.ps1
    - src/Hephaestus/Public/Resolve-HDTDeployRoot.ps1
    - src/Hephaestus/Public/Set-HDTLogPath.ps1
    - src/Hephaestus/Payload/Start-HDTDeployment.ps1
    - tests/unit/Get-HDTBootstrapConfiguration.Tests.ps1
    - tests/unit/New-HDTContentProvider.Tests.ps1
    - tests/unit/Resolve-HDTDeployRoot.Tests.ps1
    - tests/unit/Set-HDTLogPath.Tests.ps1
    - tests/unit/Invoke-HDTTaskSequence.LogRelocation.Tests.ps1
    - tests/unit/StartHDTDeploymentPayload.Tests.ps1
    - tests/fixtures/bootstrap/valid-smb.json
    - tests/fixtures/bootstrap/valid-local.json
    - tests/fixtures/bootstrap/valid-local-volume-relative.json
    - tests/fixtures/bootstrap/valid-prompt.json
    - tests/fixtures/bootstrap/invalid-unknown-provider.json
    - tests/fixtures/bootstrap/invalid-missing-deployroot.json
    - tests/fixtures/bootstrap/unparseable-truncated.json
  modified:
    - src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTDiskPartitionStep.ps1
    - src/Hephaestus/Hephaestus.psd1
    - tests/helpers/HDTFakes/HDTFakes.psm1
    - tests/unit/New-HDTFakeFileSystem.Tests.ps1
    - tests/unit/Imaging.EndToEnd.Tests.ps1
    - tests/fixtures/README.md
    - docs/DESIGN.md

key-decisions:
  - "The bootstrap's protected secret is NOT a property of the result. It is unprotected eagerly, closed over with GetNewClosure, and reachable only through GetCredential(). The object is written into RESULT.json and into log records; a property holding the share password would put it on the share"
  - "builtUtc is round-tripped explicitly, because pwsh 7's ConvertFrom-Json coerces an ISO 8601 string to [datetime] and Windows PowerShell 5.1 leaves it a string. Casting the pwsh 7 result to [string] gives '08/13/2026 09:14:22' - a machine-local rendering of a timestamp the document is meant to carry verbatim"
  - "Resolve-HDTDeployRoot probes EVERY candidate rather than stopping at the first hit, because rule 6 (two copies of the workspace) can only be detected by looking at all of them - and the refusal message has to name every volume it looked at anyway"
  - "The relocation is a MIRROR. The RAM-disk copy stays. A move that failed halfway would have destroyed the only copy of the log it was called to preserve"
  - "Set-HDTLogPath never throws. A destination that cannot be written produces a Warning through the OLD context, leaves everything on X:, and returns the old path"
  - "seq is not touched by the move. DESIGN 4.4.2's counter is monotonic across the whole run, and a reset at the relocation would be exactly the ambiguity it exists to prevent"
  - "The state mirror and the status heartbeat ride the SAME trigger as the log, because -MirrorStatePath was a literal path the caller had to know in advance - which a boot-time payload cannot, for the same reason it cannot know a drive letter. A caller who DID name one is not overruled"
  - "$PSBoundParameters is EMPTY inside a scriptblock invoked with &, so the two 'was it given explicitly' flags are read once in the function's own scope. The first attempt put the relocation in a scriptblock and silently overruled a caller who had named -MirrorStatePath"
  - "The entry point's address wait IS its gather. HDTIPAddress comes from the same 18 facts Get-HDTMachineFact returns (SPIKES S9.2), so the poll loop keeps the last result and the file has ONE call rather than a second gatherer nobody would keep in step"
  - "The sequence's own defaults are merged AFTER the resolution rather than passed into it, because the rules are one of the three places the sequence id can come from. DESIGN 3.1 puts sequence defaults last, so 'apply where nothing else spoke' is the same precedence by another route - and the file says so"
  - "A copy is a write: New-HDTFakeFileSystem.CopyItem now honours a seeded write failure on its DESTINATION, which is the only way the relocation's failure path could be staged at all"

metrics:
  duration: ~2h
  tasks: 3
  commits: 6
  files-created: 17
  files-modified: 8
  tests-added: 164
  suite-pwsh7: 4439 passed / 0 failed / 54 skipped
  suite-ps51: 4294 passed / 0 failed / 199 skipped
  completed: 2026-08-13
---

# Phase 05 Plan 03: The WinPE entry point and the log that survives the reboot — Summary

`Start-HDTDeployment.ps1` — the file `startnet.cmd` runs — plus the two things it
could not exist without: a bootstrap document that says where the content is, and
a deploy-root resolver that finds the volume WinPE actually assigned. And
DESIGN 4.4.1's relocation, which phase 04 deferred on purpose: `_HDTLogPath`
moves to the target volume the moment one is formatted, so a WinPE deployment
that dies leaves its log somewhere that still exists after the power goes off.

---

## What 05-04 and 05-05 need from this plan

### `bootstrap.json` — the exact shape, and every validation rule

05-04's `Update-HDTBootImage` writes this file into the image at
`X:\HDT\bootstrap.json`. `Get-HDTBootstrapConfiguration` reads it.

```json
{
  "schemaVersion": 1,
  "workspaceId":   "HDT-LAB",
  "provider":      "Smb",
  "deployRoot":    "\\\\HDTSRV01\\HdtShare",
  "contentMarker": "rules.yaml",
  "sequenceId":    "STD-CLIENT",
  "credential":    { "username": "CONTOSO\\svc-hdt-deploy", "protected": "<Protect-HDTShareSecret blob>" },
  "promptForCredential": false,
  "logLevel":      "Info",
  "buildId":       "<guid>",
  "builtUtc":      "2026-08-13T09:14:22Z"
}
```

The rules, each of them a test:

| Rule | Outcome |
|---|---|
| the file is absent, empty, or unparseable | `HDTConfigurationError` **naming the file** — never a raw `ConvertFrom-Json` exception |
| `schemaVersion` > 1 | refused, naming the version and the one it supports |
| `provider` missing or outside `Smb`/`Local` | refused, naming the file, the value, and both legal names |
| `deployRoot` missing or empty | refused |
| `provider: Smb` with a non-UNC `deployRoot` | refused, naming both. Volume-relative is a **Local** idea and does not weaken this |
| `provider: Local`, **rooted** `deployRoot` | legal — what a build host uses, and not an error if it is absent at boot |
| `provider: Local`, **volume-relative** `deployRoot` (`\Share`) | **legal, and the form a boot image should carry** (SPIKES S9.1) |
| no `credential`, `promptForCredential` false, `provider: Smb` | refused, saying the image was built without a credential and naming `-PromptForCredential` |
| `promptForCredential: true` | the credential block may be absent; the result reports `PromptForCredential $true` |
| `sequenceId` empty | legal — the sequence then comes from the rules (DESIGN 3) |
| `credential.protected` that will not decode | refused **at read time**, naming the file, rather than four steps later inside a provider |

Defaults applied: `contentMarker` → `rules.yaml`, `logLevel` → `Info`,
`schemaVersion` → `1`, `promptForCredential` → `$false`.

Projected properties: `SchemaVersion`, `WorkspaceId`, `Provider`, `DeployRoot`,
`ContentMarker`, `SequenceId`, `PromptForCredential`, `LogLevel`, `UserName`,
`HasCredential`, `BuildId`, `BuiltUtc`, `Path` — plus a **`GetCredential()`**
method. **`protected` is not among them.** The plaintext is closed over with
`GetNewClosure()`, so `[string] $bootstrap` and
`ConvertTo-Json -InputObject $bootstrap` both come back without it, which is
asserted.

**05-04 must carry a test that the file it writes is accepted by this reader.**
The seven fixtures under `tests/fixtures/bootstrap/` are **authored, not
captured** — nothing has ever written one of these — and
`tests/fixtures/README.md` says so and says 05-04 writes the real thing.

**`builtUtc` is round-tripped explicitly.** pwsh 7's `ConvertFrom-Json` coerces
an ISO 8601 string to `[datetime]`; Windows PowerShell 5.1 does not. Both engines
now report `2026-08-13T09:14:22Z`. Whatever 05-04 writes there will come back
verbatim.

### `Resolve-HDTDeployRoot` — the six rules and the row it returns

```
Resolve-HDTDeployRoot -DeployRoot <string> -Provider <Smb|Local>
                      [-CandidateRoot <string[]>] [-Marker <string>] [-FileSystem <object>]
    -> [pscustomobject] { Path, Source, Marker, Candidate [string[]] }
```

1. **`Smb`** → the deployRoot unchanged, `Source = 'Configured'`, `Candidate` empty. **Nothing is probed** — the share is not reachable until the provider maps it.
2. **`Local`, rooted, marker found under it** → unchanged, `Source = 'Configured'`.
3. **`Local`, volume-relative** → the marker is looked for under each candidate **in the order given**, first hit wins, `Source = 'Discovered'`. The leading separator is trimmed before `[IO.Path]::Combine`, so `D:\` plus `\Share` is `D:\Share`.
4. **`Local`, rooted, marker NOT there** → the same probe using the path's volume-relative form, plus a `Warning` naming the configured root and the one found.
5. **Nothing matched** → `HDTConfigurationError` naming the deployRoot, the marker and **every candidate, in order** (or saying "no candidate volume was offered at all").
6. **More than one matched** → the first wins and a `Warning` names all of them.

`-Marker` defaults to `rules.yaml`. Every candidate is probed even after a hit,
because rule 6 can only be detected by looking at all of them.

`Candidate` on the row is what it considered, so `RESULT.json` records what the
machine **saw** as well as what it chose.

### `Set-HDTLogPath` — semantics, and the four conditions the loop tests

```
Set-HDTLogPath -Context <logContext> -TargetVolume <string> [-Variable <IDictionary>] -> [string]
```

In order: compute the destination with `Get-HDTLogPath` (never by hand); return
at once if the context is already there; create the destination; **mirror**
everything already written with the tree preserved (`HDT.log`, `HDT.jsonl`,
`status.json`, `Steps\`, `Gather\`, `Native\`); repoint `LogPath`, `JsonlPath`,
`MasterLogPath` and — when a step is mid-flight — `StepLogPath`; set
`_HDTLogPath` when a dictionary was given; write **one** `message` record naming
both paths, through the already repointed context.

- **`Seq` is not touched.** DESIGN 4.4.2's counter is monotonic across the run.
- **It is a mirror.** The RAM-disk copy stays.
- **It never throws.** A destination that cannot be written warns through the
  **old** context and returns the old path.
- **`W`, `W:` and `W:\` all name the same volume.** `Invoke-HDTDiskPartitionStep`
  publishes a **bare letter**, and handing that to `Get-HDTLogPath` untreated
  would have written the logs to a *relative* path on the RAM disk.

The loop calls it after a step's own `step.complete` record, and only when **all
four** hold:

1. `Context.Phase -eq 'WinPE'`;
2. `Context.Variable['HDTOSVolume']` is now non-empty;
3. `Log.LogPath` is still `Get-HDTLogPath -Phase WinPE` (the RAM disk);
4. the step just run reported `Completed`.

When it fires and succeeds, two more things follow, and neither overrules a
caller who named them explicitly:

- `-MirrorStatePath` becomes `<target>\HDT\state.json` (DESIGN 4.3);
- `-StatusPath` becomes `<target>\HDT\Logs\status.json` (DESIGN 4.4.6), so the
  copied-back tree does not carry a stale `Running`.

### `RESULT.json` — the field list, and where it is written

Written by the entry point's tail, UTF-8 with no BOM via
`System.Text.UTF8Encoding($false)`:

```
runId  status  failedStep  message  computerName  sequenceId
provider  deployRoot  resolvedDeployRoot  deployRootSource  candidateRoot
connected  yamlLoaded  yamlVersion  yamlBase  engineVersion  psVersion
elapsedSecond  logPath  logDestination  endedWith  launchedBy
```

- **`launchedBy` is `$env:HDT_LAUNCHED_BY`.** `startnet.cmd` sets it (05-04); a
  human typing the command by hand does not. **05-05 reads this one field to
  prove the deployment started itself.**
- **`endedWith`** is `wpeutil reboot` or `wpeutil shutdown`, decided from the run
  status before it is recorded. ROADMAP M2 left that question open; this is the
  first run that can answer it.
- **Two destinations, in this order.** The primary is
  `Get-HDTWorkspacePath -Root <resolved deployRoot> -Kind Logs` +
  `RESULT.json`, beside `LAUNCHER.log`. `X:\HDT\RESULT.json` is written **as
  well, and it is the fallback, not the record** — `X:` is a RAM disk and the
  machine is about to power off. When no deploy root was resolved, the fallback
  is all there is and `message` says so.

### The entry point's thirteen steps

1. `Set-StrictMode`, `$ErrorActionPreference = 'Stop'`, `$InformationPreference = 'Continue'`.
2. `$ModuleRoot` onto `PSModulePath`; **`powershell-yaml` first**, then `Hephaestus`; the version of each recorded.
3. The eleven real adapters. **A fake never appears in this file.**
4. A log context at `$LogRoot` (default `Get-HDTLogPath -Phase WinPE`), *before* anything can fail.
5. `Get-HDTBootstrapConfiguration`.
6. Wait for a non-APIPA IPv4 — **only when the provider is `Smb`**. The poll is also the gather.
7. Enumerate volumes with `[System.IO.DriveInfo]::GetDrives()` (`IsReady`, `Fixed`/`Removable`), hand them to `Resolve-HDTDeployRoot`, and log the path, the source and every candidate.
8. The credential: `GetCredential()` normally, or **one** `Get-Credential` behind `promptForCredential`, with a `Write-Warning` saying the image deliberately stops for a human.
9. `New-HDTContentProvider` with the **resolved** root, then `Connect()`.
10. The gathered facts → `Get-HDTMachineOverride` (keyed on `HDTUUID`) → `Import-HDTRuleDocument` (at `<root>\<contentMarker>`) → `Resolve-HDTVariable` → the sequence.
11. `New-HDTRunState`, `New-HDTExecutionContext` with a catalog carrying `-Content`.
12. **One** `Invoke-HDTTaskSequence`, with `-State`, `-StatePath` and `-LogDestination`.
13. The tail, **after the catch and never inside the try**: `RESULT.json` (deploy root first, `X:` second), `LAUNCHER.log`, `Copy-HDTLog` again unconditionally, `Disconnect()`, then `wpeutil reboot` or `wpeutil shutdown`.

**Which sequence:** `-SequenceId`, else `bootstrap.sequenceId`, else the resolved
`HDTTaskSequenceID`. None of the three set throws a named
`HDTConfigurationError` rather than guessing.

### What the AST test forbids — so 05-04 does not stage something that violates it

`tests/unit/StartHDTDeploymentPayload.Tests.ps1`, 40 assertions. The file must
**not** contain:

| Forbidden | Why |
|---|---|
| `Get-Disk`, `Clear-Disk`, `Initialize-Disk`, `New-Partition`, `Set-Partition`, `Remove-Partition`, `Get-Partition`, `Format-Volume`, `Get-Volume`, `Remove-/Add-PartitionAccessPath` | `IDiskService` exists to be their only caller |
| `Get-/Expand-/Mount-/Dismount-WindowsImage`, `Add-WindowsDriver`, `Add-WindowsPackage` | `IImageService` likewise |
| `bcdboot`, `bcdedit`, `reagentc`, `diskpart`, `dism.exe` | scanned over the **comment-free token stream** |
| any `Invoke-HDT*Step` | the loop dispatches steps |
| `New-HDTFake*` | a fake never appears in a payload |
| `unattend`, `install.wim` | it writes no unattend and stages no image |
| `Show-*`, `PresentationFramework`, `System.Windows.Forms` | DESIGN 11's technician UI is a later milestone |
| `Write-Host` | the analyzer refuses it; `Write-Information` renders at the WinPE console |
| **any drive letter matching `[C-WYZ]:\`** | SPIKES S9.1 — `X:` is the only guarantee |
| `Get-NetAdapter`, `Get-NetIPAddress`, `New-NetIPAddress`, `Resolve-DnsName`, `Test-NetConnection`, `Get-NetIPConfiguration` | DESIGN 5.1 — no optional component adds them to WinPE |
| the literals `'TaskSequences'`, `'Logs'`, `'Control'` | `Get-HDTWorkspacePath` owns the layout |

And it must contain: exactly one `Invoke-HDTTaskSequence`, one
`Get-HDTMachineFact`, one `Resolve-HDTVariable`, one
`Get-HDTBootstrapConfiguration`, one `Resolve-HDTDeployRoot`, one
`New-HDTContentProvider` (and neither concrete provider factory), one
`Get-HDTMachineOverride`, one `Get-Credential` reachable only under a
`PromptForCredential` guard with a `Write-Warning` beside it,
`GetDrives`, `-Content` on the catalog, `-State`/`-StatePath`/`-LogDestination`
on the loop, `HDT_LAUNCHED_BY`, `UTF8Encoding`, and a `Copy-HDTLog` **and** a
`wpeutil` whose offsets are both **greater than the outermost `try`'s end**.

---

## Task 1 — the bootstrap document and the provider factory

RED: 55 tests, all watched failing with `CommandNotFoundException`. GREEN: three
public commands, seven fixtures, a `tests/fixtures/README.md` section.

`New-HDTContentProvider` is a two-branch factory and nothing else, so the entry
point carries no `switch` and DESIGN 6's future Http transport lands in one file.
**`Http` is named rather than lumped in with a typo**: a caller asking for it has
read DESIGN 6 and is entitled to "not implemented in v1", not to "unknown
provider".

## Task 2 — `_HDTLogPath` follows the deployment

RED: 39 tests. GREEN: `Set-HDTLogPath`, the loop trigger, the rewritten
`Invoke-HDTDiskPartitionStep` help, and a DESIGN 4.4.1 paragraph.

Three things came out of writing it that were not in the plan and are worth
keeping:

- **The step log had to be rebased off the context.** The loop built each step's
  log path from a `$logRoot` captured before the loop started, so after a
  relocation a step would have written half its lines to a RAM disk that was
  about to disappear.
- **`$PSBoundParameters` is empty inside a scriptblock invoked with `&`.** The
  first version put the relocation in a scriptblock, and
  `$PSBoundParameters.ContainsKey('MirrorStatePath')` was `$false` there — so it
  silently overruled a caller who *had* named one. The test caught it; the two
  flags are now read once in the function's own scope, and the code says why.
- **The status heartbeat had to move too**, or the copied-back tree would carry a
  stale `Running` while the live `status.json` died with the RAM disk.

The M3 benchmark gained `has moved the log to the target volume by the end of the
WinPE leg` and `has mirrored the state document to the target volume`, now reads
its records off the **relocated** log (the file that carries the whole leg), and
gained a **record-count floor**: `Get-HDTLogRecord` returns nothing for a file
that is not there, so three "no record of X" assertions were satisfiable by an
empty log. That is SPIKES S9.15b in a new disguise, found by pointing an existing
assertion at a file that did not exist yet.

## Task 3 — `Start-HDTDeployment.ps1`

RED: 33 assertions failing on a file that did not exist. GREEN: the payload, and
40 green assertions.

---

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 1 — Bug] The step log path survived a relocation pointing at the RAM disk**
- **Found during:** Task 2
- **Issue:** `Invoke-HDTTaskSequence` captured `$logRoot` once, before the loop, and built every step's own log file from it. After the relocation the master log and the JSONL moved and the step log did not.
- **Fix:** the per-step path is read off `$log.LogPath` at the top of each iteration.
- **Files:** `src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1`
- **Commit:** `5487918`

**2. [Rule 1 — Bug] `$PSBoundParameters` in a scriptblock silently overruled `-MirrorStatePath`**
- **Found during:** Task 2, by `It 'leaves an explicitly supplied -MirrorStatePath alone'`
- **Issue:** the relocation began life as a scriptblock invoked with `&`. `$PSBoundParameters` is scoped to a `param` block, so inside it the check returned `$false` and a caller who had named a mirror path had it replaced.
- **Fix:** the two flags are captured in the function's own scope before the loop, the relocation is inline in the loop body, and a comment records the trap.
- **Files:** `src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1`
- **Commit:** `5487918`

**3. [Rule 2 — Missing critical behaviour] The status heartbeat did not follow the log**
- **Found during:** Task 2
- **Issue:** DESIGN 4.4.6's `status.json` lives in the log directory and the copy-back ships that directory. Left behind, it would put a stale `Running` in the copy a technician reads while the live one died with the RAM disk.
- **Fix:** `-StatusPath` is repointed at the same trigger, unless the caller named one. Written test-first (`moves the status heartbeat with the log`, `leaves an explicitly supplied -StatusPath alone`).
- **Files:** `src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1`
- **Commit:** `5487918`

**4. [Rule 2 — Missing critical behaviour] The fake filesystem let a copy onto a full disk succeed**
- **Found during:** Task 2
- **Issue:** `New-HDTFakeFileSystem` honoured a seeded write failure for `WriteAllText` and `AppendAllText` but not for a `CopyItem` destination — so DESIGN 4.4.1's "it never throws" failure path could not be staged at all.
- **Fix:** `CopyItem` asserts the destination is writable, after recording. Three tests added to the fake's own suite first.
- **Files:** `tests/helpers/HDTFakes/HDTFakes.psm1`, `tests/unit/New-HDTFakeFileSystem.Tests.ps1`
- **Commit:** `5487918`

**5. [Rule 1 — Bug] `builtUtc` came back as a locale-formatted string under pwsh 7**
- **Found during:** Task 1, by the fixture assertion
- **Issue:** pwsh 7's `ConvertFrom-Json` coerces an ISO 8601 string to `[datetime]`; 5.1 leaves it a string. `[string]` on the pwsh 7 result gave `08/13/2026 09:14:22`.
- **Fix:** round-tripped explicitly with an invariant format when the parsed value is a `[datetime]`.
- **Files:** `src/Hephaestus/Public/Get-HDTBootstrapConfiguration.ps1`
- **Commit:** `b4e7693`

**6. [Rule 1 — Bug] Three benchmark assertions were satisfiable by an empty log**
- **Found during:** Task 2
- **Issue:** pointing `Imaging.EndToEnd.Tests.ps1` at the relocated log exposed that `Get-HDTLogRecord` returns `@()` for a missing file, so `writes no step.fail record`, `never asked for a reboot` and `left the deployment password out of the log` all passed against nothing.
- **Fix:** a record-count floor (`> 20`) and a non-empty assertion on the raw log, both with `-Because` explaining why.
- **Files:** `tests/unit/Imaging.EndToEnd.Tests.ps1`
- **Commit:** `a3f12d6`

### Deliberate departures from the plan text

- **`Set-HDTLogPath` passes `$Context.Phase` to `Get-HDTLogPath`, not a literal `WinPE`.** The plan said `-Phase WinPE`. Using the context's own phase keeps the "a `-TargetVolume` means nothing in the full OS" rule in the one function that owns it: a FullOS context computes `C:\HDT\Logs`, matches the current path, and the call becomes a no-op instead of relocating to a letter that no longer means what it meant in WinPE. Behaviour is identical for every call the loop makes.
- **The entry point merges the sequence's own defaults after `Resolve-HDTVariable` instead of passing `-SequenceDefault` into it.** The plan asked for one `Resolve-HDTVariable` *and* one `Get-HDTMachineFact`, and the sequence id can come from the rules — which are only known after the resolution. DESIGN 3.1 puts a sequence default last, so applying them to names nothing else supplied is the same precedence by another route. The file says so in a comment; the provenance record for those names is the merge log line rather than a `var.resolve` from the resolver.
- **The M3 benchmark's operation filter now excludes the log tree wherever it is, and the state document by name.** It previously excluded `X:\HDT\Logs*`, which stopped being the whole of the log tree. Eight anonymous `FileSystem.WriteAllText` rows for one state document written many times would have made the specification list unreadable; the mirror is asserted on its own instead.

### Not deviations, but worth stating plainly

- **The status heartbeat and the state mirror both move; the PRIMARY state document does not.** DESIGN 4.3 makes the target-volume copy the mirror. Moving the primary would make the mirror the only copy on a machine that has not rebooted yet.

---

## Verification

| Check | Result |
|---|---|
| `pwsh -NoProfile -File ./build.ps1 -Task ci` | **exit 0** — 4439 passed, 0 failed, 54 skipped |
| `powershell.exe -NoProfile -File ./build.ps1 -Task test` | **exit 0** — 4294 passed, 0 failed, 199 skipped |
| `pwsh -NoProfile -File ./build.ps1 -Task integration` | **exit 0** — 59 passed, 0 failed, 18 skipped |
| `pwsh -NoProfile -File ./build.ps1 -Task e2e` | **BLOCKED** — see below |
| `git log --oneline` shows a `test(05-03)` before every `feat(05-03)` | yes, three pairs |
| `Select-String` the payload for `\b[C-WYZ]:\\` | 0 matches |
| `Select-String` `Invoke-HDTDiskPartitionStep.ps1` for `IT DOES NOT MOVE THE LOG` | 0 matches |
| `Select-String` the payload for the five Net cmdlets | 0 matches |
| `Get-Command -Module Hephaestus \| Where Name -like '*LogPath*'` | `Get-HDTLogPath, Set-HDTLogPath` |
| the relocation suite's `seq` continuity test under both engines | green |

### The smoke run, twice, on this host under Windows PowerShell 5.1

Against a scratch workspace at `C:\HDTLab\scratch\smoke\Share` (a `rules.yaml`
and a two-step `NoOp` sequence — **no imaging sequence was run on this machine**):

```
23:45:33  powershell-yaml 0.4.12 loaded from ...\powershell-yaml\0.4.12
23:45:33  Hephaestus 0.1.0 loaded from ...\src\Hephaestus
23:45:33  PowerShell 5.1.26100.8655; launched by 'manual-smoke'
23:45:34  18 machine fact(s) gathered; a Local provider does not wait for the network
23:45:34  deploy root 'C:\HDTLab\scratch\smoke\Share' (Configured); the volumes considered were: C:\
23:45:35  sequence finished: Succeeded
could not write the fallback RESULT.json: Cannot find drive. A drive with the name 'X' does not exist.
HDT run run-20260813-234531 ended Succeeded in 4s; wpeutil shutdown
```

`RESULT.json` landed **under the workspace's `Logs\`**, beside `LAUNCHER.log` and
the copied-back run folder `HDT-SMOKE-01-run-20260813-234531\`, carrying
`launchedBy manual-smoke`, `deployRootSource Configured`,
`resolvedDeployRoot C:\HDTLab\scratch\smoke\Share`, `candidateRoot ["C:\\"]` and
`endedWith "wpeutil shutdown"`.

**A second run with the volume-relative form 05-04 will actually write** —
`"deployRoot": "\\Share..."` — resolved to the same place with
`deployRootSource Discovered`. That is SPIKES S9.1 answered by code on a real
machine rather than by a fake.

**`wpeutil.exe` does not exist outside WinPE**, so the smoke run ends with a
`CommandNotFoundException` and **cannot power the developer's machine off**. The
fallback write to `X:\HDT` fails for the same kind of reason and is reported
rather than fatal. Both are worth knowing: this file is safe to run by hand on a
workstation.

### ⚠ `build.ps1 -Task e2e` is blocked, and the reason is not this plan

```
BUILD FAILED: The 'e2e' task needs the staged Windows 11 media at
'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
```

**`C:\HDTLab\media` no longer exists.** Both staged source trees —
`Win11-LTSC-2024` and `WS2025-Std`, ~11 GB, listed in PROJECT.md as "already
staged, do not re-extract" — are gone. The directory's parent has an mtime of
20:28 today, **before this session began at ~23:15**, and nothing in this plan
deletes anything: no `Remove-Item`, no `-Recurse`, no Hyper-V call, no VHDX. The
guard in `build.ps1` fires before any test runs, so no e2e test executed.

This is the second time a `C:\HDTLab` subtree has disappeared with no established
cause — SPIKES S9.13 records `C:\HDTLab\vms` being emptied during 04-04 and
declines to invent an explanation. `C:\HDTLab\vms` is now empty again.
`C:\HDTLab\Share`, `C:\HDTLab\reference\PSD` and `C:\HDTLab\scratch\pe\` (S1/S3's
WinPE media and ISO) survive.

**`CM01` and `DC01` were never touched and are both `Off`**, confirmed read-only
and name-filtered after the work. There are zero `HDT-*` VMs.

**05-04 and 05-05 need the media restored** (`docs/ROADMAP.md` M4's exit criterion
is a VM deploying from a PXE/ISO boot image). Re-extract from
`C:\Users\Itamartz\Dropbox\System\_FORWORK\SCCM\HydrationKitWS2025\ISO\`. Nothing
in **this** plan is unproven because of it: 05-03 adds no e2e test, and its whole
surface is unit- and AST-proven plus two real smoke runs.

---

## What is now true that was not

- A boot image can say where its content is and how to reach it, in one validated
  file, and a malformed one produces a sentence rather than a stack trace on a
  machine with no operator.
- The engine **finds** its content instead of assuming a drive letter. SPIKES
  S9.1's finding is now an assertion, and a real machine has answered it twice.
- DESIGN 4.4.1's table is true in code for all four rows. A WinPE deployment that
  fails after partitioning leaves its log — and its state document, and its
  heartbeat — on a volume that still exists after the reboot.
- `seq` is continuous across the move, so the one ordering that does not depend
  on WinPE's wrong clock still holds.
- The file `startnet.cmd` will run exists, does nothing a step would do, is
  proven by parsing rather than by hope, and leaves a machine with logs and a
  power state in every path including the ones where it failed before it started.

## Self-Check: PASSED
