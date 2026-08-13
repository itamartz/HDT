---
phase: 05-bootimage
plan: 02
subsystem: content-provider
tags: [content-provider, smb, share-credential, least-privilege, acl, obfuscation, seam, pester, tdd, powershell-5.1]

# Dependency graph
requires:
  - phase: 01-foundations
    provides: the module skeleton, New-HDTErrorRecord, the fake conventions, the naming / 5.1 / no-MDT contracts
  - phase: 03-engine
    provides: New-HDTServiceCatalog, New-HDTExecutionContext, New-HDTLogContext, the shared fake journal
  - phase: 04-imaging
    plan: 02
    provides: Get-HDTOperatingSystem, ConvertTo-HDTOperatingSystemCatalog and the ImagePath seam they marked
  - phase: 05-bootimage
    plan: 01
    provides: workspace.yaml refusing a password key and naming Set-HDTShareCredential; Get-HDTWorkspacePath's closed folder set
provides:
  - "IContentProvider: five members, three implementations, one contract - New-HDTFakeContentProvider, New-HDTLocalContentProvider, New-HDTSmbContentProvider"
  - "New-HDTSmbService: the branch-free adapter over SmbShare, and New-HDTFakeSmbService as its double"
  - "The guest / anonymous / SMB1 refusal at Connect, with the refused mapping torn down"
  - "Set-HDTShareCredential / Get-HDTShareCredential: Control\\share-credential.json, obfuscated, gitignored, with the warning sentence inside the file"
  - "Test-HDTShareAcl and Get-HDTShareAccessRule: DESIGN 6.3's least-privilege check as findings that never block a build"
  - "docs/share-account.md: the setup steps DESIGN 6.3 promises and ROADMAP M4 lists"
  - "The catalog's twelfth service, Content, and ApplyImage resolving its image through it"
  - "Get-HDTSlowSuiteSkipViolation + tests/contract/SlowSuiteSkip.Contract.Tests.ps1: SPIKES S9.15 cannot come back"
affects: [05-03-deploy-root-and-launcher, 05-04-update-bootimage, 05-05-iso-and-wds, 06-drivers, 07-apps]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "One interface, three implementations, one contract file with a row per implementation - and a step whose recorded operation list is identical across two of them"
    - "An error id carried in the message rather than in an ErrorRecord, because a ScriptMethod cannot carry FullyQualifiedErrorId to its caller and a class method can"
    - "Path segments collapsed by hand instead of by [IO.Path]::GetFullPath, which clamps '..' at a UNC share root instead of reporting the escape"
    - "Map, then read the established identity back and refuse it - authentication proven by its result rather than by the absence of an exception"
    - "A secret written by exactly one command, obfuscated with a key that ships in the module, with the file itself carrying the sentence that says so"
    - "A checker that only warns, paired with a document that says what right looks like, with a test asserting the document names every folder the checker judges"
    - "A skip condition computed TWICE - in BeforeDiscovery for -Skip: and again in BeforeAll for the body - because the two phases do not share a scope"

