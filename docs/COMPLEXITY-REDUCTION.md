# Reducing engine and console complexity

Date: 2026-09-14

Status: proposed maintenance work; no implementation changes are included.

## Purpose

Make the deployment engine and console easier to understand, review, and change while preserving their current behavior. Extract cohesive responsibilities from large functions and move lengthy historical explanations into documentation. Preserve the operational safeguards those explanations describe.

This expanded proposal combines a repository-wide structural scan with code review by three subagents covering UI, deployment, and supporting code, plus a review of smaller editing helpers. The original six-file sample was insufficient: startup payloads, step handlers, validation, and development infrastructure also deserve attention. This is a maintenance review, not a claim that every file has received a line-by-line correctness audit.

## Scope and measurements

[complexity-inventory.csv](complexity-inventory.csv) records every `.ps1`, `.psm1`, and `.psd1` file found recursively under `src`, `tests`, `tools`, and `samples`, plus `build.ps1`. The generated `Hephaestus.bundle.ps1` is excluded because it duplicates source. Build output, Git metadata, secrets, and planning directories are excluded. XAML, YAML, JSON schemas, and workflows are contextual inputs rather than PowerShell metric rows.

The inventory contains **1,297 files**: 628 product files, 661 test/helper/fixture files, four tools, three samples, and the build script. Within product code, **33 files exceed 500 parser-reported lines and 11 exceed 1,000**. The CSV includes all smaller files as well.

Measurements were collected with PowerShell 7.5.8's `System.Management.Automation.Language.Parser.ParseFile`, without importing or executing the product:

- `Lines`: the parsed file extent's ending line, including comments and blank lines; a trailing newline can add one to this number.
- `Bytes`: file length on disk.
- `CommentTokenLines`: sum of the line spans of comment tokens, including command help. This is not a count of removable comments; inline comments can overlap code lines.
- `ControlFlowNodes`: recursive count of `IfStatementAst`, `SwitchStatementAst`, `LoopStatementAst`, and `CatchClauseAst`. This includes nested handlers and methods. It is a screening signal, not cyclomatic complexity or a count of independent execution paths.
- `ParseErrors`: errors reported by that parser. The three reported errors occur only in the deliberately invalid `AnalyzerBait.ps1` and `Unparseable.ps1` fixtures. This scan does not establish Windows PowerShell 5.1 compatibility.

File size identifies review candidates; it does not establish a defect or justify splitting a function by itself. The CSV is a dated snapshot, not a CI gate or a proposed size limit.

## Current observations

The original six examples remain relevant, but are only part of the inventory. Sizes are approximate decimal kilobytes, including comments, at the time of review.

| File | Size | Suggested review focus |
|---|---:|---|
| [New-HDTConsoleView.ps1](../src/Hephaestus/Private/New-HDTConsoleView.ps1) | 153 KB | Window construction, event wiring, background grid results, monitoring, and command actions |
| [Update-HDTBootImage.ps1](../src/Hephaestus/Public/Update-HDTBootImage.ps1) | 107 KB | Inspect build phases and resource ownership before choosing extraction boundaries |
| [Invoke-HDTTaskSequence.ps1](../src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1) | 98 KB | Step decisions, checkpointing, reboot handling, and terminal cleanup |
| [New-HDTConsoleEditorView.ps1](../src/Hephaestus/Private/New-HDTConsoleEditorView.ps1) | 97 KB | Inspect editor responsibilities and event-handler boundaries |
| [New-HDTConsoleHost.ps1](../src/Hephaestus/Public/New-HDTConsoleHost.ps1) | 95 KB | Inspect host responsibilities and shared state |
| [New-HDTConsoleBootImageView.ps1](../src/Hephaestus/Private/New-HDTConsoleBootImageView.ps1) | 81 KB | Inspect form construction and edit handling |

The engine already uses injected services, and the console already delegates some work to helpers such as `New-HDTConsoleGridReader`. Extend those established patterns where they make dependencies clearer.

