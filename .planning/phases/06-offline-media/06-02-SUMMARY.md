---
phase: 06-offline-media
plan: 02
subsystem: variables, payload
tags: [media, variables, provenance, payload, connect-loop, tattoo]
requires:
  - Get-HDTDeploymentMethod (06-01)
  - HDTDeploymentMethod marked not writable in Get-HDTVariableMap (06-01)
provides:
  - "Engine, the eighth provenance source"
  - "Resolve-HDTVariable -EngineVariable, applied before all five precedence sources"
  - "HDTDeploymentMethod in $resolved, $variable and $result on every run"
  - "the MEDIA connect gate: one attempt, no sleep, no Welcome screen"
  - "HDTContentUnreachable, the payload's media failure"
affects:
  - src/Hephaestus/Private/Add-HDTResolvedVariable.ps1
  - src/Hephaestus/Public/Resolve-HDTVariable.ps1
  - src/Hephaestus/Payload/Start-HDTDeployment.ps1
  - src/Hephaestus/Public/Steps/Invoke-HDTTattooStep.ps1
tech-stack:
  added: []
  patterns:
    - "a source outside the precedence ladder, applied first, ranked against nothing"
    - "the payload publishes through the hashtable the wizard's second pass reuses"
    - "the connect loop lifted out by AST and executed in both directions"
key-files:
  created:
    - tests/unit/DeploymentMethodPublication.Tests.ps1
    - tests/unit/MediaConnectLoop.Tests.ps1
  modified:
    - src/Hephaestus/Private/Add-HDTResolvedVariable.ps1
    - src/Hephaestus/Public/Resolve-HDTVariable.ps1
    - src/Hephaestus/Payload/Start-HDTDeployment.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTTattooStep.ps1
    - src/Hephaestus/Hephaestus.psd1
    - docs/command-reference.html
    - tests/unit/Add-HDTResolvedVariable.Tests.ps1
    - tests/unit/Resolve-HDTVariable.Tests.ps1
    - tests/unit/Write-HDTVariableLog.Tests.ps1
    - tests/unit/Invoke-HDTTattooStep.Tests.ps1
    - tests/unit/WelcomeRetryCredential.Tests.ps1
decisions:
  - "Engine is an eighth provenance source, not a GatheredFact - Invoke-HDTGatherStep would report a fact Get-HDTMachineFact cannot produce as 'could not be determined' on every Gather step"
  - "the publication door is Resolve-HDTVariable -EngineVariable, because Add-HDTResolvedVariable is private and a payload script only sees FunctionsToExport"
  - "it goes IN $resolveArgument, so the wizard's second resolution keeps it"
  - "HDTContentUnreachable is a payload prefix and is deliberately NOT in Get-HDTFailureClass's configuration list"
  - "Get-HDTWizardSummary is not a surface - it enumerates wizard pages and answers, never engine variables"
metrics:
  tasks: 3
  commits: 4
  gate: "13487 passed, 0 failed, 268 skipped; lint 0 diagnostics across 1112 files; selfcheck 4 of 4"
  completed: 2026-09-02
---

# Phase 06 Plan 02: HDTDeploymentMethod is published, and a disc stops being asked for a share Summary

The method is derived once from `bootstrap.Provider` where
`Resolve-HDTDeployRoot` is already handed it, logged at Info with the provider
it came from, and published into the three bags that need it at three different
times. Behind that, the deploy-root retry ladder and the Welcome screen no
longer run for a machine that booted from media.

## What was confirmed before anything was written

The plan asked for this to be read and recorded, and it was:

- **`Resolve-HDTDeployRoot.ps1` lines 135-186 already do the marker-not-found
  half.** The `Local` branch scans the candidate volumes once, with no ladder
  and no sleep, and when nothing carries the marker it throws a message naming
  the volumes in order beside the deployRoot and the marker. It was not touched
  and has a zero-line diff.
- **`Start-HDTDeployment.ps1` calls it outside any `try`**, so that error
  reaches the outer fatal handler rather than becoming a question, and the line
  above it already logs the volumes considered.

So the remaining gap was the narrower one: the marker is FOUND,
`Resolve-HDTDeployRoot` returns a local path, and `Connect()` still fails on it.
That is the case this plan changes.

## Task 1 — `Engine`, and the door the payload can actually reach

`HDTDeploymentMethod` is none of the seven sources that existed: it is not
gathered off the machine, it comes from the boot image the machine booted. It is
now an eighth, `Engine`, written **first** in the `ValidateSet` because it is
written first — the set stays closed and still refuses a name outside it, and
the `_HDT*` refusal still applies to it.

