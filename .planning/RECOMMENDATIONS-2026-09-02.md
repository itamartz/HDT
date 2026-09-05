# Recommendations — repository survey of 2026-09-02

Read-only survey of `main` at `cd8396c`, against `docs/DESIGN.md`,
`docs/ROADMAP.md`, `.planning/`, `src/Hephaestus`, `tests/`, `schemas/`,
`build.ps1` and `.github/workflows/`. Nothing was changed, no test was run.
Every file:line below was read on that commit; the surveys that fed this were
checked against the tree before a number was written down.

**What the survey found healthy, so nobody re-audits it:** 573 source files /
~114k lines under `src/Hephaestus` (the generated `Hephaestus.bundle.ps1`
excluded); ~9.6k `It` blocks across 412 unit, 60 contract, 7 integration and
7 e2e files; **zero** `TODO`/`FIXME`/`HACK`/`XXX` in `src/` or `tests/`;
`FunctionsToExport` in `Hephaestus.psd1` matches the 297 files under `Public/`
exactly in both directions; no PowerShell-7-only syntax anywhere in `src/`.

**Not a recommendation:** the variable bag is an `OrderedDictionary` and every
record and adapter is a `[pscustomobject]` rather than a PowerShell class. That
is a recorded, execution-verified decision — `tests/helpers/README.md:685-691`
(F1), `.planning/phases/02-rules/02-01-PLAN.md:134-139` — because a class
dot-sourced into `Hephaestus.psm1` is the known-flaky path across `-Force`
re-imports. Leave it.

Ordered by priority. Each section: what was found, what it lets go wrong, the
steps in TDD order, what proves it done, and the CLAUDE.md rules that bind it.

---

## 1. The schema contract suites never run on CI, and the 5.1-compat contract runs on half its evidence

### Finding

Seven contract files validate the shipped YAML/JSON documents against
`schemas/*.schema.json` with `Test-Json`, and every one of them skips itself
when the cmdlet is absent:

```
tests/contract/WorkspaceSchema.Contract.Tests.ps1:19
$script:HDTSchemaSkip = -not [bool](Get-Command -Name Test-Json -ErrorAction SilentlyContinue)
```

Same guard in `AppSchema` (:13), `OsSchema` (:17), `RulesSchema` (:19),
`SequenceSchema` (:13), `ShippedDocumentSchema` (:32), `StateSchema` (:14), and
in `tests/unit/New-HDTWorkspace.Tests.ps1:482`.

`Test-Json` does not exist in Windows PowerShell 5.1. `.github/workflows/ci.yml`
runs one job, `shell: powershell` on `windows-latest` — 5.1 — and its own
header says the pwsh matrix "was removed while the work was 5.1-only". So on
every push those seven `Describe` blocks are skipped whole, and no automated
run anywhere validates a schema in `schemas/` or proves the hand-written
`Assert-HDT*Document` validators agree with them.

The same removal hollowed out a second contract.
`tests/contract/PowerShell51Compatibility.Contract.Tests.ps1:10-12`:

> Run this suite under BOTH engines. Under 5.1 the forbidden operators are
> parse errors; under 7 they are ordinary AST nodes. Only the pair of runs
> proves the constraint.

CI runs it under one.

**Important framing, so this is not fixed in the wrong place.** The schemas
are a development/CI/editor artefact *by design*. The module never loads one:
`Assert-HDTRuleDocument.ps1:7-10` says "Test-Json does not exist under
Windows PowerShell 5.1, so `schemas/rules.schema.json` is a gate for the
console, editors and CI while this is the gate for a deployment", `build.ps1`
copies only `src/Hephaestus/*` to `out/` (:399-400), and the manifest has no
`RequiredAssemblies`. **`src/` must not grow a schema dependency.** The fix is
entirely inside `tests/` and `.github/`.

### Why it matters

- A schema edit that makes it reject every shipped `sequence.yaml` merges
  green. The console and any editor using the schema then disagree with the
  engine, and the contract that exists to catch exactly that is asleep.
- A validator change in `Assert-HDT*Document` that drifts from its schema
  merges green for the same reason.
- A PS7-only operator that happens to parse under 5.1 as something else (the
  case the compat header describes) merges green.
- `SlowSuiteSkip.Contract.Tests.ps1` guards discovery-vs-run skip bugs but only
  scans `tests/integration` and `tests/e2e` (:25), so nothing flags a contract
  suite that has been quietly skipping for weeks.

### What to do

Two ways to get the schema leg back. Pick one; do not do both.

**Option A — a test-side validator that works on 5.1.** Add
`Test-HDTJsonSchema` to `tests/helpers/HDTTestTools/tools/`, backed by
`Newtonsoft.Json.Schema` (or `NJsonSchema`) loaded from a pinned NuGet package
under `tests/helpers/lib/`, and replace every `Test-Json -Json … -Schema …` in
the seven contracts with it. Drop the `$script:HDTSchemaSkip` guards.

- For: the contracts run on the edition the product ships on, in the same job,
  with no second runner. One `./build.ps1 test` proves everything.
- Against: a binary dependency in the test tree, a draft-07 implementation
  that is not `Test-Json`'s (small differences in `format` handling), and the
  compat contract still has only one engine.

**Option B — a second CI job on pwsh 7 that runs only the two things that need
it.** Keep the 5.1 job exactly as it is. Add a `pwsh` job that runs only
`tests/contract/*Schema*.Contract.Tests.ps1`, `ShippedDocumentSchema`,
`New-HDTWorkspace.Tests.ps1` and `PowerShell51Compatibility.Contract.Tests.ps1`,
via a new `build.ps1` task (`schema`) so the list lives in one place.