Two concrete examples explain the maintenance concern:

- `Invoke-HDTTaskSequence` contains the main execution flow alongside substantial explanations of reboot ordering, interrupted steps, and teardown. A reviewer must distinguish essential ordering constraints from historical narrative across a large function.
- `New-HDTConsoleView` constructs controls and attaches timer and click handlers. Its comments describe a previous closure-capture bug involving controls captured before initialization. Extracting handlers carelessly could recreate that failure.

## Expanded refactoring backlog

Priorities indicate suggested maintenance order, not defect severity. **P1** means a concrete extraction or documentation correction with clear boundaries; **P2** means valuable work requiring broader lifecycle or behavioral characterization; **P3** means documentation cleanup or further investigation before structural changes. Files grouped in one row share a concern, not necessarily an implementation.

### UI and presentation

| Priority | Files | Concrete opportunity and constraint |
|---|---|---|
| P1 | [New-HDTConsoleView](../src/Hephaestus/Private/New-HDTConsoleView.ps1) | Separate grid completion, monitoring refresh, and category actions from window composition. The file contains 227 control-flow nodes. Preserve dispatcher access, closure capture order, and disposal. |
| P1 | [New-HDTConsoleHost](../src/Hephaestus/Public/New-HDTConsoleHost.ps1) | Extract dialog validation decisions and build-result presentation from WPF plumbing. Repeated validation closures and build runspace handling contradict its claim to be branch-free. |
| P1 | [New-HDTConsoleEditorView](../src/Hephaestus/Private/New-HDTConsoleEditorView.ps1), [Get-HDTConsoleEditorState](../src/Hephaestus/Private/Get-HDTConsoleEditorState.ps1) | Separate edit actions and selection refresh from view setup. Retain reparsing through the engine after edits; avoid a second document model. Correct the claim that every handler is one call and one assignment. |
| P1 | [Get-HDTConsoleShareNode](../src/Hephaestus/Private/Get-HDTConsoleShareNode.ps1) | Split category-specific tree projections into coherent builders. Keep node identity, ordering, and available actions stable. This 52 KB file was missing from the initial list. |
| P1 | [Get-HDTConsoleWorkspace](../src/Hephaestus/Private/Get-HDTConsoleWorkspace.ps1) | Separate catalog loading, error projection, and validation reporting. Preserve partial visibility when one document fails to load. |
| P1 | [Get-HDTConsoleBootImageSetting](../src/Hephaestus/Private/Get-HDTConsoleBootImageSetting.ps1), [New-HDTConsoleBootImageView](../src/Hephaestus/Private/New-HDTConsoleBootImageView.ps1) | Separate independent pane models and their edit handling. Keep saving settings distinct from starting an image build. |
| P2 | [New-HDTWizardHost](../src/Hephaestus/Public/New-HDTWizardHost.ps1), [Show-HDTWizardShell](../src/Hephaestus/Public/Show-HDTWizardShell.ps1) | Separate page loading, navigation, validation registration, and localization. Preserve answer harvesting, page-skip semantics, and compatibility with WinPE. |
| P2 | [Get-HDTConsoleDetectionForm](../src/Hephaestus/Private/Get-HDTConsoleDetectionForm.ps1), [Get-HDTConsoleDetectionText](../src/Hephaestus/Private/Get-HDTConsoleDetectionText.ps1), [Get-HDTConsoleDetectRuleText](../src/Hephaestus/Private/Get-HDTConsoleDetectRuleText.ps1) | Smaller helpers repeat dictionary/PSObject normalization and detection presentation mappings. Consider one normalized reader; preserve camelCase, optional-key omission, string conversions, and unknown-type behavior. |
| P3 | [Get-HDTConsolePartitionRow](../src/Hephaestus/Private/Get-HDTConsolePartitionRow.ps1) | Review authored-size-to-control conversion separately from layout defaults. Preserve explicit `bootable: false`, remainder/percentage semantics, and unsupported authored units. |

### Deployment lifecycle and steps

