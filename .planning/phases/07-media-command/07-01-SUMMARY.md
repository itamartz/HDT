---
phase: 07-media-command
plan: 01
subsystem: media
tags: [media, workspace-layout, document-family, splice, protected-path]
requires:
  - Get-HDTWorkspacePath
  - Get-HDTSelectionProfile
  - Set-HDTDocumentHeaderKey
  - ConvertFrom-HDTYaml
  - New-HDTErrorRecord
provides:
  - New-HDTMedia
  - Get-HDTMedia
  - Set-HDTMedia
  - Remove-HDTMedia
  - Assert-HDTMediaDocument
  - ConvertTo-HDTMediaCatalog
  - schemas/media.schema.json
  - "Media\\ on the workspace layout"
affects:
  - Get-HDTWorkspacePath
  - New-HDTWorkspace
  - Test-HDTShareAcl
  - Set-HDTDocumentHeaderKey
  - docs/DESIGN.md
  - docs/share-account.md
  - docs/command-reference.html
tech-stack:
  added: []
  patterns:
    - "per-item document family, copied from Applications\\<id>\\app.yaml"
    - "splice, never re-serialise, through Set-HDTDocumentHeaderKey"
    - "manifest beside the artifact, copied from Boot\\<name>.manifest.json"
key-files:
  created:
    - src/Hephaestus/Private/Assert-HDTMediaDocument.ps1
    - src/Hephaestus/Private/ConvertTo-HDTMediaCatalog.ps1
    - src/Hephaestus/Public/New-HDTMedia.ps1
    - src/Hephaestus/Public/Get-HDTMedia.ps1
    - src/Hephaestus/Public/Set-HDTMedia.ps1
    - src/Hephaestus/Public/Remove-HDTMedia.ps1
    - schemas/media.schema.json
    - tests/unit/Assert-HDTMediaDocument.Tests.ps1
    - tests/unit/New-HDTMedia.Tests.ps1
    - tests/unit/Get-HDTMedia.Tests.ps1
    - tests/unit/Set-HDTMedia.Tests.ps1
    - tests/unit/Remove-HDTMedia.Tests.ps1
    - tests/unit/Set-HDTDocumentHeaderKey.Tests.ps1
  modified:
    - src/Hephaestus/Public/Get-HDTWorkspacePath.ps1
    - src/Hephaestus/Private/Set-HDTDocumentHeaderKey.ps1
    - src/Hephaestus/Hephaestus.psd1
    - docs/DESIGN.md
    - docs/share-account.md
    - docs/command-categories.psd1
    - docs/command-reference.html
    - tests/contract/LogEventVocabulary.Contract.Tests.ps1
    - tests/unit/Get-HDTWorkspacePath.Tests.ps1
    - tests/unit/New-HDTWorkspace.Tests.ps1
decisions:
  - "The key set is seven and no more; an eighth is refused by name."
  - "selectionProfile defaults to everything, because MDT's media item does."
  - "output is share-relative unless rooted, resolved at READ time in ConvertTo-HDTMediaCatalog."
  - "The last build is Media\\<id>\\media.manifest.json, not a key in media.yaml."
  - "Set-HDTDocumentHeaderKey is passed -Block '(?!)', because media.yaml is flat."
  - "A media.yaml that will not read is still removable - the read is for the ISO location only."
metrics:
  tasks: 3
  commits: 4
  gate: "13714 passed, 0 failed, 268 skipped; lint 0 diagnostics - both under Windows PowerShell 5.1"
  completed: 2026-09-03
---

# Phase 07 Plan 01: The media document and its four commands — Summary

`Media\<id>\media.yaml` now exists as a validated seven-key document with a JSON
Schema and four commands that create, read, edit and delete one — MDT's media
item, as YAML, built but not yet buildable.

## The seven keys, exactly as shipped

Read off `Assert-HDTMediaDocument`'s `$allowedKey`, which is the one place the
engine writes them down:

```yaml
# HDT standalone media definition - the media item MDT keeps under Advanced Configuration.
# Update-HDTMediaContent projects the share through the selection profile below and writes the ISO.

schemaVersion: 1
id: WIN11-FIELD
name: Windows 11 field media
description: Engineers laptop build, no network     # optional, omitted when empty
selectionProfile: everything
output: Media\WIN11-FIELD\HDT_WIN11-FIELD.iso
enabled: true                                        # optional, defaults true
```

Required: `schemaVersion`, `id`, `name`, `selectionProfile`, `output`.
Optional: `description`, `enabled`.

That header block above is what `New-HDTMedia` actually writes, comments
included — **plan 02 must not re-serialise it.**

## The defaults chosen