key-files:
  created:
    - src/Hephaestus/Public/New-HDTLocalContentProvider.ps1
    - src/Hephaestus/Public/New-HDTSmbContentProvider.ps1
    - src/Hephaestus/Public/New-HDTSmbService.ps1
    - src/Hephaestus/Public/Set-HDTShareCredential.ps1
    - src/Hephaestus/Public/Get-HDTShareCredential.ps1
    - src/Hephaestus/Public/Get-HDTShareAccessRule.ps1
    - src/Hephaestus/Public/Test-HDTShareAcl.ps1
    - src/Hephaestus/Private/Get-HDTShareSecretKey.ps1
    - src/Hephaestus/Private/Protect-HDTShareSecret.ps1
    - src/Hephaestus/Private/Unprotect-HDTShareSecret.ps1
    - tests/helpers/HDTTestTools/tools/Get-HDTSlowSuiteSkipViolation.ps1
    - tests/unit/New-HDTFakeContentProvider.Tests.ps1
    - tests/unit/New-HDTLocalContentProvider.Tests.ps1
    - tests/unit/New-HDTFakeSmbService.Tests.ps1
    - tests/unit/New-HDTSmbContentProvider.Tests.ps1
    - tests/unit/Set-HDTShareCredential.Tests.ps1
    - tests/unit/Test-HDTShareAcl.Tests.ps1
    - tests/unit/Get-HDTSlowSuiteSkipViolation.Tests.ps1
    - tests/contract/ContentProvider.Contract.Tests.ps1
    - tests/contract/SlowSuiteSkip.Contract.Tests.ps1
    - tests/integration/SmbContentProvider.Integration.Tests.ps1
    - tests/fixtures/slowskip/ (4 files)
    - docs/share-account.md
  modified:
    - src/Hephaestus/Public/New-HDTServiceCatalog.ps1
    - src/Hephaestus/Public/Get-HDTOperatingSystem.ps1
    - src/Hephaestus/Private/ConvertTo-HDTOperatingSystemCatalog.ps1
    - src/Hephaestus/Public/Steps/Invoke-HDTApplyImageStep.ps1
    - src/Hephaestus/Hephaestus.psd1
    - tests/helpers/HDTFakes/HDTFakes.psm1
    - tests/helpers/HDTFakes/HDTFakes.psd1
    - tests/helpers/HDTTestTools/HDTTestTools.psd1
    - tests/helpers/README.md
    - tests/unit/New-HDTServiceCatalog.Tests.ps1
    - tests/unit/FakeJournal.Tests.ps1
    - tests/unit/Get-HDTOperatingSystem.Tests.ps1
    - tests/unit/Invoke-HDTApplyImageStep.Tests.ps1
    - tests/unit/BuildScript.Tests.ps1
    - tests/integration/ImageService.Integration.Tests.ps1
    - build.ps1
    - .gitignore
    - docs/DESIGN.md

key-decisions:
  - "The error id travels in the MESSAGE, not in an ErrorRecord. Probed on both engines: a refusal thrown from a PowerShell class method keeps FullyQualifiedErrorId, the same refusal from a ScriptMethod on a pscustomobject arrives as ScriptMethodRuntimeException and loses it. Since the fake is a class and every real adapter is a pscustomobject, the message is the only carrier both shapes share"
  - "Path segments are collapsed by hand rather than by [IO.Path]::GetFullPath, which returns '\\\\server\\Share\\Windows' for '\\\\server\\Share\\..\\..\\Windows' on BOTH engines - it clamps the escape instead of reporting it, so a UNC provider using it would have accepted every path that tried to climb out"
  - "The Smb provider maps and then READS THE ESTABLISHED IDENTITY BACK. A successful New-SmbMapping does not mean the deployment account authenticated; the connection row's UserName is the only evidence, and a guest, anonymous or empty identity throws HDTSecurityError AND tears the mapping down"
  - "The provider judges the connection row for the share it mapped. A real loopback mapping returned TWO rows - the share and IPC$ - so taking row[0] would make the refusal depend on enumeration order"
  - "A dialect below 3.0 warns rather than refuses. A 2.1 file server is legitimate and refusing it would be HDT deciding a fleet's infrastructure for it. SMB1 is refused outright"
  - "EnableInsecureGuestLogons is REPORTED, never changed. Turning a machine's security setting off to make a deployment work is the opposite of what the check is for"
  - "The share secret is AES over a key that is a constant in the module - obfuscation, and the file says so in a warning field of its own. NOT DPAPI, because DPAPI is user- and machine-bound and this file must be readable inside WinPE on a machine that has never seen the one that wrote it"
  - "Test-HDTShareAcl ignores rules granted to anybody but the deployment account. BUILTIN\\Administrators holds FullControl on very nearly every share there has ever been, and judging it would make Compliant unreachable and the check ignorable"
  - "build.ps1's integration task WARNS about absent staged media instead of throwing. The throw meant one missing 4 GB file stopped the whole task, so the files that skip themselves correctly never ran either"
  - "No VM in this phase deploys over SMB - PROJECT.md rule 2 (HDT VMs live on the isolated 'HDT Lab' switch) plus SPIKES S6 (a VM there cannot reach a share on the host). The Smb provider is proven against fakes and host-to-host on loopback, and nowhere else"

# Metrics
duration: 200min
completed: 2026-08-13
---

# Phase 05 Plan 02: The Content Provider, the Share Credential and the 04-02 Seam Summary

**DESIGN 6's provider interface with three implementations that satisfy one contract, an SMB transport that refuses a share it authenticated to as a guest, the deployment secret in one gitignored obfuscated file that says so about itself, and the seam 04-02 marked — closed and its comments rewritten into the present tense.**

