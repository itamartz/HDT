---
phase: 06-offline-media
verified: 2026-09-02T21:21:19Z
status: gaps_found
score: 21/21 phase-goal truths verified; 0/2 milestone exit criteria met
re_verification: false
gaps:
  - truth: "M7 Exit-media: a USB stick built from the share deploys a machine with no network."
    status: failed
    reason: >-
      Not met, and not attempted. Phase 06 made the ENGINE ready for media by
      teaching it which method it is running under; it did not build the media.
      No ISO was built, no USB written, no VM booted from a disc. New-HDTMedia
      does not exist. This is a scope statement, not a regression - docs/ROADMAP.md
      states it plainly in the M7 section, so the phase did not overclaim.
    artifacts:
      - path: "src/Hephaestus/Public/New-HDTMedia.ps1"
        issue: "Does not exist. The content projection and the ISO/USB layouts are deferred to v2."
    missing:
      - "New-HDTMedia: content projection for a selected set of sequences"
      - "ISO and USB (FAT32 boot + NTFS content) layouts"
      - "Projection-completeness tests: every artifact a selected sequence references is included, and nothing else"
      - "Provider-swap equivalence: the same sequence produces the same operation list under Local as under Smb"
      - "A real boot-from-media run on a machine with no network"
  - truth: "The suite is green under pwsh 7 as well as Windows PowerShell 5.1."
    status: failed
    reason: >-
      pwsh 7.5.8 reports 13735 passed / 8 failed / 59 skipped. NONE of the 8 is
      phase 06's. All 8 reproduce identically at cd8396c, the commit BEFORE this
      phase's first commit, proven by running those files in a scratch worktree
      under pwsh 7. The project also gates on 5.1 only, deliberately, because
      that is the shell WinPE has. Pre-existing edition divergence, not a phase
      06 defect. Recorded because the verification brief asked for both shells.
    artifacts:
      - path: "tests/contract/StateSchema.Contract.Tests.ps1"
        issue: "6 failures. Test-Json under .NET 8 rejects the fixtures at /deploymentPassword (false schema); 5.1 Test-Json accepts them."
      - path: "tests/unit/Export-HDTDeviceInventory.Tests.ps1"
        issue: "1 failure. Expected exactly X but got X - a datetime vs string identity difference in Should -BeExactly under 7."
      - path: "tests/unit/ConsoleFieldEdit.Tests.ps1"
        issue: "1 failure. RaiseEvent throws Cannot validate argument on parameter Path in the rename handler under 7."
    missing:
      - "Either fix the three files for .NET 8 semantics, or record the 5.1-only gate in the files themselves so a pwsh 7 run is not read as a regression"
---

# Phase 06: Offline Media (HDTDeploymentMethod) Verification Report

**Phase Goal:** A deployment booted from media announces itself as
`HDTDeploymentMethod = MEDIA`, and the two behaviours that only make sense over
SMB stop firing under it - the deploy-root retry ladder with its Welcome screen,
and the log copy-back to the deploy root. Proven under Pester against fakes, with
the Smb path unchanged and still green.

**Milestone:** M7 - Capture and standalone media (`docs/ROADMAP.md`)
**Verified:** 2026-09-02T21:21:19Z
**Re-verification:** No - initial verification.

**Verdict in one line: the phase GOAL is met and proven by execution; the
MILESTONE Exit-media criterion is not met, was not attempted, and the ROADMAP
says so.**

---

## Headline numbers, run by the verifier and not taken from the summaries

| Check | Result |
|---|---|
| `build.ps1 test` under Windows PowerShell **5.1.26100.8655** | **13534 passed, 0 failed, 268 skipped** - BUILD SUCCEEDED |
| `build.ps1 lint` under 5.1 (separate process) | **0 diagnostics across 1113 files** - BUILD SUCCEEDED |
| `build.ps1 selfcheck` under 5.1 | **4 of 4 checks passed** - the harness can still detect a red |
| `build.ps1 test` under **pwsh 7.5.8** | 13735 passed, **8 failed**, 59 skipped - BUILD FAILED (all 8 pre-existing, see Gaps) |
| Working tree after verification | unchanged from how it was found |

