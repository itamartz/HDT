---
phase: 08-windows-update
plan: 08-01-04
subsystem: steps
tags: [windows-update, step-type, authoring-surface, console, samples, shipped-template, set-based-test]
requires:
  - 08-01-03
provides:
  - Get-HDTWindowsUpdateStepTemplate
  - Get-HDTWindowsUpdateStepDescription
  - "Get-HDTConsoleStepCatalog: WindowsUpdate, Gather"
  - "Get-HDTStepPropertyChoice: WindowsUpdate/categories"
  - "Get-HDTStepPropertyDefinition: WindowsUpdate"
  - tests/unit/WindowsUpdateStepSurface.Tests.ps1
  - tests/fixtures/sequences/valid-windows-update.yaml
affects:
  - src/Hephaestus/Private/Get-HDTConsoleStepCatalog.ps1
  - src/Hephaestus/Private/Get-HDTStepPropertyChoice.ps1
  - src/Hephaestus/Private/Get-HDTStepPropertyDefinition.ps1
  - src/Hephaestus/Hephaestus.psd1
  - src/Hephaestus/Templates/client.yaml
  - samples/workspace/TaskSequences/STD-CLIENT/sequence.yaml
  - samples/workspace/TaskSequences/STD-SERVER/sequence.yaml
  - tests/contract/StepContract.Tests.ps1
  - tests/contract/StepVariableExpansion.Contract.Tests.ps1
  - docs/command-categories.psd1
  - docs/command-reference.html
  - docs/DESIGN.md
  - docs/ROADMAP.md
  - "C:\\HDTLab\\Share\\TaskSequences\\PNP-TEST\\sequence.yaml (spliced, outside the repository)"
tech-stack:
  added: []
  patterns:
    - "A set-based surface test: walk Get-HDTStepType and the step files on disk, ask the question for EVERY type"
    - "Discovery-scope -ForEach data, guarded by a second read of the same folder"
key-files:
  created:
    - src/Hephaestus/Public/Steps/Get-HDTWindowsUpdateStepTemplate.ps1
    - src/Hephaestus/Public/Steps/Get-HDTWindowsUpdateStepDescription.ps1
    - tests/unit/WindowsUpdateStepSurface.Tests.ps1
    - tests/fixtures/sequences/valid-windows-update.yaml
  modified:
    - src/Hephaestus/Private/Get-HDTConsoleStepCatalog.ps1
    - src/Hephaestus/Private/Get-HDTStepPropertyChoice.ps1
    - src/Hephaestus/Private/Get-HDTStepPropertyDefinition.ps1
    - src/Hephaestus/Templates/client.yaml
    - samples/workspace/TaskSequences/STD-CLIENT/sequence.yaml
    - samples/workspace/TaskSequences/STD-SERVER/sequence.yaml
decisions:
  - "The console offers the step ONCE, named 'Windows Update' on the General shelf - not 'Install Updates Offline', which is MDT's name for the offline step and is HDT's ApplyUpdates"
  - "Both steps ship DISABLED in client.yaml, because MDT's own Client.xml does - read off the file on this host, not remembered"
  - "The template writes server: '%HDTWSUSServer%' and the step REFUSES an unresolved token; an ABSENT server key is what means Windows Update"
metrics:
  tasks-completed: 2
  tasks-blocked: 1
  duration: ~2h
  completed: 2026-09-06
---

# Phase 08 Plan 04: Every authoring surface for the WindowsUpdate step Summary

The `WindowsUpdate` step became creatable — template, description, console shelf,
properties sheet, closed-set drop-down, schema fixture, manifest and docs — all
proven by a test that walks the SET rather than naming the new type; the E2E on a
machine is **blocked** on `HDT-WSUS-01` having no DNS record.

## What was built

**Task 1 — the surfaces (commit `79dc68e`).** `Invoke-HDTWindowsUpdateStep`
landed in plan 08-01-03 and the registry discovered it that minute. Every
authoring surface stayed silent: no template, so `CanAdd` was false and the Add
menu left it out; no description, so the log said `WindowsUpdate: Windows Update`
and nothing about what the step would do; no properties rows; and the step
contract's hand-written list did not name it — **one failing assertion out of 276
for a type that was invisible in five other places.**

`tests/unit/WindowsUpdateStepSurface.Tests.ps1` walks `Get-HDTStepType` and the
files on disk and asks the question for every type, so it goes red for the next
step type anybody adds in whichever surface they forget. Where a set assertion
already existed — `ConsoleStepCatalog`, `StepPropertyDefinition`,
`StepTemplate.Contract`, `StepContract` — the file points at it and does not copy
it.

**Task 2 — the samples, the shipped template and the docs (commit `1b8f87e`).**
Both samples run the step twice, bracketing `Install Applications`, under MDT's
own names for its two instances. `src/Hephaestus/Templates/client.yaml` — the
file every new workspace is seeded from — carries both, both `disabled: true`.
DESIGN 10.1 and ROADMAP record that the step was deferred on 2026-08-16 and
**built on 2026-09-06**, with the deferral history struck through rather than
deleted.

**Task 3 — the E2E: NOT DONE, and see "Blocked" below.**

