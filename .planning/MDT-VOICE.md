# Instruction — MDT mentions in comment-based help

**Scope: comment-based help only** (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`,
`.EXAMPLE`, `.NOTES`, `.OUTPUTS`) in `src/Hephaestus/**/*.ps1`. 139 functions
carry the word today. Code comments outside a help block, `docs/`, `.planning/`
and tests are **out of scope** for this pass.

## Why

`Get-Help Get-HDTDiskPartitionStepTemplate` currently opens with *"MDT's Format
and Partition Disk grid, answered without a window."* That sentence only lands
for somebody who has used MDT. HDT is the product; MDT is the thing it replaces
and, since 2019, a thing a reader may never have seen. Help must describe what
**HDT** does, completely, on its own terms. MDT may follow as orientation — it
must not be the explanation.

This is a voice change. **Nothing about behaviour changes.**

## The three buckets

Classify every MDT mention into exactly one.

### 1. REWRITE — MDT is doing the explaining

The tell: delete the MDT clause and the sentence no longer says what the command
does.

> `Get-HDTDiskPartitionStepTemplate`
> before: "MDT'S Format and Partition Disk GRID, answered without a window."
> after:  "The disk layout a sequence starts from, as data rather than a dialog:
>          an ordered list of partitions with size, type and letter."

Note what the "after" does NOT do: it does not append a parenthesis naming the
MDT dialog. Deleting the reference outright is the expected outcome for most of
this bucket.

Rules for the rewrite:

- State the HDT behaviour first and in full. The first sentence must stand alone
  with the word MDT deleted.
- Where the MDT reference genuinely orients — HDT deliberately copied that shape
  — keep it as **one trailing clause or one parenthetical**, never the opening.
- Never more than one MDT reference per help section.
- **Never reach for the same construction twice.** A first run of this
  instruction produced "(MDT administrators know this as X.)" twenty-three
  times, because the worked example above used to end that way. Read verbatim
  across a fifth of the module, a formula is a find-and-replace rather than
  writing. Where a reference does survive, write it as a sentence belonging to
  that particular function.
- Drop SHOUTED headings that are MDT comparisons (`MDT'S X IS Y`). Those are
  design rationale: move them to a `#` comment above the code if they are not
  already there, do not carry them into help.

### 2. KEEP — MDT is the subject matter

These are facts about a real translation surface. Removing them breaks the
product's purpose and the contract tests.

- `Get-HDTVariableMap` — its whole job is the MDT→HDT name table, and
  `tests/contract/VariableNamespace.Contract.Tests.ps1` asserts the mapping.
  The `MdtName` property stays; the help that documents it stays.
- File names HDT reuses on purpose: `Bootstrap.ini`, `CustomSettings.ini`.
  Name them; a sentence explaining *whose* they were may stay if it is one
  clause.
- The `HDT variable name is not an MDT one; run Get-HDTVariableMap` error
  message text quoted in help — the message itself is out of scope.

Trim these for length if they ramble, but do not de-MDT them.

### 3. CUT — MDT as filler or repo-internal argument

Delete outright, no replacement:

- Appeals to project rules: "CLAUDE.md asks for MDT's shape where MDT and a
  fresh idea disagree, and MDT's shape here is…". That is a decision record,
  not help.
- "…which is what MDT does", "…as MDT's own sequence has", "MDT needs its
  Nothing because…" where the surrounding sentence already stated HDT's
  behaviour. Redundant justification.
- The repeated boilerplate line in ~20 `Get-HDT*StepDescription` functions:
  `'<Type>: <name>' instead, which is what MDT's progress line shows.`
  → `'<Type>: <name>' instead.`

## Hard constraints

1. **Help text only.** No change to code, parameter names, `[OutputType]`,
   `.OUTPUTS` type names, or any string the module emits at runtime.
2. **`src/Hephaestus/Hephaestus.bundle.ps1` is generated** — never hand-edit it.
   `./build.ps1 -Task bundle` regenerates it from `Private/` and `Public/`.
3. **PS 5.1 syntax** and existing formatting: same indentation, same ~78-column
   wrap, ASCII hyphens (the tree uses `-`, not en dashes).
4. **`.EXAMPLE` blocks keep their runnable command and their result sentence.**
   Only the prose changes.
5. **Every function keeps a `.SYNOPSIS` and `.DESCRIPTION`.** A rewrite that
   empties a section is a defect — `tests/contract/` checks help completeness.
6. One MDT reference maximum per help section; zero is fine and often better.
7. **Atomic commits**, grouped by area (Private, Public, Public/Steps), one
   logical unit each.

## Done means

```powershell
./build.ps1 -Task bundle
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "./build.ps1 test"
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "./build.ps1 lint"
```

green (5.1 is the gate; run the analyzer in its own process), and the MDT
mention count in help down from 139 functions to the KEEP set only — expected
to be roughly a dozen, all of them about the variable map, `Bootstrap.ini` or
`CustomSettings.ini`.

Re-run the census to check:

```powershell
# AST-parse src/Hephaestus/**/*.ps1, GetHelpContent(), match 'MDT'
```