| | Value | Why |
|---|---|---|
| `selectionProfile` | `everything` | MDT defaults its media item to Everything; a whole share on a disc is the first answer somebody wants |
| `output` | `Media\<id>\HDT_<id>.iso` | composed relative and **left relative** — a share is authored on one machine and built on another |
| `enabled` | `true` | MDT's media item ships ticked |
| `description` | key not written at all | a key present and blank reads as a failed template substitution |

`-Enabled` is a `[bool]` and not a `[switch]` on all three writing commands,
because the value goes into a document and `-Enabled:$false` has to be sayable.

## What plan 02 needs from this

**The manifest shape is already read.** `Get-HDTMedia` reads
`Media\<id>\media.manifest.json` and projects `LastBuildUtc`, `IsoPath`,
`IsoSizeBytes`, `IsoSha256`. It reads them from the **same shape
`Boot\<name>.manifest.json` uses**, so plan 02 writes:

```json
{ "schemaVersion": 1, "mediaId": "M1", "builtUtc": "2026-09-01T07:13:00Z",
  "artifacts": { "iso": { "path": "...", "sizeBytes": 0, "sha256": "" } } }
```

A manifest that will not parse is treated as a **missing** manifest, not a
failed read.

**`enabled` is a refusal, not a filter.** `Update-HDTMediaContent` must refuse a
disabled item by name and say to run `Set-HDTMedia -Enabled` — not skip it
silently, which reads as a build that did nothing. Nothing in this plan spends
that decision; the value is carried and projected only.

**`OutputPath` is already resolved.** Build to `$media.OutputPath`, never to
`$media.Output` — the first is the second resolved against the workspace root
(or left alone when rooted, including UNC).

## What had to change in `Set-HDTDocumentHeaderKey` for a flat document

Two things, and the second is the one that would have bitten silently.

**1. The `-Key` `ValidateSet` gained `selectionProfile`, `output` and
`enabled`.** It was `name, version, description, folder`. That set is a surface:
a key not in it cannot be spliced at all, so a document that grows an editable
key and forgets this line has a key nothing can edit. The two existing callers
(`Set-HDTTaskSequenceProperty`, `Set-HDTOperatingSystemProperty`) are unaffected
and still green.

**2. `-Block` must be passed as `'(?!)'`, the never-matching group.** The
parameter names the pattern whose line ENDS the header — `steps|variables` for a
sequence, `images` for an os. media.yaml has no nested block at all, and left at
the default a value line opening with one of those words ends the header early:
every key below it is then **inserted rather than replaced**, leaving the
document with two. `tests/unit/Set-HDTDocumentHeaderKey.Tests.ps1` proves both
halves — the correct splice with `'(?!)'` and the duplicate without it.

`''` cannot be used to mean "no block": `-Block` is `[ValidateNotNullOrEmpty()]`
and an empty string is refused at bind time, so the command never runs.

Also worth carrying forward: **`Set-HDTDocumentHeaderKey` treats a whitespace
`-Value` as REMOVE THE KEY** (`$clear = [string]::IsNullOrWhiteSpace($Value)`).
That is what makes `-Description ''` take the description out, and it is why
`-Enabled` is written as the bare lowercase `true`/`false` and must never reach
it as an empty string.

## The layout is one edit

`Media` went into `Get-HDTWorkspacePath`'s `-Kind` `ValidateSet` and **nowhere
else in code**. `New-HDTWorkspace.ps1:172` and `Test-HDTShareAcl.ps1:110` both
read that set by reflection, so a new share gets the folder and the ACL check
without either file being touched — proved by the set-driven tests that were
already there, not by a test naming `Media`.