| Priority | Files | Concrete opportunity and constraint |
|---|---|---|
| P2 | [Start-HDTDeployment](../src/Hephaestus/Payload/Start-HDTDeployment.ps1) | The approximately 156 KB startup script was entirely missed by the Public/Private-only size sample. Separate connection/retry decisions, rule/wizard/context preparation, and terminal reporting. Do not move pre-import bootstrap code into helpers that require the module to be loaded. |
| P2 | [Start-HDTResume](../src/Hephaestus/Payload/Start-HDTResume.ps1) | Isolate share reconnection, rule reconstruction, progress setup, and finish handling. Share leaf operations with startup only where phase and failure behavior agree. |
| P2 | [Invoke-HDTTaskSequence](../src/Hephaestus/Public/Invoke-HDTTaskSequence.ps1) | Extract bounded lifecycle operations while keeping the loop's order visible. Resume-agent staging, autologon, log relocation, durable checkpoints, and teardown are interdependent; do not treat them as interchangeable callbacks. |
| P1 | [Invoke-HDTApplyDriversStep](../src/Hephaestus/Public/Steps/Invoke-HDTApplyDriversStep.ps1) | Extract inventory formatting and report construction before altering staging or installation. Keep the staging closure's dependencies explicit and preserve disabled-driver filtering. |
| P1 | [Invoke-HDTInstallApplicationsStep](../src/Hephaestus/Public/Steps/Invoke-HDTInstallApplicationsStep.ps1) | Extract selection/provenance presentation, command redaction, detection reporting, and checkpoint serialization. Keep per-leg counters separate from persisted progress and preserve reboot re-entry. |
| P2 | [Invoke-HDTValidateStep](../src/Hephaestus/Public/Steps/Invoke-HDTValidateStep.ps1) | Separate hardware, target-disk, Refresh compatibility, partition, and space checks into policy evaluators returning result rows. Retain all target and downgrade guards. |
| P1 | [Invoke-HDTApplyUpdatesStep](../src/Hephaestus/Public/Steps/Invoke-HDTApplyUpdatesStep.ps1) | Separate update-plan checks, report rendering, and DISM output formatting. Complete the whole plan's preflight before the first update is applied. |
| P2 | [Invoke-HDTWindowsUpdateStep](../src/Hephaestus/Public/Steps/Invoke-HDTWindowsUpdateStep.ps1) | Extract option/source resolution and persisted progress serialization from the bounded install/reboot loop. Preserve limits and resume state. |
| P1 | [Invoke-HDTApplyUnattendStep](../src/Hephaestus/Public/Steps/Invoke-HDTApplyUnattendStep.ps1) | Separate XML/template transformation from staging and applying the answer file. Cover escaping, missing values, recursive variable expansion, and literal percent semantics. |
| P1 | [Invoke-HDTGatherStep](../src/Hephaestus/Public/Steps/Invoke-HDTGatherStep.ps1) | Separate fact merge decisions from provenance and change-log rendering. Compare actual values before redacting their display. |
| P2 | [Invoke-HDTBootToWinPEStep](../src/Hephaestus/Public/Steps/Invoke-HDTBootToWinPEStep.ps1), [Invoke-HDTSysprepStep](../src/Hephaestus/Public/Steps/Invoke-HDTSysprepStep.ps1) | Name preflight, staging, boot/resume preparation, invocation, and cleanup operations. Keep their side-effect order explicit and test failure between phases. |
| P2 | [Invoke-HDTEnableBitLockerStep](../src/Hephaestus/Public/Steps/Invoke-HDTEnableBitLockerStep.ps1) | Extract option interpretation and polling/result presentation first. Preserve recovery-key escrow and protector ordering. |

### Services, configuration, and smaller helpers