## Checked rather than remembered

MDT's own `C:\Program Files\Microsoft Deployment Toolkit\Templates\Client.xml`
on this host, read this session:

```
line 378  <step name="Windows Update (Pre-Application Installation)"  disable="true" continueOnError="true" ...>
line 381  <step type="BDD_InstallApplication" name="Install Applications" disable="false" ...>
line 388  <step name="Windows Update (Post-Application Installation)" disable="true" continueOnError="true" ...>
```

Two instances, both disabled, bracketing the applications step. `client.yaml`
now ships exactly that shape. MEMORY, "HDT is a homage to MDT": when MDT and a
fresh idea disagree about behaviour, build MDT's.

## The lab share was spliced

CLAUDE.md rule 8's corollary — a change to `Templates\` that `C:\HDTLab\Share`
does not have is a change nobody here can test, because the next deployment runs
the SHARE's copy.

**File spliced:** `C:\HDTLab\Share\TaskSequences\PNP-TEST\sequence.yaml` — the
share's own client sequence, and the one both media VMs ran. **Spliced, never
replaced**: the rest of that file is somebody's edits. It imports to 17 steps
with the two new ones at index 11 and 15, both `Disabled True`. No other sequence
on the share was touched.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `Gather` was offered under Custom**
- **Found during:** Task 1, by the new set-based test on its first run
- **Issue:** `Get-HDTConsoleStepCatalog`'s `$known` table had never been given a
  row for `Gather`, the only type this repository ships that was missing one. The
  Add menu offered it on the **Custom** shelf, named by its type — the shelf
  meant for a third-party step out of `Modules\`. Nothing noticed because the
  test guarding that shelf named three types by hand (`InstallApplications`,
  `InstallRoles`, `EnableBitLocker`) rather than walking the set. This is
  precisely the failure mode CLAUDE.md describes: "a test that names your new
  thing passes for it and fails nobody after it."
- **Fix:** `'Gather' = @{ Text = 'Gather'; Category = 'General'; Order = 11 }`,
  MDT's own word for the step, on MDT's own shelf.
- **Files modified:** `src/Hephaestus/Private/Get-HDTConsoleStepCatalog.ps1`
- **Commit:** `79dc68e`

**2. [Rule 1 - Bug] The template's help contradicted the step, and so did client.yaml**
- **Found during:** Task 2, by the full gate — two red rows in
  `StepVariableExpansion.Contract.Tests.ps1`
- **Issue:** The help I wrote said an unset `HDTWSUSServer` "means Windows
  Update". It does not. `Expand-HDTVariableToken` leaves a token nothing supplied
  LITERAL, and `Invoke-HDTWindowsUpdateStep` refuses the text `%HDTWSUSServer%`
  **on purpose** — writing it into the `WUServer` policy value takes a machine
  off Windows Update without putting it onto anything. An **absent** `server` key
  is what gives you Windows Update. `client.yaml`'s comment repeated the same
  wrong claim, which would have sent a technician to enable a step that then
  failed with a message they had been told to expect not to see.
- **Fix:** Corrected both, and added a test that pins the template and the step's
  refusal message together so the prose cannot drift from the code again.
- **Files modified:** `Get-HDTWindowsUpdateStepTemplate.ps1`,
  `src/Hephaestus/Templates/client.yaml`,
  `tests/unit/WindowsUpdateStepSurface.Tests.ps1`
- **Commit:** `1b8f87e`

**3. [Rule 3 - Blocking] The expansion probe's two list rows went red the moment a template existed**
- **Found during:** Task 2, same gate run
- **Issue:** `StepVariableExpansion.Contract.Tests.ps1` builds its starting bag
  from the step type's **own template** — and 08-01-03's own comment predicted
  this ("a type whose template is not written YET"). Once a template existed it
  wrote `server: '%HDTWSUSServer%'`, so the `categories` and `exclude` runs both
  died at the server refusal before reading the property under test, and matched
  each other perfectly while proving nothing.
- **Fix:** Both rows carry `Extra = @{ server = 'http://wsus.contoso.local:8530' }`
  — the same shape `ApplyImage`'s `target` row uses to carry `os`, and
  `JoinDomain`'s `ou` row uses to carry `domain`.
- **Files modified:** `tests/contract/StepVariableExpansion.Contract.Tests.ps1`
- **Commit:** `1b8f87e`

**4. [Rule 1 - Bug] A test of mine passed by not existing**
- **Found during:** Task 2's own RED run
- **Issue:** I built the samples' `-ForEach` list in a `BeforeAll`. `-ForEach` is
  read while Pester DISCOVERS; a `BeforeAll` runs later, so the list was `$null`
  at the moment the cases would have been generated, Pester generated **none**,
  and six assertions were reported as passing by not existing — a run that said
  37 tests where 43 were written.
- **Fix:** File-scope declaration read off the disk (`STD-*`), plus a guard that
  reads the same folder a second time and asserts the count. The guard cannot be
  written against the list itself: a file-scope variable is `$null` in a test
  BODY, and `@($null).Count` is 1, so the obvious version passes for the wrong
  reason on an empty list and fails for the wrong reason on a full one.
- **Files modified:** `tests/unit/WindowsUpdateStepSurface.Tests.ps1`

### Deliberate departures from the plan text

- **The plan's sample YAML omitted `runIn: FullOS`.** Added it on every instance.
  The samples' State Restore groups are gated by a `condition` rather than by a
  group `runIn`, so without the line the flattened step carries no phase and the
  assertion that it runs in the full OS would have been vacuous.
- **`docs/command-categories.psd1` and the regenerated reference were done in
  Task 1**, not Task 2 as the plan schedules them. The two new exports turned
  `CommandReference.Contract.Tests.ps1` red the moment they were added, and
  committing Task 1 over a red contract is worse than moving two lines forward.
- **`Get-HDTStepPropertyChoice` carries `categories` only.** The plan listed
  `exclude` as free text and it stayed free text; nothing else about that row was
  changed.

## Blocked

**Task 3, the E2E, was not started. Its pre-flight check 4 failed.**

The plan makes this an explicit stop: "If it does not resolve: **stop and report
it.** Do not substitute an address into the sequence and do not invent a
hosts-file entry on the target — either would make the E2E prove something other
than what a real deployment does, and the address is a lease this repository does
not write down."

What was checked, this session:

| Check | Result |
|---|---|
| 1. Both approved updates `Ready` | **PASS.** Exactly 2 approved on `HDT-WSUS-01`; KB5121003 (26100.9168) `Ready`, KB5120710 `Ready` |
| 2. Memory budget | **PASS.** `HDT-WSUS-01` and `HDT-WDS-01` both unstamped, so both are ignored by the budget |
| 3. Host address on `HDT External` | **PASS.** Present, /24, `Manual` — read, not written down |
| 4. `HDT-WSUS-01` resolves by name | **FAIL.** `Resolve-DnsName -Type A` → "DNS name does not exist"; `Test-Connection` → "No such host is known" |

The server itself is healthy and on the right subnet — Hyper-V reports its guest
address on `192.168.1.0/24`, on the `HDT External` switch. It is a **workgroup**
machine, and the real LAN's DNS carries no registration for it. The sequence
points the client at `http://HDT-WSUS-01:8530` deliberately, so that no second
lease is written into a file; a name that does not resolve makes `SetServer`
write a policy pointing at nothing, the search return nothing applicable, and the
step report exactly what a working step reports on a fully-patched machine — a
45-minute run that proves nothing and looks like a pass.