`Media\` is judged **read-only** by `Test-HDTShareAcl` (it is not in
`$writableFolder`), which is right: a deployment account has no business writing
media.

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 3 - Blocking] `docs/share-account.md` had to name `Media\`**

- **Found during:** Task 1
- **Issue:** `tests/unit/Test-HDTShareAcl.Tests.ps1:350` reads the same `-Kind`
  ValidateSet and asserts the document names every folder the checker judges.
  Adding `Media` to the set turned it red. The plan did not list this surface.
- **Fix:** added the `Media\` row to the ACL table and to the check-it-yourself
  snippet in section 4.
- **Commit:** `51f0256`

**2. [Rule 1 - Bug] `ExampleQuality` contract: a help line opening with `.iso`**

- **Found during:** Task 3
- **Issue:** a wrapped line in `Assert-HDTMediaDocument`'s `.DESCRIPTION` began
  `.iso, and carrying no '..' segment`. A help line opening with a dot is read
  as a section keyword and everything after it is dropped.
- **Fix:** reworded to "ending in an .iso extension".
- **Commit:** `a461ae3`

**3. [Rule 1 - Bug] `LogEventVocabulary` contract read the whole of DESIGN.md**

- **Found during:** Task 3
- **Issue:** it extracts event names with `^\|\s*`([a-z]+(?:\.[a-z]+)?)`\s*\|`
  across the entire document, on a comment claiming no other table has such a
  row. DESIGN 6.2's new key table made that false: `id`, `name`, `description`,
  `output` and `enabled` were read as log event names and the suite reported five
  names `Write-HDTLog` would reject. **The test was wrong, not the document.**
- **Fix:** cut section 4.4.2 out first and extract from that, with the reason
  recorded above the code. Strictly more correct than it was — it now reads the
  section it always claimed to.
- **Commit:** `a461ae3`

**4. [Rule 1 - Bug] Two `It` names carried `<id>`**

- **Found during:** Task 3, by the gate and not by a direct run
- **Issue:** `<id>` is Pester's own data-substitution syntax and resolves as
  `$id`; under the gate's StrictMode that throws
  "The variable '$id' cannot be retrieved because it has not been set."
  Green in a direct `Invoke-Pester` run, red in `./build.ps1 test`.
- **Fix:** renamed both.
- **Commit:** `a461ae3`

**5. [Rule 1 - Bug] A broken `media.yaml` could not be removed**

- **Found during:** final verification, by **running the module against a real
  share** rather than by any fake
- **Issue:** the round trip added an eighth key by hand to prove the validator
  refuses it — and then `Remove-HDTMedia` could not delete the item, because it
  calls `Get-HDTMedia` before deleting and that validates. A media.yaml that no
  longer validates is exactly the one somebody wants gone, so this was a delete
  nobody could ever do.
- **Fix:** the document is read for one thing — where the ISO was written — so a
  read failure costs that answer and nothing else. It now warns naming the read
  failure and removes the folder. Two tests cover it: a document that will not
  validate and one that will not parse.
- **Commit:** `09eb901`

**6. [Rule 3 - Blocking] `PSUseSingularNouns` on all four commands**

- **Found during:** Task 3 lint
- **Issue:** the analyzer reads "Media" as the Latin plural of "medium".
- **Fix:** `SuppressMessageAttribute` on each, with the justification — Media is
  MDT's own name for the Deployment Workbench node and for Update Media Content,
  DESIGN 6.2 names these four commands, and plan 03 calls `Get-HDTMedia` by name.
  Renaming to `MediaItem` would make HDT the only toolkit an MDT admin has to
  translate. Precedent: `Import-HDTBootImageToWds` carries the same suppression.
- **Commit:** `a461ae3`

### Deliberately not done

- **No `media.yaml` under `Templates\` or `samples/workspace\`.** The plan says
  so and it is right: `ShippedDocumentSchema.Contract.Tests.ps1` pairs a schema
  with a shipped document by name, and a template media item would be a media
  definition on every new share nobody asked for. A media item is created, not
  seeded. That suite is green with the schema pairing with nothing.
- **The second path check in `Remove-HDTMedia` cannot be independently
  triggered.** Every way of escaping `Media\` carries a separator, which the
  typed-id check blocks first. It is kept as a backstop — a recursive delete is
  worth two cheap checks — and the test says so honestly rather than claiming it
  fires.

## The lab share

`C:\HDTLab\Share` predates this change and had no `Media\` folder, so
CLAUDE.md rule 8's corollary applies: **the folder was created there** (additive,
nothing overwritten). `New-HDTMedia` creates it on demand anyway, but
`Test-HDTShareAcl` judges the whole layout and would have reported it missing.

Noticed while doing it and **not touched**, because it is a pre-existing gap
outside this plan: that share also has no `Modules\` folder.

## Verification

- `./build.ps1 test` — **13714 passed, 0 failed, 268 skipped**, Windows
  PowerShell 5.1.26100.8655
- `./build.ps1 lint` — **0 diagnostics across 1128 files**, run as a separate
  process
- A real round trip on a real temp share, against the real module:
  `New-HDTWorkspace` → `New-HDTMedia` → `Get-HDTMedia` → `Set-HDTMedia` →
  `Get-HDTMedia` → `Remove-HDTMedia`. Editing `name` and `enabled` in one call
  changed **exactly two line indices, 5 and 8**, with all three comments intact.
  An eighth key added by hand was refused by name. `-Id '..\..\Windows'` was
  refused before anything was deleted. The temp share was removed by the same
  code that created it.
- No VM, no Hyper-V, no ADK and no ISO was touched. Every unit test runs against
  `New-HDTFakeFileSystem` with the workspace root at `X:\Share`, a drive this
  session has not mounted — a command that dropped `-FileSystem` on a call to
  another HDT command would read the real disk and fail there.

## Self-Check: PASSED