| Priority | Files | Concrete opportunity and constraint |
|---|---|---|
| P2 | [Update-HDTBootImage](../src/Hephaestus/Public/Update-HDTBootImage.ps1) | Separate option/certificate preflight, servicing, driver injection, engine/UI staging, bootstrap generation, customization, and publication. Preserve one visible owner for mount cleanup and failure recovery. |
| P1 | [New-HDTImageService](../src/Hephaestus/Public/New-HDTImageService.ps1) | ApplyImage, CaptureImage, and AddPackage repeat DISM streaming plumbing. Consider a shared process/stream transport with operation-specific arguments and outcomes. ApplyUnattend deliberately uses polling; it cannot be merged blindly. |
| P1 | [Assert-HDTWorkspaceDocument](../src/Hephaestus/Private/Assert-HDTWorkspaceDocument.ps1) | Extract nested boot-image block validators from the root validator. At 95 control-flow nodes, this is a stronger candidate than byte size alone suggests. Preserve strict unknown-key rejection and error locations. |
| P2 | [Assert-HDTMediaDocument](../src/Hephaestus/Private/Assert-HDTMediaDocument.ps1), [Assert-HDTOperatingSystemDocument](../src/Hephaestus/Private/Assert-HDTOperatingSystemDocument.ps1), and other `Assert-*Document` validators | Repeated mapping, unknown-key, and schema-version scaffolding suggests shared primitives. Keep domain rules readable. Some schema contracts inspect AST variable assignments; preserve schema/engine parity when changing that test seam. |
| P1 | [Set-HDTWorkspaceIndent](../src/Hephaestus/Private/Set-HDTWorkspaceIndent.ps1), [Set-HDTBlockIndent](../src/Hephaestus/Private/Set-HDTBlockIndent.ps1) | Both implement the same broad line-shifting operation. Extract only the shifting mechanism if worthwhile; workspace anchoring uses the first nonblank line, step anchoring uses a dash line, and their whitespace patterns differ. Preserve these distinctions. |
| P2 | [Set-HDTDocumentHeaderKey](../src/Hephaestus/Private/Set-HDTDocumentHeaderKey.ps1), [Set-HDTApplicationLine](../src/Hephaestus/Private/Set-HDTApplicationLine.ps1), [Set-HDTRuleKey](../src/Hephaestus/Private/Set-HDTRuleKey.ps1), [Set-HDTWorkspaceKey](../src/Hephaestus/Private/Set-HDTWorkspaceKey.ps1) | Related splice mechanics deserve comparison, but are not identical. Blank-line boundaries, nested containers, ordering, and folded scalars differ. Characterize those cases before sharing a primitive; do not replace comment-preserving editing with serialization. |
| P3 | [ConvertTo-HDTReport](../src/Hephaestus/Public/ConvertTo-HDTReport.ps1), [Get-HDTMachineFact](../src/Hephaestus/Public/Get-HDTMachineFact.ps1), [New-HDTSmbContentProvider](../src/Hephaestus/Public/New-HDTSmbContentProvider.ps1) | Secondary structural candidates: respectively 64, 44, and 41 control-flow nodes. Inspect output-format boundaries, fact normalization, and connection/path responsibilities before committing to new abstractions. The metrics alone do not prove a needed refactor. |
| P3 | [Update-HDTMediaContent](../src/Hephaestus/Public/Update-HDTMediaContent.ps1) | Already delegates projection and workspace rewriting. Clarify assembly stages and shorten history before extracting more helpers. Preserve owned scratch cleanup and ISO-before-manifest publication. |

### Build and test infrastructure