- For: no new dependency, uses the validator the contracts were written for,
  and it is the only way to give the compat contract its second engine. The
  matrix "is in the history if it is ever wanted back" (`ci.yml:13-14`), so
  this is the author's own reopening, narrowed.
- Against: a second runner per push (a few minutes — these suites are small)
  and a job whose green means nothing about WinPE, which is the reason the
  matrix was cut. That objection is answered by scoping the job to files that
  *cannot* run on 5.1 and nothing else.

**Recommendation: Option B.** It fixes both findings, adds no binary to the
repository, and is the smaller change to a CI file that already has a test
suite of its own (`tests/unit/CiWorkflow.Tests.ps1`).

Steps, test first:

1. `tests/unit/CiWorkflow.Tests.ps1` — add `It`s asserting: `ci.yml` has a job
   whose `defaults.run.shell` is `pwsh`; that job invokes
   `./build.ps1 -Task schema`; and the 5.1 job is unchanged (still
   `shell: powershell`, still `-Task ci`). Red.
2. `tests/unit/BuildScript.Tests.ps1` — add an `It` asserting `build.ps1`
   accepts `-Task schema` and that the task's file list is exactly the set
   above (assert the *set*, per rule 8 — a later schema contract must fail this
   test until it is added to the list). Red.
3. `build.ps1` — add `schema` to the `ValidateSet` at :76 and a dispatcher
   entry that runs `Invoke-Pester` over that list with the same Pester pin.
   Green.
4. `.github/workflows/ci.yml` — add the `pwsh` job. Install the same three
   pinned modules. Upload its NUnit result under a distinct artefact name.
   Green.
5. `tests/contract/SlowSuiteSkip.Contract.Tests.ps1:25` — extend the scan to
   `tests/contract` and `tests/unit`, so a `-Skip:$script:X` whose `$X` is
   always true on the CI edition is reported. Write the `It` first; expect it
   to list the seven schema files under 5.1; make the message say which
   edition would run them.
6. Leave the `$script:HDTSchemaSkip` guards in place — they are what lets a
   developer run the whole suite on 5.1 locally without seven spurious reds.
7. Whichever option: add one line to `docs/DESIGN.md` §13.2.5 saying the
   schema and compat contracts run on a pwsh leg because `Test-Json` is
   6+-only, so the next person does not remove the leg again for the reason
   it was removed the first time.

### Evidence of done

- The CI run for the commit shows two jobs green; the pwsh job's NUnit XML
  reports the schema contracts as **executed**, not skipped (count > 0 in
  `WorkspaceSchema`, `SequenceSchema`, etc.).
- `pwsh -NoProfile -Command "./build.ps1 -Task schema"` green locally.
- Break one on purpose — add a bogus `required` key to
  `schemas/sequence.schema.json` — and the pwsh job goes red while the 5.1 job
  stays green. Revert.
- `& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "./build.ps1 test"`
  still green — the 5.1 gate is untouched.

### Constraints

- No change to `src/`. The engine's validators are the runtime gate and stay
  hand-written (rule 2, and their own header comments).
- `build.ps1` functions are `Verb-HDTNoun` (rule 3).
- Pester stays pinned to 5.7.1 in the new job — a different Pester fakes
  failures (memory: "Pester version must be pinned").
- Do not run the two shell suites concurrently on the lab machine — they
  collide over DISM artefacts (memory: "Don't run both shell suites at once").
  The CI runners are separate machines; locally, run them one after the other.

---

## 2. Eight fakes have no contract test, and the secret-handling helpers are named in no test

### Finding

`tests/helpers/HDTFakes/HDTFakes.psm1` defines 23 `New-HDTFake*` factories.
Fifteen have a paired `tests/contract/<Name>.Contract.Tests.ps1` that runs the
same assertions against the fake and the real adapter. **Eight do not:**

| Fake (`HDTFakes.psm1`) | Real counterpart (`src/Hephaestus/Public/`) |
|---|---|
| `New-HDTFakeRandomNumberGenerator` (:1549) | the RNG used by `Set-HDTAutoLogon` / `HDTAdminPassword: <random>` |
| `New-HDTFakeScreen` (:1826) | `New-HDTConsoleScreen.ps1` |
| `New-HDTFakeSmbService` (:5047) | `New-HDTSmbService.ps1` |
| `New-HDTFakeWdsService` (:5308) | `New-HDTWdsService.ps1` |
| `New-HDTFakeWizardHost` (:5834) | `New-HDTWizardHost.ps1` |
| `New-HDTFakeProgressHost` (:6081) | `New-HDTProgressHost.ps1` |
| `New-HDTFakeBootStatusHost` (:6179) | `New-HDTBootStatusHost.ps1` |
| `New-HDTFakeDomainService` (:6463) | `New-HDTDomainService.ps1` |

Two of them are load-bearing for *other* contracts:
`ContentProvider.Contract.Tests.ps1:61` uses `New-HDTFakeSmbService` and
`JoinCredential.Contract.Tests.ps1:79` uses `New-HDTFakeDomainService`. A
divergence there propagates into contracts that look green.

Separately, ~96 functions in `src/` are named by no file under `tests/`. Most
are covered generically (`Get-HDT*StepTemplate`/`*StepDescription` via
`StepTemplate.Contract.Tests.ps1`, which enumerates the registry). The ones
that look genuinely untested:

- **`Unprotect-HDTShareSecret`, `Get-HDTShareSecretKey`** — the pair that turns
  the obfuscated share credential in a boot image back into a password
  (DESIGN §6.3). `grep -rn` across `tests/` returns nothing.
- `Import-HDTDriverArchive`, `Measure-HDTDriverInf`, `Read-HDTUpdatePackage`,
  `Get-HDTTargetDiskAssessment`, `Remove-HDTBlankRun`,
  `Update-HDTDriverFolderReference`, `Test-HDTBootImageCertificatePassword`.