## Performance

- **Duration:** ~200 min
- **Tasks:** 3 of 3
- **Files created:** 26 · **Files modified:** 18
- **Unit + contract:** **4275 passed / 0 failed / 54 skipped** under pwsh 7.5.8 (`./build.ps1 -Task ci`, exit 0); **4130 passed / 0 failed / 199 skipped** under Windows PowerShell 5.1.26100.8655 (`./build.ps1 -Task test`, exit 0).
- **Integration:** **59 passed / 0 failed / 18 skipped** (`./build.ps1 -Task integration`, elevated, exit 0).
- PSScriptAnalyzer: **0 diagnostics across 303 files.**

New tests, counted per file under pwsh 7:

| File | Tests |
|---|---|
| `tests/unit/New-HDTSmbContentProvider.Tests.ps1` | 41 |
| `tests/contract/ContentProvider.Contract.Tests.ps1` | 36 (12 × 3 implementations) |
| `tests/unit/Test-HDTShareAcl.Tests.ps1` | 30 |
| `tests/unit/New-HDTFakeContentProvider.Tests.ps1` | 23 |
| `tests/unit/New-HDTLocalContentProvider.Tests.ps1` | 23 |
| `tests/unit/Set-HDTShareCredential.Tests.ps1` | 20 |
| `tests/unit/New-HDTFakeSmbService.Tests.ps1` | 18 |
| `tests/integration/SmbContentProvider.Integration.Tests.ps1` | 16 |
| `tests/unit/Get-HDTSlowSuiteSkipViolation.Tests.ps1` | 12 |
| `tests/contract/SlowSuiteSkip.Contract.Tests.ps1` | 3 |
| **New files, unit + contract** | **206** |
| **New file, integration** | **16** |

The unit + contract suite grew from **3997 to 4275 — 278 tests** — the difference
between that and the 206 above being rows added to existing files:
`FakeJournal.Tests.ps1` (two new fakes × its seven `-ForEach` assertions),
`New-HDTServiceCatalog`, `Get-HDTOperatingSystem`, `Invoke-HDTApplyImageStep` and
`BuildScript`.

## Task Commits

| # | Task | RED | GREEN |
|---|---|---|---|
| 1 | IContentProvider, the fake, Local, the S9.15 guard | `16228eb` (93 failing) | `62674d2` |
| 2a | the fake SMB service | `4c0a39b` (24 failing) | `0228300` |
| 2b | the Smb provider and its refusals | `09957b5` (52 failing) | `8156fe9` |
| 2c | the credential and the ACL check | `296e991` (49 failing) | `1309d1c` |
| 2d | DESIGN 6.3 correction | — | `7f79e1d` |
| 2e | docs/share-account.md | — | `0a7e739` |
| 2f | the real loopback integration | `1df1242` | (same commit — see below) |
| 3 | the 04-02 seam | `7496fbb` (8 failing) | `41f28dc` |
| — | SPIKES S9.15b applied to this plan's guards | — | `1cbd132` |

Every RED commit was **watched failing for the right reason** — `CommandNotFoundException`, a missing `Content` property, `NamedParameterNotFound`, and in one case `Get-Help` resolving `New-HDTSmbContentProvider` to **`New-HDTFakeSmbService`**, which is exactly the fuzzy-match trap helpers README section 12 records and is why every help test asserts `$help.Name` first.

`1df1242` carries the integration file together with three fixes it forced, because they were discovered by running it and are meaningless apart from it.

---

## What 05-03, 05-04 and 05-05 are written against

### `IContentProvider` — five members, and the exact semantics

```
ResolveContent([string] $RelativePath) -> [string]   an absolute path a step can use
TestContent([string] $RelativePath)    -> [bool]
CopyContent([string] $RelativePath, [string] $Destination) -> [string] the destination
Connect()      -> [string]   the root that is now reachable
Disconnect()   -> void
```

plus `Root`, `ServiceName` (`'ContentProvider'`), `Operations`, `Journal`,
`IsConnected` and `GetOperationName()`.

**Connect and Disconnect are on the interface even where they do nothing.** A
provider whose implementations differ in shape is a provider a step has to branch
on, and a step that branches on its transport is the parallel code path DESIGN 6.2
exists to prevent. On `Local`, `Connect` earns its place anyway: it verifies the
root exists, so a USB stick that was never inserted fails there rather than in the
middle of an apply.