| Priority | Files | Concrete opportunity and constraint |
|---|---|---|
| P1 | [build.ps1](../build.ps1) | Lint and test paths repeat shard launch/wait/cleanup orchestration. Share worker lifecycle management while preserving their different payloads, reports, and failure aggregation. Keep one build entry point. |
| P2 | [HDTFakes.psm1](../tests/helpers/HDTFakes/HDTFakes.psm1) | The inventory identifies 7,369 parser-reported lines and 384 control-flow nodes. Review splitting implementations by service behind the same test-module interface. Do not sacrifice ordered operation journals or fidelity to production services. This is a structural candidate, not a verified defect. |
| P2 | [WorkspaceSchema.Contract.Tests.ps1](../tests/contract/WorkspaceSchema.Contract.Tests.ps1) | Validator refactoring can break contracts that inspect local metadata assignments. Make the intended metadata boundary explicit; retain schema/engine agreement rather than simply removing assertions. |
| P3 | [Refresh.E2E.Tests.ps1](../tests/e2e/Refresh.E2E.Tests.ps1), [ApplicationRoundTrip.E2E.Tests.ps1](../tests/e2e/ApplicationRoundTrip.E2E.Tests.ps1), [UnattendedDeployment.E2E.Tests.ps1](../tests/e2e/UnattendedDeployment.E2E.Tests.ps1) | Large scenario suites merit a later fixture/lifecycle review. Length alone does not justify hiding scenario assertions in helpers; preserve lab target guards and failure evidence. |

## Confirmed documentation drift

- `New-HDTConsoleHost` says it is deliberately branch-free and decides nothing, but contains validation closures and background build orchestration. Replace that description with its current responsibilities and extract testable decisions where useful.
- `Get-HDTConsoleEditorState` says every console handler is one call and one assignment. The current view handlers do substantially more. Document the actual boundary between state computation and UI orchestration.
- `Set-HDTDocumentHeaderKey` carries a lengthy CI incident explanation around newline normalization. Retain the input-shape invariant beside the expression and move the incident account into maintenance notes.
- Driver installation, application checkpointing, and resume UI comments include particular run counts, timings, run IDs, and earlier implementation locations. Preserve current guarantees and relevant regression tests; historical measurements should identify their context in documentation.
- README and CLAUDE.md disagree about supported validation shells. Resolve this explicitly before implementation rather than copying either statement into new helpers.

## What should remain cohesive

`Invoke-HDTCommandLineStep` and `Invoke-HDTPowerShellStep` already represent focused execution roles; shorten historical commentary before proposing splits. Tiny step-template factories do not need restructuring merely because there are many of them. `Set-HDTMediaWorkspaceLine` already delegates workspace editing to `Set-HDTWorkspaceKey`, which is the kind of reuse to preserve.

Similarly, an injected service with many thin methods may reasonably be larger than a policy helper. Do not merge production adapters and test fakes to remove apparent duplication: independent fakes help validate the contract.

`Get-HDTConsoleStepCatalog` is substantially declarative metadata: many rows do not imply mixed responsibilities. Desktop wizard/progress preview tools already delegate to product hosts and are low-priority comment-cleanup candidates.

## Proposed boundaries

### Console

Keep the view function responsible for composing the window and connecting its components. Consider extracting background-grid completion handling, monitoring refresh, and coherent groups of command actions in separate changes.

Pass required controls, services, and state explicitly. Avoid helpers that depend on incidental caller variables. Make ownership of timers, runspaces, event subscriptions, and disposal visible. Preserve the distinction between background work and WPF dispatcher updates.

Do not turn every click handler into a separate abstraction. Extract a responsibility when it has a clear input, outcome, and lifecycle, or when it removes substantial branching from window construction.

### Deployment engine

Keep the main loop readable as an ordered sequence of decisions. Candidate extractions include step eligibility decisions, checkpoint preparation, and terminal reporting. Prefer isolating decisions before moving operations that change machine state.

Keep reboot and teardown ordering explicit at the orchestration level. Extraction must preserve:

- The order of checks for completed, interrupted, disabled, phase-incompatible, and conditionally skipped steps.
- The distinction between a completed step and a step pending re-entry after reboot.
- Checkpoints before restart and the ordering of autologon operations.
- Cleanup from `finally` on terminal outcomes, including failures.
- The original failure when cleanup or log copying also fails.

Helpers should accept the existing context or narrowly scoped dependencies and return explicit results. Avoid hidden changes to caller scope. Do not add a second execution path or a new framework solely to shorten this file.

### Other large files