- The three WPF entry points `Show-HDTBuildProgressWindow`,
  `Show-HDTDriverWindow`, `Show-HDTSelectionProfileWindow`, and console helpers
  `Get-HDTConsoleHeader`, `Get-HDTConsoleDisplayText`, `Get-HDTConsoleFlagText`,
  `Get-HDTConsoleLintText`, `Get-HDTConsoleJsonProperty`,
  `Get-HDTConsoleCatalogEntry`, `Resolve-HDTConsoleWindowSize`.

### Why it matters

Rule 5 — engine logic runs only against injected services — is only worth
anything if fake ≡ real. CLAUDE.md rule 8's own example is the fake `MoveItem`
that moved files and not directories while the real adapter did both: the
fake was wrong, every test was green, and the defect shipped. Eight adapters
are in that state today. The share-secret pair is the one that decides whether
a machine can reach the share at all, and a regression there is found on a
booted VM, not in Pester.

### What to do

1. **A contract that names the set, so the ninth fake cannot be forgotten.**
   New `tests/contract/FakeCoverage.Contract.Tests.ps1`: enumerate
   `function New-HDTFake*` in `HDTFakes.psm1` by AST, enumerate
   `tests/contract/*.Contract.Tests.ps1`, and assert every fake `X` has a
   `X.Contract.Tests.ps1` (or is on an explicit, commented allow-list, empty at
   the end of this work). Red with eight names. This is the rule-8 "test
   against the set" test; write it first.
2. Eight contract files, one per fake, in the existing shape — copy
   `ProcessService.Contract.Tests.ps1`: a `-ForEach` over `@{ Name='fake'; Factory=… }`
   and `@{ Name='real'; Factory=…; Skip=<environment predicate> }`, same `It`s
   for both. What each must assert, at minimum:
   - **SmbService**: method set and parameter names; `Connect` on an
     unreachable UNC throws the same exception *type* from both after
     unwrapping (`ContentProvider.Contract.Tests.ps1:20` shows the unwrapping
     idiom); drive-letter allocation from `Z:` downward.
   - **WdsService**: `Import-WdsBootImage` argument shape; replace-in-place
     semantics (`Import-HDTBootImageToWds.Tests.ps1` already asserts them
     against the fake — lift those into the contract).
   - **DomainService**: the join credential split (`JoinCredential.Contract`
     already probes it — move the fake there into a real pair).
   - **RandomNumberGenerator**: length, character class, and that two calls
     differ; the real one must be `RNGCryptoServiceProvider`-backed, not
     `Get-Random`.
   - **WizardHost / ProgressHost / BootStatusHost / Screen**: these are WPF
     hosts. Their contract is the *member surface* (method and property
     names, parameter names, return shapes) — WPF builds in Pester with no
     desktop (memory: "Console wiring is testable"), so the real leg can
     construct the host; it must not `ShowDialog`.
3. Real-leg skips are environment predicates evaluated at discovery, in the
   shape `SlowSuiteSkip` enforces (`SPIKES S9.15`), never a `Set-ItResult`
   inside `It`.