**The publication is a parameter on `Resolve-HDTVariable`, not a call to
`Add-HDTResolvedVariable`.** That helper is private, absent from
`FunctionsToExport`, and its `-Scope` parameter is mandatory over an internal the
result object does not return — a payload line naming it parses, lints, passes
every AST test here and fails only on iron. So `-EngineVariable` takes a
dictionary and applies it through the same single writer **before precedence 1**.

That ordering is the other half of 06-01's refusal. `Assert-HDTRuleDocument`
turns away a `rules.yaml` that declares the name, but the command line, a machine
override and a wizard page never pass through that validator. First-writer-wins
closes all three, and there is a test for each.

**A defect fixed in passing, as the plan predicted:** `Resolve-HDTVariable`'s
`.OUTPUTS` said the source set was six names when it was seven — `Wizard` was
added to the `ValidateSet` and never to that sentence. It now lists all eight.

**Surfaces reached.** Grepping every existing source name found only two lists:
the `ValidateSet` plus its help, and that `.OUTPUTS` sentence. There is no schema
enum, sort order or console colour map keyed on the source name.
`ConvertTo-HDTVariableText` renders the value, not the source, and
`Write-HDTVariableLog` composes `NAME = 'value' (Source)` generically — which is
asserted now rather than assumed. **`docs/command-reference.html` WAS a surface**
and was missed at first: it lists parameters, so it was regenerated with
`tools/New-HDTCommandReference.ps1` rather than hand-edited.

## Task 2 — the payload publishes it, and the Tattoo step stamps it

One derivation, at the top of section 7, immediately before the
`Resolve-HDTDeployRoot` call that is handed the same `bootstrap.Provider`. Three
publications:

| Bag | Where | Why there |
|---|---|---|
| `$result['deploymentMethod']` | section 7 | reaches `RESULT.json` beside the deploy root it was decided with |
| `$resolveArgument['EngineVariable']` | before `Resolve-HDTVariable` | provenance row saying `Engine`; **in the hashtable**, because `Start-HDTWizardDeployment` re-runs the resolver with that same hashtable and its result is the bag the engine deploys with |
| `$variable['HDTDeploymentMethod']` | beside `HDTDeploymentStart` | `Invoke-HDTTaskSequence` checkpoints `$variable` into `state.json` and `Start-HDTResume.ps1` puts it back, so the full-OS leg gets it without re-deriving from a drive letter that has moved |

Logged at **Info** (`& $say` with no level), naming the method and the provider
it came from, asserted by counting the call's `CommandElements`.

The ordering assertions are AST-based, the way `EarlyLogDestination.Tests.ps1`
does it: the derivation comes before the connect loop and before
`Get-HDTLogDestination`, and `Get-HDTDeploymentMethod` is called exactly once.

**The set-driven one** was written more narrowly than the plan sketched, and
deliberately. "No string constant `'Local'` or `'MEDIA'` in any comparison" is
not compatible with task 3, whose gate is `$deploymentMethod -eq 'MEDIA'`. It is
now two assertions that say what was actually meant:

- **no comparison anywhere in the payload has `'Local'` on either side** — that
  is what deciding the method from the provider a second time looks like;
- **every comparison against `'MEDIA'` has `$deploymentMethod` on the other
  side** — gating on the one derived answer is the design; deriving it again
  wearing the answer's clothes is not.

`Provider -eq 'Smb'` in section 8 is left alone and the comment says why: a
credential is an SMB concept, and asking for one is not a method decision.

**The Tattoo step** stamps `DeploymentMethod` beside `DeploymentType`. `$valueOf`
already returned `''` for an absent name — confirmed by reading it, and there is
now a test that removes the variable and asserts a blank field rather than an
exception on the last step of a deployment. The fixture's "real resolved set"
gained `HDTDeploymentMethod`, because the payload publishes it on every run and a
fixture without it would have made the empty-value warning fire in every test in
that file.

That file also carries a set-driven contract — *every value it stamps has a
publisher that runs on an ordinary deployment* — which reads the step's own
source and greps all of `src/Hephaestus` for a bag assignment. The new field
satisfies it through `$variable['HDTDeploymentMethod']` in the payload.

**`Get-HDTWizardSummary` turned out NOT to be a surface.** It builds rows from
`-Page` (wizard page declarations) and `-Value` (what the technician typed) and
has no enumeration of engine variables to join, so an engine fact in a list of
"what the technician chose" would have been wrong rather than incomplete. Read,
then decided — nothing was added to it.

## Task 3 — under MEDIA the deployment starts straight away

Two gates on the local `$deploymentMethod`, and nothing else in the loop moved.