Resolution, identical in all three:

| Input | Answer |
|---|---|
| `sources\install.wim` | `Root\sources\install.wim` |
| `sources/install.wim` | same — both separators accepted |
| `D:\Captures\surface.ffu` (rooted) | returned **unchanged** (DESIGN 9.3) |
| `OperatingSystems\..\Applications\x` | `Root\Applications\x` — a `..` that stays inside is fine |
| `..\..\Windows\System32\config\SAM` | **refused**, `System.ArgumentException`, message begins `HDTConfigurationError:` and names the path and the root |
| `''` or `'   '` | **refused**, same shape |

`ResolveContent` **does not check existence** — `TestContent` is that question.
`CopyContent` throws `System.IO.FileNotFoundException` for a source that is not
there, creates the destination's parent directory, and returns the destination.
Every call records before it can throw; `-Journal` is honoured.

### Where the error id lives, and why

**Probed on pwsh 7.5.8 and Windows PowerShell 5.1.26100.8655:** a refusal thrown
as an `ErrorRecord` from a **PowerShell class method** reaches the caller with
`FullyQualifiedErrorId = 'HDTConfigurationError'`; the identical throw from a
**`ScriptMethod` on a pscustomobject** arrives as `ScriptMethodRuntimeException`
and the id is gone. The fake is a class (helpers README section 2) and every real
adapter is a pscustomobject (F1), so **the id is written into the sentence**,
where both shapes carry it, and the contract asserts the exception *type* after
unwrapping to the innermost exception (README section 5).

### The '..' trap that would have made the UNC provider unsafe

```
[IO.Path]::GetFullPath('\\server\Share\..\..\Windows')  ->  \\server\Share\Windows
[IO.Path]::GetFullPath('C:\Share\..\..\Windows')        ->  C:\Windows
```

Both engines. **On a UNC root `GetFullPath` clamps the escape instead of
reporting it**, so a provider that detected escapes by comparing the resolved path
against the root would have accepted every `..` a UNC share was given. Segments
are therefore walked by hand — a stack that refuses to pop past empty — which is
identical in the fake, `Local` and `Smb` and is why the contract's escape test
passes on all three.

### `New-HDTSmbService` — the adapter, and the connection row shape

```
NewMapping([string] $RemotePath, [string] $UserName, [string] $Password) -> void
RemoveMapping([string] $RemotePath)                                      -> void
GetConnection([string] $ServerName) -> [object[]] rows of
                                       { ServerName, ShareName, UserName,
                                         Dialect, Encrypted, Signed }
GetClientConfiguration() -> { EnableInsecureGuestLogons, RequireSecuritySignature }
```

over `New-SmbMapping -RemotePath -UserName -Password -Persistent:$false`,
`Remove-SmbMapping -Force`, `Get-SmbConnection -ServerName` and
`Get-SmbClientConfiguration`. `SmbShare` is present in WinPE (DESIGN 5.1), which
is why this is the mechanism and not `net use`.

**It carries exactly one branch, and it is named rather than hidden:**
`New-SmbMapping` refuses an empty `-UserName`, so a connection made as the
caller's own identity omits the two parameters instead of passing them empty.
The rule that adapters stay branch-free exists because they are not unit tested;
this one is exercised for real by the integration file, which is the same bargain
README section 11 records for `New-HDTScriptInvoker`.

**The password is recorded as `<redacted>`** on the adapter and on the fake.

### `New-HDTSmbContentProvider` — the exact refusal list

`New-HDTSmbContentProvider -Root <unc> [-Credential] [-AllowAnonymous] [-SmbService] [-FileSystem] [-Journal]`

**Before it maps** — and when it refuses here it has called nothing at all, which
a test asserts by requiring the SMB service's journal to be empty:

| # | Condition | Class | Message begins |
|---|---|---|---|
| 1 | `Root` is not UNC | `System.ArgumentException` | `HDTConfigurationError:` |
| 2 | a credential with an empty password | `System.Security.SecurityException` | `HDTSecurityError:` |
| 3 | no credential and no `-AllowAnonymous` | `System.Security.SecurityException` | `HDTSecurityError:` |
| 4 | no credential, and `EnableInsecureGuestLogons` is `$true` | `System.Security.SecurityException` | `HDTSecurityError:` |