The gate was launched from Bash with `unset PSModulePath`, and the analyzer ran
in its own process, per the two traps recorded in project memory. The selfcheck
matters and is why the green run is worth anything: it plants a deliberately
failing test and a bait fixture and confirms both are caught, so `0 failed` means
the suite ran rather than that it silently did nothing.

---

## Goal Achievement - Observable Truths

Derived from the `must_haves.truths` in all three PLAN frontmatters (21 truths),
each checked against the codebase and, where behavioural, against the running
module rather than the fakes alone.

### 06-01 - the variable exists and cannot be forged

| # | Truth | Status | Evidence |
|---|---|---|---|
| 1 | `-Provider Local` answers MEDIA, `-Provider Smb` answers UNC, no third value | VERIFIED | Real module probe: Local -> MEDIA, Smb -> UNC, Osd -> refused by the ValidateSet before the body runs |
| 2 | Exactly one HDTDeploymentMethod row: MDT name DeploymentMethod, Origin engine, Writable False | VERIFIED | `Get-HDTVariableMap` read back live: HDTDeploymentMethod / DeploymentMethod / False / engine |
| 3 | HDTDeploymentType still present, still writable, still separate | VERIFIED | Same probe, adjacent row: HDTDeploymentType / DeploymentType / True / engine. No row merged the two |
| 4 | A rules.yaml setting HDTDeploymentMethod is refused, saying it is a fact about how the machine booted | VERIFIED | `Assert-HDTRuleDocument.ps1:266` - names the file, the rule, the consequence and `Get-HDTVariableMap` |
| 5 | A rules.yaml setting any writable HDT name is still accepted | VERIFIED | `Assert-HDTRuleDocument.Tests.ps1` green; 34 pre-existing assertions retained |
| 6 | The refusal is driven by the map Writable column, not a hard-coded list | VERIFIED | `Assert-HDTRuleDocument.ps1:156` iterates `Get-HDTVariableMap`, collecting non-writable names into one OrdinalIgnoreCase HashSet per document |

**The second door was found and closed, and this is the phase's most valuable
finding.** The setFrom return values are validated in exactly one place -
`Resolve-HDTVariable.ps1:279` - and that guard tested only the underscore
convention. So a rule forbidden from writing HDTDeploymentMethod directly could
call a setFrom script that wrote it anyway. Widened to the same map column, with
a set-driven test. Verified present in the diff.

### 06-02 - it is published, and the ladder stops

| # | Truth | Status | Evidence |
|---|---|---|---|
| 7 | Provider Local publishes HDTDeploymentMethod = MEDIA before the first step | VERIFIED | `Start-HDTDeployment.ps1:1001` derives it at the top of section 7 from the same bootstrap.Provider handed to `Resolve-HDTDeployRoot` |
| 8 | Provider Smb publishes UNC before the first step | VERIFIED | Same single call site; `DeploymentMethodPublication.Tests.ps1` asserts both directions (17 passing) |
| 9 | The provenance log names the value and the provider it came from, at Info | VERIFIED | `Start-HDTDeployment.ps1:1006`. Engine added as an eighth provenance source in the `Add-HDTResolvedVariable` ValidateSet |
| 10 | Published through an EXPORTED command, because a payload sees only FunctionsToExport | VERIFIED | `Hephaestus.psd1:243` exports `Get-HDTDeploymentMethod`; `-EngineVariable` added to the exported `Resolve-HDTVariable` because `Add-HDTResolvedVariable` is private |
| 11 | Under MEDIA an unopenable root is NOT retried five times and does NOT open the Welcome screen | VERIFIED | `Start-HDTDeployment.ps1:1179` sets the attempt count to 1; `:1221` throws HDTContentUnreachable before the Welcome screen is reached |
| 12 | Under MEDIA that failure names the volumes considered, not a UNC path to correct | VERIFIED | `:1223` interpolates path, method, the joined ready volumes and the underlying error; said to the log at Warning first, for the run nobody is watching |
| 13 | Under UNC all five attempts and the Welcome screen still happen, exactly as today | VERIFIED | `MediaConnectLoop.Tests.ps1`, 18 passing. The five UNC assertions - five attempts, 2/4/6/8 backoff, Welcome screen, retyped share, retyped account, cancel - all green |
| 14 | A media deployment is still HDTDeploymentType = NEWCOMPUTER | VERIFIED | HDTDeploymentType untouched across the phase; asserted in `DeploymentMethodPublication.Tests.ps1` |
| 15 | A Tattoo step stamps DeploymentMethod beside DeploymentType | VERIFIED | `Invoke-HDTTattooStep.ps1` +5 lines; `Invoke-HDTTattooStep.Tests.ps1` +46 |