The expanded backlog identifies boot-image and editor boundaries, but helper names and signatures still require examining their callers and tests. Identify resource lifetimes and side effects before moving code. For boot-image work, any extraction must retain clear ownership of mounted images and cleanup after errors.

## Comment policy

Keep concise comments beside code when they explain a non-obvious invariant, a platform constraint, or why operation order matters. Retain public command help, parameter descriptions, and useful examples.

Move extended incident narratives, abandoned approaches, measurements, and repeated architectural explanations into focused documentation or the relevant section of [DESIGN.md](DESIGN.md). Link to that explanation from the code where useful. Preserve the reason for a safeguard before removing its original commentary.

For example, a long account of a timer crash could become:

```powershell
# Resolve controls before creating closures; GetNewClosure captures current values.
# Catch timer callback failures so they cannot escape through the dispatcher.
```

The associated documentation should explain the failure mechanism and point to the regression test. Git history can retain the chronology; current documentation should explain the behavior a maintainer must preserve.

## Delivery plan

1. Choose one cohesive console responsibility as the first change. Record its current inputs, side effects, failure behavior, and resource ownership.
2. Review existing behavioral tests. Add a failing regression test first where an important behavior lacks coverage, following repository test policy. Avoid tests that merely assert new helper names or source layout.
3. Extract that responsibility without changing public commands, configuration formats, user-visible behavior, or error handling.
4. Move historical commentary in a separate, easily reviewed change, leaving concise invariants at the relevant code.
5. Run relevant tests under Windows PowerShell 5.1, then the required repository checks. For UI changes, exercise the affected interactions, rapid selection changes, error paths, and window closure while background work is pending.
6. Proceed to engine extractions only after the smaller console change establishes a useful pattern. Verify interrupted execution, restart, step re-entry, checkpoint failure, and teardown failure behavior with the existing fake services and appropriate regression coverage.

Before implementation, consult the authoritative design and applicable repository instructions. Reconcile their shell-validation guidance: the current README specifies Windows PowerShell 5.1 as the supported gate, while CLAUDE.md still requests both shells.

Keep every extraction independently reviewable. Avoid combining this work with timeout changes, checkpoint-storage changes, or new product features.

### Suggested first changes

1. Correct the two inaccurate branch-free/handler descriptions and relocate one incident narrative, preserving concise invariants and links.
2. Extract a category projection from `Get-HDTConsoleShareNode`, or a detection normalization helper after characterizing dictionary/PSObject behavior. These have less lifecycle risk than moving reboot code.
3. Extract one console refresh responsibility with explicit state and disposal ownership. Use existing parse-cache, selection-occurrence, tree-expansion, row-commit, monitoring, and boot-image close/dirty tests where relevant.
4. Extract report/formatting logic from one step, then a nested workspace validator. Preserve schema contract coverage when moving metadata.
5. Address shared build-worker lifecycle and DISM transport separately. Use failure, missing-report, nonzero-exit, and callback/heartbeat cases, not only successful runs.
6. Refactor startup/resume and task-sequence lifecycle last, using existing Ordering, Reboot, Resume, ResumeAgent, FullOsStateMirror, LogRelocation, Teardown, and CaptureLeg test families.

## Validation of this review

This change adds documentation and a static inventory only. The review did not run deployments, import the module, or execute Pester. The inventory was parsed as CSV and documentation links checked locally. Existing README and ROADMAP working-tree changes were left untouched. Implementation validation remains part of each future refactoring change.

## Acceptance criteria

- A maintainer can identify the main execution or UI flow without reading unrelated implementation details.
- Extracted helpers have cohesive responsibilities and explicit dependencies.
- Resource ownership, closure initialization, reboot order, and cleanup remain visible and correct.
- Existing behavior and public interfaces are preserved, with relevant validation passing.
- Important rationale remains accessible through concise comments and linked documentation.
- No arbitrary file-size target drives unnecessary fragmentation.

Success means a routine change touches fewer unrelated concerns and is easier to verify. A lower line count alone is insufficient.