**After it maps**, reading `GetConnection(<server>)` back and judging the row
whose `ShareName` matches the share it mapped:

| # | Condition | Class | Mapping torn down |
|---|---|---|---|
| 5 | no connection row at all | `System.InvalidOperationException` (`HDTEnvironmentError:`) | yes |
| 6 | `UserName` empty, `Guest`, `*\Guest`, or `ANONYMOUS LOGON` (case-insensitive) | `System.Security.SecurityException` (`HDTSecurityError:`) | **yes** |
| 7 | `Dialect` begins `1.` | `System.Security.SecurityException` (`HDTSecurityError:`) | yes |
| 8 | `Dialect` major below 3 | **warning**, continues | — |
| 9 | `Encrypted` is `$false` | **warning** (once), continues | — |

`Connect()` is re-entrant — twice maps once. `Disconnect()` calls
`RemoveMapping` and **never throws**; it runs in a `finally`.

### The credential

```
Set-HDTShareCredential -WorkspaceRoot <string> -Credential <pscredential> [-FileSystem]  # SupportsShouldProcess
Get-HDTShareCredential -WorkspaceRoot <string> [-FileSystem]  -> { UserName, Password }
```

Written to `<workspace>\Control\share-credential.json`, built with
`Get-HDTWorkspacePath -Kind Control` and never a literal (asserted by reading the
source and refusing `'Control'` in it):

```json
{
  "schemaVersion": 1,
  "username": "CONTOSO\\svc-hdt-deploy",
  "password": "<base64 of a 16-byte IV followed by AES-CBC ciphertext>",
  "warning": "This password is obfuscated, not encrypted: the key is a constant in the Hephaestus module, so anyone who can read this file - or the boot image, the ISO or the Boot folder that carry it - can recover the password. ..."
}
```

**The protection is obfuscation and is documented as such** — in the file itself,
in the help of all three private crypto functions, and in `docs/share-account.md`.
The key is `SHA-256('Hephaestus Deployment Toolkit share credential obfuscation
key v1')`, a constant in the module. **Not DPAPI**: DPAPI is user- and
machine-bound and this file must be readable inside WinPE on a machine that has
never seen the one that wrote it, which is the entire reason the credential is
embedded. `Control/share-credential.json` and `**/Control/share-credential.json`
are gitignored — `git check-ignore -v samples/workspace/Control/share-credential.json`
reports a match.

### `Test-HDTShareAcl` — the result shape

```
Test-HDTShareAcl -WorkspaceRoot <string> -Identity <string> -AccessRule <hashtable>
    -> { Compliant [bool]; Finding [rows of { Path, Severity, Message }] }
```

`-AccessRule` maps a folder relative path (`'.'` or `''` is the root) to the rows
`Get-HDTShareAccessRule` returned, or `$null` where the ACL could not be read.
Findings, sorted **Critical first**:

| Condition | Severity |
|---|---|
| the deployment identity is an admin group (`Domain Admins\|Enterprise Admins\|Administrators`) | Critical, quoting DESIGN 6.3's "a domain admin credential in a boot image is a domain compromise" |
| `FullControl` anywhere, including `Logs\` | Critical |
| no read at the workspace root | Critical |
| write outside `Logs\` and `Captures\` | Warning |
| an ACL that could not be read | Information |

`Compliant` is `$true` only when nothing above `Information` was found. It
**never throws and never blocks a build** — DESIGN 6.3 says warn, and a build
that died on one unreadable ACL is a check somebody turns off. The folder set it
recognises is read from `Get-HDTWorkspacePath`'s `ValidateSet` at run time, and a
test asserts `docs/share-account.md` names every one of them, so the page and the
checker cannot drift apart.

### What loopback SMB actually negotiated on this host

Printed by the integration run, on `\\localhost\HDTIntegration$`, as
`Lap-Ammso01\Itamartz`:

```
SMB loopback negotiated: dialect=3.1.1 encrypted=False signed=True user=Lap-Ammso01\Itamartz
SMB client: EnableInsecureGuestLogons=False RequireSecuritySignature=False
```

So **rule 9 fires for real** — the unencrypted warning is emitted by the actual
provider against an actual connection, not only against a fake. Loopback SMB is
signed and unencrypted on Windows 11 26100.

`Get-SmbConnection -ServerName localhost` returned **two rows** — the share and
`IPC$` — which is why the provider selects by `ShareName`.

### The seam, closed

`Get-HDTOperatingSystem -Content <provider>` and
`ConvertTo-HDTOperatingSystemCatalog -Content <provider>`: given a provider, the
projected `ImagePath` is what it answered for the path relative to **its own**
root (the OS folder is made relative to `$Content.Root` first, so
`sources\install.wim` is asked for as
`OperatingSystems\<id>\sources\install.wim`); given none, the behaviour is
byte-for-byte what it was, which the compatibility test holds in place. A rooted
`sourcePath` is untouched either way. A provider refusal is re-raised as
`HDTConfigurationError` naming `os.yaml`, because a `sourcePath` that climbs out
of the workspace is a mistake in that file.

`Invoke-HDTApplyImageStep` passes `$Context.Service.Content`. **That is the whole
change to step logic** — two lines, in a diff of 19 insertions of which 12 are
help text. The evidence is
`It 'produces an identical operation list under Local and under Smb'`: the same
step, the same `os.yaml` and the same fake image service run twice through a
**shared journal**, once over `New-HDTLocalContentProvider` rooted at `C:\Share`
and once over `New-HDTSmbContentProvider` rooted at `\\server\Share`, asserting
that the ordered list of every service call is equal —

```
FileSystem.TestPath, FileSystem.ReadAllText, Clock.GetUtcNow,
ContentProvider.ResolveContent, FileSystem.AppendAllText, ...,
ImageService.ApplyImage, ...
```

— while the arguments differ (`C:\Share\...\install.wim` versus
`\\server\Share\...\install.wim`). The test asserts **both**, so it says which of
the two properties it means.

`Select-String -Path src/Hephaestus -Recurse -Pattern 'SEAM M4 REPLACES'` returns
nothing; all three files now describe what is.

---

## Deviations from Plan

### Auto-fixed issues

**1. [Rule 3 — Blocking] `./build.ps1 -Task integration` refused to start without the staged media**

- **Found during:** task 2, the first integration run.
- **Issue:** `C:\HDTLab\media` is **gone from this machine** (see Environment
  findings below). `Invoke-HDTIntegrationTest` threw on the missing
  `install.wim` before running anything, so the whole task — including a new
  file that needs no Windows image at all — could not run.
- **Fix:** the media precondition warns and names what will skip itself;
  elevation is still a hard refusal. A test in `BuildScript.Tests.ps1` was
  written first and asserts the new shape.
- **Files:** `build.ps1`, `tests/unit/BuildScript.Tests.ps1` · **Commit:** `1df1242`

**2. [Rule 1 — Bug] `ImageService.Integration.Tests.ps1` failed twice for an absent file instead of skipping**

- **Found during:** the same run. `Describe 'IImageService reading the real
  media'` had no skip, while the slow `Describe` beside it did.
- **Fix:** a `$script:skipMedia` computed in `BeforeDiscovery`, a printed
  warning, and `-Skip:` on that `Describe`.
- **Commit:** `1df1242`

**3. [Rule 1 — Bug] the new integration file died in DISCOVERY on its first run through `build.ps1`**

- **Issue:** `-Skip:` on a `Context` is bound **while Pester discovers**, so the
  `$script:skipSmb` this file set in `BeforeAll` did not exist there and
  StrictMode killed discovery: *"The variable '$skipSmb' cannot be retrieved"*.
  **SPIKES S9.15 from the other side** — and it happened in the very plan that
  added the guard against S9.15, which is worth recording rather than tidying
  away. The guard scans for the reverse direction and could not have caught it.
- **Fix:** the condition is computed **twice** — in `BeforeDiscovery` for
  `-Skip:` and again in `BeforeAll` for the body — and the run-phase half of the
  question (was the share actually created) is handled by `Set-ItResult -Skipped`
  in a `BeforeEach`.
- **Commit:** `1df1242`

**4. [Rule 1 — Bug] the provider judged whichever connection row came back first**

- **Found during:** the same run — a real loopback mapping returns two rows, the
  share and `IPC$`. Selecting by index made the guest refusal depend on
  enumeration order.
- **Fix:** the row whose `ShareName` matches the mapped share is the one judged,
  with a unit test written first.
- **Commit:** `1df1242`

**5. [Rule 2 — Correctness] SPIKES S9.15b applied to this plan's own guards**