**The connect-loop test is behavioural, not a text scan.** `MediaConnectLoop.Tests.ps1`
lifts the payload's own while loop out **by AST** (a WhileStatementAst matched on
the provider Root argument, so it cannot drift to a stale line number) and
*executes* it against hand-written fakes in both directions. Line 235 asserts the
lifted source is non-empty, so the test cannot pass vacuously if the AST match
ever fails. `Start-Sleep` is mocked at the adapter boundary, never redefined - a
redefinition would fail Naming.Contract.

### 06-03 - the log does not get copied to a disc

| # | Truth | Status | Evidence |
|---|---|---|---|
| 16 | Under MEDIA with no HDTSLShare, no copy-back to the deploy root Logs folder | VERIFIED | Live probe: Source=Media, Path empty, Skipped=D:\Deploy\Logs |
| 17 | Under UNC with no HDTSLShare, the copy-back still happens as today | VERIFIED | Live probe: Source=DeployRoot, Path=<root>\Logs, Skipped empty |
| 18 | An explicit HDTSLShare is honoured under MEDIA | VERIFIED | Live probe: Source=HDTSLShare, Path=the named log share, Skipped empty - the gate sits AFTER the HDTSLShare branch, deliberately |
| 19 | The WinPE leg still copies its log to the OS volume before restarting, under MEDIA as under UNC | VERIFIED | `MediaLogCopyBack.Tests.ps1:358-379` - "still writes the WinPE log to the OS volume before the restart, under MEDIA", plus an AST guard: "is reached by no code path this phase added a method check to" |
| 20 | The skip is said at Info, naming the destination skipped and the method that skipped it | VERIFIED | `Start-HDTDeployment.ps1:1495` and `:2450`, `Start-HDTResume.ps1:751`. Each names the destination, the reason, the local log path, and the HDTSLShare remedy |
| 21 | The full-OS leg reads the method from the state document and skips for the same reason | VERIFIED | `Start-HDTResume.ps1:737` calls the same `Get-HDTLogDestination`; a test asserts `Get-HDTDeploymentMethod` is NEVER called there, because the method crosses the reboot in state.json |

**Backward compatibility was designed for and is provable.** The gate is
`-eq MEDIA`, not `-ne UNC`. Probed live with an empty variable bag - every
state.json written before this phase has no method at all - and it returns
Source=DeployRoot, the old behaviour exactly. Skipped is present on **all four**
return shapes (`:121`, `:161`, `:171`, `:178`) and empty on three, because a
property present on only one branch is what makes StrictMode throw three files
away.

---

## Key Link Verification