**This needs a decision that is not mine to make**, because every way out is a
change to the user's lab or to the plan's own rule:

1. Give `HDT-WSUS-01` a DNS record on the LAN's DNS, so the name resolves the way
   a real deployment's would. This is the option that keeps the E2E honest.
2. Accept an address in `tests/e2e/payload/UPD-WSUS/sequence.yaml`, against the
   plan's explicit instruction and against the lease rule.
3. Defer the E2E to a follow-up plan and land the authoring work as it stands.

Nothing was improvised, no VM was created, started, stopped or removed, and no
sequence had an address written into it.

## Verification

- **`./build.ps1 ci` GREEN under Windows PowerShell 5.1**, 2026-09-06T00:10Z:
  `test: 14389 passed, 0 failed, 298 skipped`; `lint: 0 diagnostics across 1175
  file(s)` in its own process; `selfcheck: 4 of 4 checks passed`;
  `BUILD SUCCEEDED (clean, version, bundle, build, lint, test, selfcheck) on
  PowerShell 5.1.26100.8655`.
- **The module was run, not just faked.** `Get-HDTStepType -Name WindowsUpdate`
  off a real import reports `CanAdd : True`, and
  `Get-HDTWindowsUpdateStepTemplate` emits the seven lines.
- **The console was opened and photographed**, offscreen with an STA probe and
  `RenderTargetBitmap` — nothing was shown on the user's desktop. The Add menu's
  General shelf reads: `... Install Applications, Join Domain, Tattoo, Windows
  Update, Gather`, with `Apply Windows Updates` still separate on Images. The
  Properties sheet draws all four rows with the classifications drop-down
  carrying the closed set.
- **The lab is as it was found.** `HDT-WSUS-01` Running / 8 GB / `Notes` empty,
  `HDT-WDS-01` Running / 4 GB / `Notes` empty. No VM created, started, stopped or
  removed.

## Test counts, read from real output

| Run | Result |
|---|---|
| Baseline before any work | `StepContract` 275 passed / **1 failed** — 08-01-03 shipped the step file without adding it to `$HDTExpectedStepType` |
| Task 1 RED | surface file **6 passed / 27 failed** |
| Task 1 GREEN | surface file **33 / 0**; seven neighbouring set-walking suites **365 / 0 / 48 skipped** |
| Task 2 RED | surface file 56 discovered, **17 failed** |
| Task 2 GREEN | surface file + expansion contract **95 / 0**; shipped-document contracts **50 / 0 / 13 skipped** |
| Full gate | **14389 passed / 0 failed / 298 skipped**, lint 0/1175, selfcheck 4/4 |

## Self-Check: PASSED

All created files present on disk; both commits present in `git log`.