1. **`$attemptCount = 1` under MEDIA.** The five exist for a network that has
   just come up — a switch still learning, a lease seconds old, a server with no
   session for a client that has only just appeared — and none of those can
   happen to a volume this machine is already standing on. `$ConnectAttempt`
   keeps its default and its meaning; the `for` header and its message read
   `$attemptCount`.
2. **The Welcome screen is refused under MEDIA**, with a message naming the
   path, the method, the ready volumes considered and the underlying error —
   said to the log at `Warning` *before* the throw, because a run nobody is
   watching never sees the failure screen.

**The error prefix is `HDTContentUnreachable`, and it is registered nowhere
else — on purpose.** The prefixes the payload already throws are
`HDTDeploymentCancelled` (which its own catch special-cases into a Cancelled
status, because a technician who pressed a button did not suffer a failure) and
`HDTConfigurationError`. The only *list* of prefixes in the module is
`Get-HDTFailureClass`'s `$configurationErrorId`, and that classifies **step**
failures so a refusal is not retried three times; it reads a step result's
`errorId` or an `ErrorRecord`'s `FullyQualifiedErrorId`, neither of which a
payload `throw` of a plain string produces. Content that will not open is an
environment fact rather than bad authoring, so adding it there would have been
wrong twice over. It lands as `FATAL` / status `Failed`, which is correct.

The test file lifts the payload's own `while` loop out by AST and executes it
against hand-written fakes, **in both directions**. The five UNC assertions are
the ones that matter most — a change that quietly disables the SMB path passes a
test written only for the disc — and they cover the five attempts, the 2/4/6/8
backoff (and the absence of a fifth sleep), the Welcome screen, the retyped
share, the retyped account, and the cancel when nobody answers.

`Start-Sleep` is **mocked, never redefined**: `Naming.Contract.Tests.ps1`
enumerates every function defined under `tests/` and requires `Verb-HDTNoun`, so
a `function Start-Sleep` there would fail the gate. It is also the adapter
boundary `Mock` is reserved for. The file never actually sleeps.

Both of `WelcomeRetryCredential.Tests.ps1`'s hard-won traps were carried across
with their reasons — building the `Connect` closure into a variable before
`Add-Member`, and not naming the stub `$provider`.

## Deviations from Plan

**1. [Rule 1 — Bug] The plan's set-driven assertion would have contradicted its
own task 3.**
- **Found during:** Task 3
- **Issue:** Task 2 specified "walk the payload AST for any string constant
  `'Local'` or `'MEDIA'` in a comparison and assert there is none". Task 3's own
  implementation is `if ($deploymentMethod -eq 'MEDIA')`. Written as specified,
  task 2's test passes vacuously and then task 3 turns it red.
- **Fix:** split into two assertions that state the actual intent — no `'Local'`
  comparison anywhere, and every `'MEDIA'` comparison against `$deploymentMethod`
  and nothing else. Strictly stronger: it now also forbids a `'MEDIA'` gate on
  some *other* variable, which the original wording allowed.
- **Files modified:** `tests/unit/DeploymentMethodPublication.Tests.ps1`
- **Commit:** `0359ac4`

**2. [Rule 3 — Blocking] The precedence test could not be written from real
YAML.**
- **Found during:** Task 1
- **Issue:** `It 'BEATS a rule that sets the same name'` builds its document
  through the real `Import-HDTRuleDocument`, and 06-01's `Assert-HDTRuleDocument`
  now refuses a `rules.yaml` declaring `HDTDeploymentMethod` at all — so the test
  failed in the importer, before the resolver was ever called.
- **Fix:** that one test assembles the rule document in memory, with a comment
  saying why: the refusal and the ordering are two different guarantees, and the
  value a deployment gates on must not depend on which door a document came
  through. The neighbouring `when:`/`%Var%` test still uses real YAML, because
  *gating* on the name is allowed and is the point of publishing it.
- **Files modified:** `tests/unit/Resolve-HDTVariable.Tests.ps1`
- **Commit:** `cea2310`

**3. [Rule 2 — Missing surface] `docs/command-reference.html` lists parameters.**
- **Found during:** Task 1
- **Issue:** the plan named three surfaces to check for a source list. The
  command reference is a fourth: it renders `.PARAMETER` help, so a new parameter
  on an exported command is missing from it until it is regenerated.
- **Fix:** regenerated with `tools/New-HDTCommandReference.ps1`, never hand-edited.
- **Commit:** `cea2310`