| From | To | Via | Status |
|---|---|---|---|
| `Assert-HDTRuleDocument.ps1` | `Get-HDTVariableMap` | the Writable column, read once per document | WIRED (:156) |
| `Hephaestus.psd1` | `Get-HDTDeploymentMethod` | FunctionsToExport | WIRED (:243) |
| `Start-HDTDeployment.ps1` | `Get-HDTDeploymentMethod` | called from bootstrap.Provider | WIRED (:1001) |
| `Start-HDTDeployment.ps1` | the connect-and-retry loop | the method gates ladder and Welcome screen | WIRED (:1179, :1221) |
| `Invoke-HDTTattooStep.ps1` | HDTDeploymentMethod | the stamp hashtable | WIRED |
| `Get-HDTLogDestination.ps1` | HDTDeploymentMethod | the Variable bag both legs already pass | WIRED (:152) |
| `Start-HDTResume.ps1` | `Get-HDTLogDestination` | the restored state bag, case-insensitively | WIRED (:737) |
| `Resolve-HDTVariable.ps1` | `Add-HDTResolvedVariable` | -EngineVariable, applied before precedence 1 | WIRED (:223) |

The method value **crosses the reboot** into state.json (`:1858`) and into the
resolve arguments as an EngineVariable (`:1350`) so the wizard's second
resolution keeps it. Both present.

---

## Hard-Rule Compliance