4. **Share secret round trip.** `tests/unit/ShareSecret.Tests.ps1`:
   `Protect-HDTShareSecret` → `Unprotect-HDTShareSecret` returns the input;
   a key from `Get-HDTShareSecretKey` is stable across two calls in one
   process and differs for a different boot image identity; a tampered blob
   fails with a typed `HDT*` error and never returns partial plaintext; the
   log line for either side is redacted (reuse
   `SecretRedaction.Contract.Tests.ps1`'s assertion helper). Red first, then
   fix whatever it finds.
5. The remaining untested private helpers: one unit file each, smallest
   first — `Measure-HDTDriverInf` and `Read-HDTUpdatePackage` against the real
   `.inf` and `.msu` fixtures already in `tests/fixtures/`. The console
   helpers can wait for section 6's console refactor; do not block on them.

### Evidence of done

- `FakeCoverage.Contract.Tests.ps1` green with an empty allow-list.
- `Invoke-Pester tests/contract -Output Detailed` under 5.1 shows 23
  `*.Contract.Tests.ps1` with both `fake` and `real` legs executed for every
  service the lab machine can host, and the real leg *skipped* (not
  passed-vacuously) for WDS.
- `grep -rln "Unprotect-HDTShareSecret" tests/` returns at least one file.

### Constraints

- Fakes stay hand-written classes in `HDTFakes.psm1`; `Mock` only at the
  adapter boundary (Conventions). No new fake defined outside that module —
  a dot-sourced class is the flaky path (README F1).
- Real adapters stay branch-free (rule 1's exception) — if a contract exposes
  a branch in one, the fix is to move the branch into a tested helper, not to
  unit-test the adapter.
- Never write the fake's class name as a type literal in a test
  (`01-03-SUMMARY.md:76-80`).
- Secret tests never write a real credential to a fixture; generate it in
  `BeforeAll`.

---

## 3. The documents disagree with each other and with the code

### Finding

Three roadmaps, three answers on M7:

- `docs/ROADMAP.md:751` — `CAPTURE IN PROGRESS · MEDIA DEFERRED TO v2`.
- `.planning/ROADMAP.md:19` — `~~M7 — Capture and standalone media~~ **DEFERRED TO v2**`.
- `README.md:398` — "deferred to v2, at the author's direction" — while
  `README.md:15-33` embeds two films of the capture exit criterion running:
  sysprep, one-shot boot into WinPE, `CaptureImage`, and the WIM deployed to a
  second VM.

The capture half is built — `Invoke-HDTSysprepStep`, `Invoke-HDTCaptureImageStep`,
`Invoke-HDTBootToWinPEStep`, `Templates/reference.yaml`,
`tests/e2e/ReferenceCapture.E2E.Tests.ps1`,
`tests/e2e/CapturedImageDeployment.E2E.Tests.ps1`, and the seal proof in
`SPIKES.md` S23.13 — but `docs/ROADMAP.md`'s **Exit — capture** block
(:778-794) carries no `✅ Met`.

`docs/DESIGN.md` is stale in five places, in both directions:

| Where | Says | Code |
|---|---|---|
| §1 `:53-56` | "§9.3 Capture … v1 … does not sysprep and capture its own" | capture is built (above) |
| §4.2 `:430-433` | lists `WindowsUpdate` as a v1 step type; `:404-406` puts it in the canonical example sequence | no `Invoke-HDTWindowsUpdateStep` exists; `:436-438` two paragraphs later says it is deferred |
| §4.2 `:430-433` | omits `Gather`, `NoOp`, `Tattoo`, `InstallCertificate` | all four ship with `Invoke-HDT*Step.ps1`, template, description and console catalog entry |
| §11.2 `:2723-2732` | Credentials page with `HDTSkipCredentials`; `HDTSkipDomainMembership`; `HDTSkipTimeZone`; "Admin password — NOT A PAGE" | none of the three skip names exists in `src/`; `Templates/Wizard/wizard.yaml:214` *is* an `AdminPassword` page; there is a `BitLocker` page (`:157`) not in the table |
| §12 `:2828-2830`, `:2846` | "WPF on .NET 8, MVVM, hosting PowerShell via `Microsoft.PowerShell.SDK`"; "ships as a separate solution" | no `.csproj`/`.sln` in the repo; the console is a PowerShell function loading XAML (`Show-HDTConsole.ps1:26-29`); §16.2 `:3048` already says "one module — engine and WPF console alike" |
| §12 `:2836` | `Move-HDTConsoleStep` | the command is `Move-HDTStep` |
| §14 `:2950-2951` | "Prompt by default; encrypted opt-in" / "per-deployment random password" | §6.3 `:1724,1777-1779` and §4.5.2 `:1165` reversed both; code follows the detailed sections |

Smaller:

- `src/Hephaestus/Private/Add-HDTResolvedVariable.ps1:53-56` and
  `src/Hephaestus/Public/Resolve-HDTVariable.ps1:85-86` document "five" / six
  sources; the `ValidateSet` at `Add-HDTResolvedVariable.ps1:109` has seven
  (`Wizard` is missing from both comments). Plan `06-02` adds an eighth,
  `Engine`.
- `.planning/ROADMAP.md:98-100` — "GitHub-side CI has not been observed green
  because the repository has no remote yet". `README.md:3-5` carries live CI
  badges from `github.com/itamartz/HDT`, tags through `v0.15.0`.
- `.planning/ROADMAP.md:16-20` maps phases to `.planning/phases/05.5-technician-ui/`,
  `06-drivers/`, `07-apps-fullos/`, `08-capture-media/`, `09-console/`. None
  exists or ever did (`git log --diff-filter=A` is empty). `:331-349` ticks
  six `07-0N-PLAN.md` files that were never committed. M5, M6 and M8 have no
  PLAN/SUMMARY/VERIFICATION record, unlike M0–M4. Meanwhile
  `.planning/phases/06-offline-media/` (three plans, `cd8396c`) exists and is
  not in that table at all.
- `docs/ROADMAP.md:200` ("no applications, updates or roles (M6)") and `:342`
  ("DESIGN 11's technician UI is absent. It is M8") are point-in-time lines in
  met milestones, not struck through the way `:246-251`, `:305-312`, `:679-684`
  are.
- M0 and M1 have no `✅ Met` block in `docs/ROADMAP.md` (`:31`, `:51-52`);
  completion is recorded only in `.planning/ROADMAP.md:95,119`.

### Why it matters

CLAUDE.md says the three documents "settle nearly every design question. Do
not re-derive or contradict them." A `rules.yaml` author reading §11.2 writes
`HDTSkipTimeZone: true` and it silently does nothing. An agent planning work
from §12 plans a .NET solution. An agent reading `.planning/ROADMAP.md`
believes M7 is deferred and skips the capture tests. The `hdt-phase` workflow
reads these files; wrong input there is wrong output at scale.

### What to do

One documentation pass, in this order, one commit per file:

1. **`docs/ROADMAP.md`.** Add `✅ Met` to **Exit — capture** with the evidence
   (`ReferenceCapture.E2E`, `CapturedImageDeployment.E2E`, SPIKES S23.13, the
   README films). Change the `:751` banner to `CAPTURE MET · MEDIA IN PROGRESS`
   (phase 06 is planned). Strike `:200` and `:342` in the house style. Add
   `✅ Met` blocks to M0 and M1 citing `01-VERIFICATION.md` / `02-VERIFICATION.md`.
2. **`.planning/ROADMAP.md`.** Un-strike M7; split it into "capture — met" and
   "media — phase 06, in progress, `.planning/phases/06-offline-media/`".
   Replace the phase-directory table with what exists on disk; mark 05.5, 07,
   09 as "no phase record — built on `feat/*` branches and merged; evidence
   lives in `docs/ROADMAP.md` exit blocks". Delete the "no remote yet" clause.
   Add the offline-servicing pipeline (DESIGN §7.5, `ApplyUpdates`,
   `WindowsUpdates\`) to the v2 list's neighbour so the "no in-sequence
   patching" cost line (`:43-65`) is no longer false.
3. **`README.md:398`.** "capture met (2026-09-02); standalone media in
   progress".
4. **`docs/DESIGN.md`**, each as a dated revision note in the file's own style:
   - §1: remove §9.3 from the deferred list; keep §6.2.
   - §4.2: drop `WindowsUpdate` from the v1 list (keep the disambiguation
     paragraph), add `Gather`, `NoOp`, `Tattoo`, `InstallCertificate`; fix the
     §4.1 example at `:404-406`.
   - §11.2: rewrite the table from `Templates/Wizard/wizard.yaml` — pages,
     `skip:` names, `validate` rules, in file order. Remove Credentials
     (say where credentials are actually collected: the Welcome flow,
     `HDTSkipWelcome` in `bootstrap.json`), add BitLocker, un-strike Admin
     password with the reason from `wizard.yaml:205`. Either add
     `HDTSkipDomainMembership`/`HDTSkipTimeZone` to the code (footnote ¹ says
     "keeps both because MDT does" — that is the MDT-homage rule, so this is
     the direction to prefer) or strike them; do not leave them promised.
     If added: test first against the *set* of pages in `wizard.yaml`
     (`WizardPageSurface.Contract.Tests.ps1` is the place), then the page's
     `skip:`, then `Get-HDTWizardSkip`, then splice `C:\HDTLab\Share\Scripts\UI\wizard.yaml`.
   - §12: replace the stack paragraph with what §16.2 already says; fix
     `Move-HDTConsoleStep` → `Move-HDTStep`.
   - §14: fix the two rows to match §6.3 and §4.5.2.
5. **Source comments.** `Add-HDTResolvedVariable.ps1:53-56` and
   `Resolve-HDTVariable.ps1:85-86`: list the seven (eight after 06-02) and say
   the `ValidateSet` is the truth. Better: a unit `It` that reads the
   `.PARAMETER Source` help text and asserts it names every `ValidateSet`
   member — rule 8's "test against the set", so the ninth source cannot be
   forgotten in the comment.
6. `tests/contract/WizardPageSurface.Contract.Tests.ps1`: if it does not
   already, assert that every `skip:` name in `wizard.yaml` appears in the
   §11.2 table (parse the markdown table) and vice versa. That is the test
   that would have caught §11.2 drifting.

### Evidence of done

- `grep -n "DEFERRED TO v2" .planning/ROADMAP.md README.md` returns only the
  v2 items that are still deferred (media, online `WindowsUpdate`, iPXE).
- `grep -n "HDTSkipCredentials\|HDTSkipTimeZone\|HDTSkipDomainMembership\|Move-HDTConsoleStep\|Microsoft.PowerShell.SDK" docs/DESIGN.md` — each hit is either gone or has a matching name in `src/`.
- The new source-list `It` and wizard-table `It` are green under 5.1.

### Constraints

- Where the code and DESIGN disagree, **decide which is right and update the
  other** — never quietly leave them apart (CLAUDE.md, "Specification").
  For §11.2 skips, MDT's shape wins (memory: "HDT is a homage to MDT").
- YAML on the share is spliced, never re-serialised — comments die at parse
  time (memory: "YAML edits splice, never re-serialise").
- Another session commits on `main` (memory: "Concurrent session on main");
  `cd8396c` landed during this survey. Commit per file, check `git status`
  before every `git add`.

---

## 4. The boot image carries a bootloader a patched Secure Boot machine refuses

### Finding

`docs/ROADMAP.md:343-369`, recorded under a *met* milestone (M4), echoed as
an open item at `.planning/ROADMAP.md:67-76`. SPIKES S20: `bootmgr.efi` and
`EFI\Boot\bootx64.efi` from the ADK's WinPE media carry **SVN 3.0 against an
enforced floor of 7.0** — a Secure Version Number revocation, not a DBX hash
and not the certificate. A fully patched machine with Secure Boot on refuses
the ISO and the PXE payload alike.

The roadmap has already scoped the work:

- The swap goes in `Update-HDTBootImage` after the media tree is copied
  (`Update-HDTBootImage.ps1:771`) and before the ISO is burned (`:1644`).
- `New-HDTPxePayload.ps1:18-20` stages `bootmgfw.efi` and `wdsmgfw.efi` from
  the same ADK media — "**Both paths, or neither.**"
- `efisys*.bin` embeds its own `cdboot_noprompt.efi`; if an SVN check reaches
  it, the `.bin` is rebuilt, not patched.
- The untested coupling: the patched boot manager (`10.0.28000.342`) against
  the ADK's 26100-era `EFI\Microsoft\Boot\BCD`. "This cannot be proven by a
  build succeeding — it needs a Generation 2 VM with Secure Boot on."

`grep -n bootmgr src/Hephaestus/Public/Update-HDTBootImage.ps1` returns
nothing. Not started.

### Why it matters

Every physical machine that has taken the 2024-2025 Secure Boot servicing
(the SVN floor is pushed by Windows Update) refuses HDT's media outright. The
Latitude 5420 that proved M5/M6 evidently had not yet; the next one will. The
failure is a firmware message before WinPE loads, so nothing HDT logs can
explain it. This is the largest unshipped piece of a milestone marked met.

### What to do

1. **A tested helper decides the source, the adapter copies.**
   `Get-HDTBootLoaderSource` (Private): given the ADK media root and an
   optional `-BootLoaderPath` (a folder with `bootmgr.efi`, `bootmgfw.efi`,
   `bootx64.efi`, `wdsmgfw.efi` taken from a patched Windows), returns the
   ordered list of `(source, destination)` pairs for a boot image and, with
   `-Target Pxe`, for the PXE payload — reading the SVN from each file's
   version resource so the log can say `bootmgfw.efi 10.0.28000.342 (SVN 7)
   replaces 10.0.26100.x (SVN 3)`. Unit test first, against
   `New-HDTFakeFileSystem`: the pair list for each target, the refusal when
   the supplied folder lacks one of the four files (an incomplete swap is
   worse than none — one refused loader among four is still a refused boot),
   and the log lines. Assert the **set** of files, not one name (rule 8).
2. **`Update-HDTBootImage`** gains `-BootLoaderPath`; after `:771` it calls the
   helper and lets `IFileSystem` copy. `Update-HDTBootImage.Tests.ps1` asserts
   the copies appear in the fake's operation list between the media copy and
   the ISO burn, and that the manifest (`New-HDTBootImageManifest`) records
   the loader version so `Get-HDTBootImage` can show it.
3. **`New-HDTPxePayload`** gains the same parameter and the same helper with
   `-Target Pxe`; `New-HDTPxePayload.Tests.ps1` asserts the staged
   `bootmgfw.efi`/`wdsmgfw.efi` come from the supplied folder and the hash
   rows (`Get-HDTPxePayloadRow`) reflect it.
4. **Surfaces (rule 8):** the console's boot-image build window
   (`New-HDTConsoleBootImageView`, `ConsoleBootImageField.Contract`) needs the
   field; `docs/command-reference.html` / `command-categories.psd1` need the
   parameter; the workspace `boot-image.yaml` (or wherever the build settings
   are persisted — check `Assert-HDTWorkspaceDocument`) needs the key and its
   validator entry; `Templates/` if a default is shipped.
5. **Integration** (`tests/integration/BootImage.Integration.Tests.ps1`): build
   once with a real loader folder and assert the four files' version resources
   in the mounted media tree.
6. **The proof.** An e2e `It` in `WinPeSmoke.E2E.Tests.ps1`: `New-HDTLabVirtualMachine`
   with `-SecureBoot` (add the switch; refuse anything but the `HDT External`
   / `HDT Lab` switches as it does today), boot the rebuilt ISO, assert the
   `Logs\_active\<RunId>.json` marker appears. Then the same ISO on a VM with
   Secure Boot **off**, to show the swap did not break the unpatched path.
   Then the PXE payload on `HDT Lab` only.
7. **Document the source of the loader files.** They come from a patched
   Windows install (`C:\Windows\Boot\EFI\`), which is not in the repository
   and not in the ADK; `.planning/PROJECT.md` "Lab assets" gets a row for
   where this lab keeps them, and `docs/DESIGN.md` §5.1 gets a paragraph on
   why the ADK's own loader is not enough and what an admin supplies.
8. Rebuild this lab's boot image and splice the new key into
   `C:\HDTLab\Share`'s configuration — the share runs the share's copy, not
   the repository's (rule 8, corollary).

### Evidence of done

- `Update-HDTBootImage.Tests.ps1` and `New-HDTPxePayload.Tests.ps1` green
  under 5.1 with the new assertions.
- The manifest of a built image names the loader version and SVN.
- An `HDT-*` Generation 2 VM with Secure Boot enabled boots the rebuilt ISO to
  the HDT progress window and writes its `_active` marker; a second with
  Secure Boot off does the same; a third on `HDT Lab` PXE-boots the payload.
  The three run IDs go in the SPIKES entry that closes S20.

### Constraints

- The image bakes the share address in — **read the host's `HDT External`
  address before building** and never write the octet anywhere (CLAUDE.md
  "Networking"; memory: "Lab host IP is a lease").
- VMs are `HDT-*`, Generation 2, under `C:\HDTLab\vms\`, on `HDT External` or
  `HDT Lab` only; PXE only on `HDT Lab`. Touch no other VM.
- The copy is an adapter call through `IFileSystem`; the decision (which
  files, which order, refuse-if-incomplete) is the tested helper. Adapters stay
  branch-free.
- `SupportsShouldProcess` on the build, as it already has (rule 6).
- Logs say the version and SVN of what was replaced and what replaced it, and
  why — the admin reading a firmware refusal a week later needs it (CLAUDE.md
  "Logging").
- Do not run the e2e leg while a gate is running; do not run both shell
  suites at once.

---

## 5. Standalone media: the variable is planned, the projection command is not

### Finding

`docs/ROADMAP.md:805-830` settles `HDTDeploymentMethod` (`UNC` / `MEDIA`,
engine-origin, not settable from rules, published where `bootstrap.Provider`
is read at `Start-HDTDeployment.ps1:980`) and names its surfaces:
`Get-HDTVariableMap`, the provenance log, `Invoke-HDTTattooStep`, the wizard
summary, `Assert-HDTRuleDocument`. `:832-877` settles the three carry-overs:
(1) no five-attempt retry and no Welcome screen under `MEDIA`; (2) the
corrected share into the full-OS leg — already built, guarded at
`Invoke-HDTTaskSequence.ps1:999`, keep it; (3) no derived log copy-back to a
deploy root under `MEDIA`.

`grep -rn HDTDeploymentMethod src/ tests/ schemas/` returns nothing.
`New-HDTMedia` does not exist. `.planning/phases/06-offline-media/` (three
plans, `cd8396c`, 2026-09-02 22:15) covers the variable (06-01), behaviour 1
and the `Engine` provenance source (06-02), and behaviour 3 (06-03). **It does
not cover `New-HDTMedia`** — the projection itself, the USB layout, the
`Local` provider wired in, or the media marker `Start-HDTDeployment` will
look for.

### Why it matters

Without the projection, `HDTDeploymentMethod` can never read `MEDIA` on a real
machine, so 06-02 and 06-03 ship behaviours that only a fake exercises. The
`Local` content provider is built and contract-tested
(`New-HDTLocalContentProvider.ps1`, `ContentProvider.Contract.Tests.ps1`), so
the gap is genuinely one command plus its wiring.

### What to do

Execute 06-01 → 06-02 → 06-03 as written; they already carry RED-first tests
and the rule-8 surfaces. Then the fourth plan, which does not exist yet:

1. **`06-04-PLAN.md` — `New-HDTMedia`.** Public cmdlet, `SupportsShouldProcess`.
   Input: workspace path, an output root (a folder that a later step formats
   onto a stick — HDT does not touch the USB device itself in v1; the admin
   uses `diskpart`/Rufus, per "Admins own their choices"), an optional
   selection profile to prune `OperatingSystems\`, `Drivers\`,
   `Applications\`, `WindowsUpdates\`. Output: the DESIGN §6.2 layout — boot
   files from the boot image build at the root, the projected share under
   `\Deploy\` (or the folder DESIGN names), a media marker file the bootstrap
   reads, and `bootstrap.json` with `Provider: Local`.
2. **Tests first** (`tests/unit/New-HDTMedia.Tests.ps1`, against
   `New-HDTFakeFileSystem` and `New-HDTFakeBootImageService`): the file set
   copied for a workspace with and without a selection profile — assert the
   **set**, computed from the fake workspace, not a hand-typed list; the
   marker exists; `bootstrap.json` names `Local`; `Logs\` and `Captures\` are
   *not* projected (read-only content, no place to write); the manifest
   records the source boot image hash; `-WhatIf` copies nothing.
3. **The bootstrap side.** `Start-HDTDeployment` already reads
   `bootstrap.Provider`; add the marker check that 06-02 §"half of behaviour 1
   is already built" describes, so a stick with the marker resolves the
   deploy root to its own volume without a network. Test in
   `StartHDTDeploymentPayload.Tests.ps1`.
4. **Surfaces (rule 8):** manifest `FunctionsToExport`; `docs/command-reference.html`
   and `command-categories.psd1`; a console **Media** node — DESIGN §12 lists
   it in the tree and `.planning/ROADMAP.md:63-65` warns about nodes with
   nothing behind them; `Get-HDTWorkspacePath` if a `Media\` folder is added
   (its `ValidateSet` at `:62-63` is the set test); `Assert-HDTWorkspaceDocument`
   for any new key; `schemas/workspace.schema.json`.
5. **Exit — media** (`docs/ROADMAP.md:802-803`): "a USB stick built from the
   share deploys a machine with no network." The VM form: `New-HDTLabVirtualMachine`
   with the media folder burned to an ISO via `New-HDTBootIso`'s oscdimg
   path (a data ISO — check `oscdimg` arguments in SPIKES before assuming the
   boot-ISO ones fit), **no network adapter**, and the deployment reaching
   the full-OS leg with `HDTDeploymentMethod = MEDIA (Engine)` in the
   provenance log and no `Logs\` written to the deploy root. Then mark M7 met
   in `docs/ROADMAP.md` with the run ID.
6. Splice `C:\HDTLab\Share` for anything the phase adds to `Templates\` or
   `Payload\` — the share runs its own copy.

### Evidence of done

- `Invoke-Pester tests/unit/New-HDTMedia.Tests.ps1` green under 5.1;
  `tests/contract/VariableNamespace.Contract.Tests.ps1` green with the
  `HDTDeploymentMethod` row.
- `Get-HDTVariableProvenance` on a media run shows
  `HDTDeploymentMethod = 'MEDIA' (Engine)`.
- An `HDT-*` VM with no NIC deploys to the desktop from the projected media,
  and `docs/ROADMAP.md` M7 carries `✅ Met` for both exits.

### Constraints

- All 5.1 syntax in `src/` (rule 2). `New-HDTMedia` is destructive to its
  output folder only: `SupportsShouldProcess`, and refuse an output root that
  is not empty or is one of the protected paths (rule 6, "Paths that must
  never be deleted").
- Media is a *projection of the share with the provider swapped, not a second
  code path* (CLAUDE.md "Architecture"): no media-only step types, no
  media-only sequence.
- The media build bakes nothing network-specific in — but it reuses the boot
  image, and that one does; the 192.168.1.0/24 rule applies to the image it
  starts from.
- 06-02's "do not rewrite the `\\` guard at `Invoke-HDTTaskSequence.ps1:999`"
  is a design decision already taken; carry-over 2 is kept, not touched.

---

## 6. Small items

Each is a single sitting. Test first where there is logic; a doc line where
there is not.

### 6.1 `ci.yml` has no `timeout-minutes`

`coverage.yml:31` sets 240 and `tests/unit/CiWorkflow.Tests.ps1:214-215`
asserts it — for the coverage job only (`$script:coverageJob`, `:181-183`).
The CI job runs under GitHub's 360-minute default; a hung DISM or a wedged
Pester runner burns six hours of runner time in front of every subsequent
push.

1. `CiWorkflow.Tests.ps1`: add the same two assertions against the `windows`
   job in `ci.yml`, bound to something like `30 < t < 90` — the suite is
   ~10 minutes; a 45-minute cap catches a hang without tripping on a slow
   runner. Red.
2. `ci.yml`: `timeout-minutes: 45` on the job. Green.

Evidence: the `It` passes; a workflow run shows the timeout in its job
summary.

### 6.2 The same breadth-first directory walk in two places

`src/Hephaestus/Private/Get-HDTDriverPackageFile.ps1` and
`src/Hephaestus/Public/Copy-HDTLog.ps1` each implement a `$pending`
`ArrayList` BFS over `IFileSystem` — push `[pscustomobject]@{ Path; Relative }`,
pop index 0, recurse. Two copies of the same traversal drift; the next
`IFileSystem` edge case (junctions, a directory that vanishes mid-walk) gets
fixed in one.

1. `tests/unit/Get-HDTRelativeFile.Tests.ps1` first: against
   `New-HDTFakeFileSystem`, a three-level tree yields every file with its
   relative path in breadth-first order; an empty root yields nothing; a
   `-Filter` limits by extension. Red.
2. `Private/Get-HDTRelativeFile.ps1` (or the name that matches how the two
   callers speak of it — check both before choosing). Green.
3. Replace both call sites; their existing tests stay green unchanged. If
   either caller's test does not pin the *order* of files, add that `It` —
   order is the thing a shared walk can change.

Evidence: `grep -rn "\$pending" src/Hephaestus` returns one file.

### 6.3 `schemas/machine.schema.json` has no `Assert-` validator; `Assert-HDTBootstrapRuleDocument` has no schema; three schemas have no contract test

- `machine.schema.json` is consumed only by
  `tests/contract/RulesSchema.Contract.Tests.ps1:57,66,70,149`. The engine
  reads machine overrides through `Get-HDTMachineOverride` with no
  `Assert-HDTMachineDocument`, so a malformed override is either silently
  ignored or fails somewhere inside resolution with a message about the
  symptom.
- `Private/Assert-HDTBootstrapRuleDocument.ps1` validates a document that no
  schema describes, so the console and editors have nothing to validate it
  against.
- `os-releases.schema.json`, `selection-profile.schema.json`,
  `update.schema.json` have validators but no `*Schema.Contract.Tests.ps1`,
  so nothing proves schema ≡ validator for them.

1. **The set test.** `tests/contract/SchemaPairing.Contract.Tests.ps1`:
   enumerate `schemas/*.schema.json`, `Private/Assert-HDT*Document.ps1`, and
   `tests/contract/*Schema.Contract.Tests.ps1`; assert the three sets pair up
   by a declared name map (allow-listed exceptions must carry a reason
   string). Red with the five names above. This is the test that keeps the
   twelfth schema honest.
2. `tests/unit/Assert-HDTMachineDocument.Tests.ps1` first (mirror
   `Assert-HDTRuleDocument.Tests.ps1`: unknown key refused, `schemaVersion`
   newer than the engine refused, valid sample accepted), then
   `Private/Assert-HDTMachineDocument.ps1`, then call it from
   `Get-HDTMachineOverride`. Same header sentence as its siblings about
   `Test-Json` and 5.1.
3. `schemas/bootstrap-rules.schema.json` written from
   `Assert-HDTBootstrapRuleDocument`'s key set, plus its contract test.
4. Three contract files for the three orphan schemas, in the shape of
   `AppSchema.Contract.Tests.ps1` — they will run only on the leg section 1
   restores.
5. Surfaces (rule 8): `ShippedDocumentSchema.Contract.Tests.ps1` if it
   enumerates schemas by name; the console's validation surface if it lists
   them.

Evidence: `SchemaPairing.Contract.Tests.ps1` green with an empty exception
list; `Invoke-Pester tests/contract/*Schema*` executed (not skipped) on the
pwsh leg.

### 6.4 `SlowSuiteSkip.Contract.Tests.ps1` scans only `integration` and `e2e`

Covered by section 1 step 5. Listed here so it is not lost if section 1 takes
Option A.

### 6.5 `Tattoo` is used by no shipped template and no sample

`Invoke-HDTTattooStep` is implemented, registered, contract-tested, and
exercised by `tests/e2e/payload/REF-*/sequence.yaml` — and appears in neither
`Templates/client.yaml`, `Templates/reference.yaml`, nor any
`samples/workspace/TaskSequences/*`. MDT's `ZTITatoo` runs in every standard
sequence; the step that writes `HDTDeploymentMethod` and the run ID into the
registry is the one an admin reads first when a machine turns up broken a
month later.

1. `tests/contract/SequenceTemplatePlan.Contract.Tests.ps1` (or
   `ShippedDefault.Contract`): an `It` that every shipped template with a
   full-OS leg carries a `Tattoo` step after `ApplyUnattend` and before
   `InstallApplications` — MDT's placement. Red.
2. Add it to `client.yaml` and `reference.yaml`. Green.
3. **Splice it into `C:\HDTLab\Share\TaskSequences\*\sequence.yaml`** — the
   share runs its own copy, and 0.10.1's `PNP-TEST` is the recorded cost of
   forgetting (rule 8).
4. `docs/DESIGN.md` §4.2 lists it (section 3 step 4).

Evidence: the contract `It` is green; `Get-HDTVariableProvenance` on the next
lab run shows the tattoo written; the share's `sequence.yaml` diff is a
splice, not a rewrite.

### Constraints for all of section 6

Rules 1–3 and 7 throughout; the share is spliced; the `hdt-phase` workflow
and CLAUDE.md rule 8 tables get a row when one of these turns out to be
another "half-feature" surface.

---

## Order of work

1. Section 1 (Option B) — half a day, and every later section's schema and
   compat evidence depends on it.
2. Section 6.1 — ten minutes, same CI file, same commit series.
3. Section 2 — the `FakeCoverage` set test first, then the eight contracts,
   then the share-secret round trip.
4. Section 3 — one pass, one commit per document; do it before section 4 or
   5 so the plans those phases read are true.
5. Section 6.3 and 6.5 — with section 3, since they touch the same templates
   and validators.
6. Section 4 — needs the loader files staged in the lab and a Secure Boot VM;
   the only item here that cannot be proven from Pester alone.
7. Section 5 — phase 06 as planned, then 06-04 for `New-HDTMedia`, then the
   media exit.
8. Section 6.2 — whenever the next `IFileSystem` edge case lands.

Every step: `& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "./build.ps1 test"`
green before a commit; the affected files iterated on their own until then
(memory: "Iterate on affected tests, not the full suite"); the gate run in
the background with a timestamped tick, and the tree left alone while it
runs.