- The developer recorded S9.15b mid-plan: `@($null).Count` is `1`, so
  `@($x).Count | Should -BeGreaterThan 0` passes for a collection that is not
  there. Every guard this plan added now asserts on something coercion cannot
  fabricate — the slow-suite contract names three files that must be in its scan,
  the deliberate-fixture check names the variable it must report, and the ACL
  tests name the severity they expect.
- **Commit:** `1cbd132`

### Additions beyond the plan's file list

- **`Get-HDTShareSecretKey.ps1`, `Protect-HDTShareSecret.ps1`,
  `Unprotect-HDTShareSecret.ps1`** — three private functions rather than the
  crypto written twice inside `Set-` and `Get-HDTShareCredential`. Covered by
  those commands' round-trip and not-plain-text tests.
- **`tests/fixtures/slowskip/`** — four fixtures for the S9.15 scanner, one per
  case, including a deliberately unparseable file that proves the line-scan
  fallback.

### Deliberately not done

- **`ConvertTo-SecureString -AsPlainText` appears nowhere in the new tests.**
  PSScriptAnalyzer refuses it outright (`PSAvoidUsingConvertToSecureStringWithPlainText`,
  an *Error* under this repo's settings), so every test credential is built a
  character at a time with `AppendChar`.
- **The fake's `NewMapping` third parameter is named `$Secret`, not `$Password`.**
  A PowerShell class method cannot carry a `SuppressMessageAttribute`, and the
  analyzer fires on the `UserName`/`Password` pair; the real adapter suppresses
  the same two rules with a justification instead.

---

## Environment findings, reported rather than tidied away

- **`C:\HDTLab\media` no longer exists on this host.** PROJECT.md lists the
  Windows 11 and Server 2025 source trees there as staged (~11 GB). Their absence
  is why 15 of the 18 skipped integration tests skip, and why
  `ImageService.Integration.Tests.ps1`'s media rows and
  `ImageService.Contract.Tests.ps1`'s real row do not run. **Nothing in this plan
  deleted them** — this plan's only deletes are a per-run GUID folder under
  `C:\HDTLab\scratch\smb` and the throwaway share, both by explicit
  `-LiteralPath` / name. Restaging from the ISOs in
  `…\Dropbox\System\_FORWORK\SCCM\HydrationKitWS2025\ISO\` is a prerequisite for
  05-04's boot image work and for any further imaging integration.
- **Two firewall rules named `HDT Lab SMB (445) inbound` and `HDT Lab ICMP
  inbound` exist on this host and predate this plan** (SPIKES S6 records creating
  a scoped 445 rule by hand). **This plan opened no port** — the integration file
  uses `\\localhost`, which never leaves the machine — and it removed none
  either, because they are not its to remove.
- After every run: `Get-SmbShare -Name 'HDTIntegration$'` reports nothing,
  `Get-SmbMapping` reports nothing, and `CM01` and `DC01` are `Off` and untouched.

## The gap this plan does not close, stated plainly

**No VM deployed over SMB in this phase, and none could have.** PROJECT.md rule 2
puts every HDT test VM on the isolated `HDT Lab` switch, and SPIKES S6 records
that a VM there **cannot reach a share on the host**. Moving one to a switch that
could would break the rule that keeps HDT's PXE work away from CM01's PXE
responder — the rule exists precisely to prevent the two labs colliding.

So the Smb provider is proven in exactly two places:

1. **Every decision** — the four pre-map refusals, the identity read-back, the
   guest / anonymous / empty-user / SMB1 refusals, the teardown of a refused
   mapping, re-entrancy, the two warnings — **against `New-HDTFakeSmbService`**,
   41 tests.
2. **The mechanism** — `New-SmbMapping`, `Get-SmbConnection`,
   `Get-SmbClientConfiguration`, `Remove-SmbMapping`, plus the credential
   round-trip and the ACL adapter — **host-to-host on loopback**, 16 tests.

**A real guest connection was never produced**, and the integration file says so
in a comment: staging one means enabling `EnableInsecureGuestLogons` on the
developer's machine, which is a security posture change no test gets to make.
That refusal is proven at unit level only. Nothing here demonstrates a PXE-booted
machine reaching a real deployment share with the deployment account — that
remains unproven until a phase with an environment that permits it.

## Self-Check: PASSED