| Rule | Status | Evidence |
|---|---|---|
| **1. TDD** | **PROVEN BY EXECUTION** | See below - not taken on trust |
| **2. PS 5.1 syntax** | PASS | PowerShell51Compatibility.Contract - **1115 passed, 0 failed** |
| **3. Verb-HDTNoun** | PASS | Naming.Contract - **6 passed, 0 failed**. `Get-HDTDeploymentMethod` conforms: approved verb, uppercase HDT, singular noun |
| **4. Zero MDT dependencies** | PASS | NoMdtDependency.Contract - **1115 passed, 0 failed**. OSD and SCCM deliberately excluded from the value set as MECM's, documented in the command's own DESCRIPTION |
| **5. No direct hardware access** | PASS | The whole-phase src diff grepped for Get-CimInstance, Get-WmiObject, Get-Disk, Get-Volume, Get-Partition, IO.File, IO.Directory, the ItemProperty verbs, Copy-Item, Remove-Item, Test-Path, New-Item, Set-Content, Get-Content, Out-File, Start-Process and dism - **zero such calls added anywhere in src/**. InjectedServiceDefault.Contract green |
| **6. SupportsShouldProcess** | N/A | Nothing in this phase is destructive; it publishes a value and refuses two behaviours |
| **7. StrictMode + ErrorActionPreference** | PASS | Present in `Get-HDTDeploymentMethod.ps1`; the Skipped-on-all-four-shapes design exists precisely to survive StrictMode |
| **8. One place of truth / all surfaces** | PASS | All four reached: manifest (:243), `docs/command-categories.psd1` (:254), `docs/command-reference.html` (5 hits, **regenerated by the generator, not hand-edited**), and the rules validator |

### TDD - verified by re-running history, not by reading the summary

The brief asked whether test files appear before or alongside the implementation.
They appear **alongside** in every commit - no commit adds src/ without its
tests. But "alongside" is weak evidence on its own, so I went further: for each
task I checked out the **previous** commit's implementation into a scratch
worktree, dropped in **only** the test file as it was committed, and ran it. A
test written after the fact would come up green.

| Test file | Implementation at | Result | Verdict |
|---|---|---|---|
| `Get-HDTDeploymentMethod.Tests.ps1` | 3003650~1 | **0 passed / 8 failed** | RED first |
| `Assert-HDTRuleDocument.Tests.ps1` | 92529e6~1 | 34 passed / **4 failed** | RED first |
| `DeploymentMethodPublication.Tests.ps1` | 33f7243~1 | 8 passed / **8 failed** | RED first |
| `MediaConnectLoop.Tests.ps1` | 0359ac4~1 | 8 passed / **10 failed** | RED first |
| `Get-HDTLogDestination.Tests.ps1` | bb28689~1 | 19 passed / **10 failed** | RED first (summary claimed 20/9) |
| `MediaLogCopyBack.Tests.ps1` | 60ad03d~1 | 18 passed / **8 failed** | RED first (summary claimed 19/7) |

All six go red against the preceding implementation. The two small count
discrepancies against the summaries are harness differences (unsharded, single
process), not a contradiction - the direction is what matters and it is
unambiguous. **TDD holds.**

The scratch worktree was created under the session scratchpad and removed with
`git worktree remove` by the same code that created it. The repository tree was
never checked out over.

---

## Anti-Pattern Scan

| Pattern | Result |
|---|---|
| TODO / FIXME / XXX / HACK / placeholder in phase files | none |
| Stub returns (return null, empty hashtable, empty handler) | none - `Get-HDTDeploymentMethod` is two branches over a validated set, deliberately |
| Skipped tests hiding a gap | none - all four new phase test files contain **zero** -Skip or Set-ItResult |
| Vacuously-passing AST test | guarded - `MediaConnectLoop.Tests.ps1:235` asserts the lifted source is non-empty |
| Unproven "unchanged" claims | checked - see below |

**The "left alone" claims are true.** The whole-phase diff on
`Resolve-HDTDeployRoot.ps1`, `Invoke-HDTTaskSequence.ps1` and
`Get-HDTMachineFact.ps1` returns **zero lines**. Carry-over 2 - the resolved-root
splice guarded on a leading UNC prefix at `Invoke-HDTTaskSequence.ps1:999` - is
therefore genuinely untouched, and its guard test "leaves a local root alone,
because a drive letter moves" is intact.

**Two Rule-1 defects were found and fixed inside the phase rather than shipped.**
The failure screen Log row went **blank** under MEDIA - on the very machine whose
local log is the entire point of the behaviour - and the tail printed "no log
destination was resolved", which is true and reads like a failure to resolve one.
Both fixed in **both** legs, not just the one found first, with a skipped-flag
carried in RESULT.json. This is what the CLAUDE.md defect rule asks for.

**One latent gate defect was found and fixed.** GeneratedDocument.Contract
collected any tracked document mentioning a tools generator script, so
`06-02-SUMMARY.md` - which merely *says* the command reference was regenerated -
was treated as a generated artefact and failed on a version string. It passed its
own gate and failed the next one, because a SUMMARY is committed *after* the gate
that approves it, so git ls-files cannot see it while it is being written. This
was latent for every summary that has ever named a generator. The planning tree
is now excluded and the suite was re-run **after** committing the summary, under
the exact condition that had hidden it.

---

## Hyper-V Lab Safety

Enumerated, not assumed, and the enumeration is non-empty so this is not an
empty-equals-empty pass.

| Check | Result |
|---|---|
| Total VMs enumerated | **5** (non-empty - the snapshot is real) |
| VMs NOT named HDT-* | **0** |
| All VMs Generation 2, files under C:\HDTLab\vms\ | yes |
| Switches in use by HDT-* | `HDT External` only - no Default Switch, no invented subnet |
| Unfiltered Hyper-V pipeline run by the verifier | none - every mutating verb avoided; reads only |

HDT-PXE-01, HDT-UPDSEL-A, HDT-UPDSEL-B and HDT-WSUS-01 are **Off**.
HDT-WDS-01 is **Running**, uptime 17:29:13, created 2026-09-02 06:20.

**This is not a stray left by phase 06.** The phase's diff contains no VM code, no
e2e test and no integration test; `build.ps1 test` runs neither suite by design.
HDT-WDS-01 is the WDS infrastructure VM from earlier PXE work, on the correct
switch, within the 12 GB budget. It is recorded here only so that a running
machine is a stated fact rather than an unexplained one.

**Caveat stated honestly:** there is no pre-phase VM snapshot to diff against, so
"exactly as it was found" cannot be proven directly for a phase that is already
complete. What *can* be proven, and is, is that the phase touched no VM code at
all, and that the non-HDT set is empty on this host - the user's other virtual
machines live under VMware, on the VMnet adapters named in CLAUDE.md, not in
Hyper-V.

---

## Requirements Coverage

| Requirement (ROADMAP M7) | Status | Note |
|---|---|---|
| HDTDeploymentMethod is MEDIA under Local, UNC under Smb | SATISFIED | Proven against the real module |
| A rules document that tries to set it is refused | SATISFIED | Both doors - direct, and via setFrom |
| Carry-over 1: no retry ladder, no Welcome screen on media | SATISFIED | One gate in the payload; `Resolve-HDTDeployRoot` unchanged |
| Carry-over 2: corrected share carried into full-OS leg for UNC only | SATISFIED (kept) | Zero-line diff; guard test green |
| Carry-over 3: no log copy-back to the deploy root under MEDIA | SATISFIED | One gate in `Get-HDTLogDestination`, which both legs already call |
| Surfaces: variable map, provenance log, Tattoo, rules validator | SATISFIED | All four; the wizard summary is documented as *not* a surface, with the reason |
| Projection completeness - every referenced artifact included, nothing else | BLOCKED | `New-HDTMedia` does not exist |
| Provider-swap equivalence: same operation list under Local as Smb | BLOCKED | Not built |
| **Exit - media:** a USB stick built from the share deploys a machine with no network | **NOT MET** | Not attempted; see Gaps |
| **Exit - capture** | NOT MET | Out of this phase's scope entirely |

---

## Gaps Summary

**Two gaps. Neither is a defect in what phase 06 built, and both are structured in
the frontmatter above.**

**1. The milestone exit criterion is not met.** M7 Exit-media asks for a USB stick
that deploys a machine with no network. Nothing of the sort was attempted: no ISO
built, no USB written, no VM booted from a disc, and `New-HDTMedia` does not
exist. The phase made the engine *ready* for media by teaching it which method it
is running under.

The important point for a verifier is that **the phase did not overclaim this.**
`docs/ROADMAP.md` states in the M7 section: *"This made the engine ready for media
by teaching it which method it is running under. It did not build the media ...
the Exit-media criterion above is not met."* The 06-03 summary says the same in as
many words. The gap is one of scope, declared in advance, not a green suite
papering over an unbuilt feature - which is the failure mode this kind of
verification exists to catch.

**2. pwsh 7 is red, with 8 failures, none of them phase 06's.** Proven rather than
argued: the three affected files were checked out at cd8396c - the commit before
this phase began - into a scratch worktree and run under pwsh 7.5.8, producing
**the same 8 failures** (42 passed / 8 failed, same test names). Six are Test-Json
schema-engine differences between .NET Framework and .NET 8, one is a datetime
identity difference under Should -BeExactly, one is a WPF event-handler
difference. The project gates on 5.1 only and deliberately, because that is the
shell WinPE has.

**What is genuinely strong here.** The behavioural claims are proven at the level
that matters rather than by text scan: the connect loop is lifted out **by AST and
executed** in both directions, the log-destination answers were read back from the
**running module** and not only from a fake, backward compatibility for a
pre-phase state.json was probed live, the "left alone" files carry a verified
zero-line diff, and TDD was confirmed by **re-running each test against the
previous commit** rather than by reading a summary. Two real UI and logging
defects and one latent gate defect were found and fixed inside the phase.

**Recommendation:** accept the phase against its stated goal. Do **not** mark M7
complete - its two exit criteria, media and capture, both remain open.

---

_Verified: 2026-09-02T21:21:19Z_
_Verifier: Claude (gsd-verifier)_
_Suites run by the verifier: 5.1 test, 5.1 lint, 5.1 selfcheck, pwsh 7 test, 6 targeted TDD red-checks, 11 targeted contract and unit files, 2 live module probes_