**4. [Rule 3 - Blocking] `WelcomeRetryCredential.Tests.ps1` could not keep a
zero-line diff, and the gate is what said so.**
- **Found during:** final verification
- **Issue:** the plan requires that file green *and unmodified*. It was, in a
  direct `Invoke-Pester` run - and the gate failed six of its tests. That file
  executes the payload's connect loop by lifting its source out with the AST and
  running it against a caller scope it builds **by hand**: `$ConnectAttempt`,
  `$bootstrap`, `$candidateRoot`, `$deployRoot`, `$providerArgument`, `$say`,
  `$showWelcome`. The loop gained one more input, `$deploymentMethod`. Under
  `Set-StrictMode -Version Latest` - which `build.ps1` runs and a direct
  `Invoke-Pester` does not - reading an undeclared variable is a terminating
  error, where a direct run leaves it `$null` and compares false into the UNC
  branch. Reproduced deliberately with `powershell.exe -Command "Set-StrictMode
  -Version Latest; Invoke-Pester ..."`: 13 passed, 6 failed.
- **Fix:** one line, `$deploymentMethod = 'UNC'`, added to that probe's
  hand-built scope with a comment explaining both halves. This is the harness
  keeping up with the fragment's inputs - the same category as the eight
  variables already declared beside it - and not a change to what the file
  asserts: UNC is its entire subject, and the disc's half lives in
  `MediaConnectLoop.Tests.ps1`, which runs the same lifted loop under both
  methods. **The plan's intent - "if you had to edit it, the change is in the
  wrong place" - was aimed at the SMB behaviour, and that behaviour is
  untouched: all six tests assert the same things and pass.**
- **Files modified:** `tests/unit/WelcomeRetryCredential.Tests.ps1`
- **Commit:** see `fix(06-02): the hand-built scope has to declare what the lifted loop reads`

**5. [Housekeeping] `Hephaestus.psd1` moved 0.15.0 → 0.16.0.** The manifest
carries `SourceHash`/`LayoutHash`, and the build's version task bumps the minor
when the source hash changes. It is a consequence of the edits, not a decision
taken here.

No architectural changes were needed, so nothing was escalated under Rule 4.

## The leave-alone assertions, checked

- **`Invoke-HDTTaskSequence.ps1:~999`** — the `$resolvedRoot.StartsWith('\\')`
  guard on the resume-agent carry — is **unmodified**, `git diff --stat` empty.
  Its test, `Invoke-HDTTaskSequence.ResumeAgent.Tests.ps1`
  `It 'leaves a local root alone, because a drive letter moves'`, was run and is
  **green**. It was not rewritten to use `HDTDeploymentMethod`.
- **`src/Hephaestus/Public/Resolve-HDTDeployRoot.ps1`** — unmodified, zero-line
  diff.
- **`tests/unit/WelcomeRetryCredential.Tests.ps1`** — green, but **not with a
  zero-line diff**: one variable declaration was added to its hand-built scope.
  See deviation 4, which is the one thing in this plan that did not come out as
  written.
- **`tests/unit/EarlyLogDestination.Tests.ps1`** and
  **`tests/unit/StartHDTDeploymentPayload.Tests.ps1`** — green, unedited.

## Verification

Every suite below was executed under Windows PowerShell 5.1
(`powershell.exe -NoProfile`) with `PSModulePath` unset. The pwsh 7 pass is
deliberately off.

| Run | Result |
|---|---|
| Task 1: the eight provenance/resolver suites | 218 passed, 0 failed |
| `tests/contract` (the sweep for a source list not found) | 3656 passed, 0 failed, 255 skipped |
| Task 2: publication, tattoo, EarlyLogDestination, StartHDTDeploymentPayload | 164 passed, 0 failed |
| Task 3: media loop, welcome retry, deploy root, payload, publication, resume agent | 184 passed, 0 failed |
| `./build.ps1 ci`, first run | **6 failed** - deviation 4 |
| `./build.ps1 ci`, after the fix | **BUILD SUCCEEDED**: 13487 passed, 0 failed, 268 skipped |

The gate: `clean, version, bundle, build, lint, test, selfcheck` on
PowerShell 5.1.26100.8655. Lint 0 diagnostics across 1112 files. All four
selfchecks passed, so the run that reported green was capable of reporting red.
Version 0.16.1.

Each unit was red first and for the right reason, checked by reading the output:
`ValidationMetadataException` on the `Engine` source, "a parameter cannot be
found that matches parameter name 'EngineVariable'", the eight AST assertions
finding nothing, and the ten MEDIA assertions failing while the seven UNC ones
already passed — which is what proves the harness runs the real loop rather than
a copy of it. The one test that could only go red against pre-change code
(`prints an engine-published variable as ... (Engine)`) was verified by reverting
both source files, running it, and restoring them.

No VMs, no Hyper-V, no real media. Everything ran against hand-written fakes.
