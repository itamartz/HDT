# tests/helpers

Conventions every test double follows. Phases 02-09 add `IDiskService`,
`IImageService`, `IContentProvider`, `IRegistryService` and `ILsaService` fakes
(PROJECT constraint 4); they must look like the two that already exist, because
the benchmark test — a full multi-group sequence with reboots, executing
end-to-end against fakes and asserting the exact ordered operation list — only
works if every fake records the same way.

## 1. Where things live

| Path | Holds |
|---|---|
| `tests/helpers/HDTTestTools/` | Analysis helpers used by `build.ps1` and the contract tests: source discovery, name validation, the 5.1 compatibility scanner, the MDT scanner, the Pester configuration |
| `tests/helpers/HDTFakes/` | Hand-written service doubles — one class per service, all inline in `HDTFakes.psm1` |
| `tests/fixtures/` | Captured data the fakes are seeded from, and deliberately invalid source the scanners are pointed at. See `tests/fixtures/README.md` |

The fakes that exist, and the real adapter each is the double for:

| Fake | Interface | Real adapter | Seeded with |
|---|---|---|---|
| `New-HDTFakeFileSystem` | `IFileSystem` | phase 04 | `-File`, `-Directory` |
| `New-HDTFakeCimProvider` | `ICimProvider` | `New-HDTCimProvider` | `-Instance`, `-FixturePath`, `-NamespaceFixturePath` |
| `New-HDTFakeRegistryService` | `IRegistryService` (read subset; phase 03 adds the writes) | `New-HDTRegistryService` | `-Value` |
| `New-HDTFakeEnvironmentProvider` | `IEnvironmentProvider` | `New-HDTEnvironmentProvider` | `-Variable` |
| `New-HDTFakeScriptInvoker` | `IScriptInvoker` | `New-HDTScriptInvoker -Root` | `-Result` |

Both helper modules are ordinary modules with a manifest, an explicit
`FunctionsToExport`, `PowerShellVersion = '5.1'` and
`CompatiblePSEditions = @('Desktop', 'Core')`.

## 2. Factory rule

Every fake is created by `New-HDTFake<Service>`. The class is an implementation
detail.

```powershell
$fs = New-HDTFakeFileSystem -File @{ 'C:\ws\rules.yaml' = 'schemaVersion: 1' }
$cim = New-HDTFakeCimProvider -FixturePath ./tests/fixtures/cim
```

Two rules, both load-bearing:

- **Define classes inline in `HDTFakes.psm1`**, never in dot-sourced `.ps1`
  files. Class definitions that arrive by dot-sourcing are the known-flaky path
  across `-Force` re-imports.
- **Never write the class name as a type literal in a test.** No
  `[HDTFakeFileSystem]::new()`, no `-is [HDTFakeCimProvider]`, no
  `[HDTFakeFileSystem] $fs` parameter. A type literal binds to whichever dynamic
  assembly was loaded first, so it breaks the moment the module reloads. Go
  through the factory.

## 3. Naming

Test helpers and fakes obey `Verb-HDTNoun` exactly like engine code
(DESIGN 15.1), and the naming contract enforces it over them —
`Get-HDTSourceFile` includes `tests/helpers/**`.

Class **members** are exempt and are excluded from the naming contract by
`Get-HDTSourceFunction`: a method name is fixed by the service contract
(`IFileSystem.TestPath`), not by DESIGN 15.1, which names commands.

## 4. Recording

Every fake exposes:

- `[System.Collections.ArrayList] $Operations` — one `[pscustomobject]` per call:

  | Property | Meaning |
  |---|---|
  | `Sequence` | 1-based call number |
  | `Operation` | the method name |
  | `Arguments` | `object[]` of the arguments, in declaration order |

- `[string[]] GetOperationName()` — the ordered operation names.

Rules:

- **Read-only methods record too.** `TestPath`, `ReadAllText`, `GetChildItem`,
  `GetLength`, `GetInstance` all append. Provenance and query-order assertions
  need them.
- **Record before the method can throw.** Query order is evidence about what the
  code under test *tried*, not only about what succeeded.
- **Seeding is not an operation.** Anything the factory or an `Add*`/`Seed*`
  method does is invisible to `$Operations`, so the first recorded call is the
  first thing the code under test did.

The canonical ordered-operations assertion, copied from
`tests/unit/New-HDTFakeFileSystem.Tests.ps1` — this is the DESIGN 12.2.1 shape
in miniature, and the template every later fake copies:

```powershell
It 'returns operation names in order from GetOperationName' {
    $fs = New-HDTFakeFileSystem
    $fs.CreateDirectory('C:\ws')
    $fs.WriteAllText('C:\ws\a.txt', 'x')
    $fs.TestPath('C:\ws\a.txt') | Out-Null
    $fs.ReadAllText('C:\ws\a.txt') | Out-Null

    $fs.GetOperationName() | Should -Be @('CreateDirectory', 'WriteAllText', 'TestPath', 'ReadAllText')
}
```

## 5. Error parity

A fake throws the **same exception type** the real adapter throws, and the
contract test asserts that type **after unwrapping to the innermost exception**:

```powershell
$record = $null
try { $script:invoker.Invoke($missing, @{}) } catch { $record = $_ }

$record | Should -Not -BeNullOrEmpty
$inner = $record.Exception
while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
$inner | Should -BeOfType ([System.IO.FileNotFoundException])
```

**Why the loop, and not `Should -Throw -ExceptionType`.** Where an exception is
thrown from decides how the caller sees it, and the two implementations of a
contract throw from different places:

| Thrower | What the caller catches |
|---|---|
| PowerShell class method (every fake) | the original type, e.g. `System.IO.FileNotFoundException` |
| `ScriptMethod` on a `pscustomobject` (every real adapter — section 11) | `System.Management.Automation.MethodInvocationException`, whose `InnerException` is `System.Management.Automation.RuntimeException`, whose `InnerException` is the original |

So `-ExceptionType` passes against a fake and **fails against a real adapter**,
which is exactly the boundary a contract has to survive. The loop is a no-op for
the fake and unwraps twice for the adapter, so one assertion serves both rows.
Verified on pwsh 7.5.8 and Windows PowerShell 5.1.26100.8655.

Assertions about a *message* need no unwrapping: `MethodInvocationException.Message`
embeds the inner message, so `Should -Throw -ExpectedMessage '*...*'` works
against both. A fake's own unit test, which only ever faces the class, may keep
using `-ExceptionType`.

`FakeFileSystem` throws `FileNotFoundException`, `DirectoryNotFoundException`,
`UnauthorizedAccessException` and `IOException` exactly where `System.IO` would;
`FakeScriptInvoker` throws `FileNotFoundException` where the real invoker finds
no script.

Messages are free to differ, and should still be useful — `FakeCimProvider`
names the missing class the way `Get-CimInstance` does **not**, because a vaguer
message would hide a typo in a fact gatherer. See F7 in section 11.

## 6. Contract first

Every service gets `tests/contract/<Service>.Contract.Tests.ps1` holding the
`$script:HDTImplementation` registry **at discovery time** — Pester 5 expands
`-ForEach` while discovering, so a registry built in `BeforeAll` produces zero
test cases.

```powershell
$script:HDTImplementation = @(
    @{ Name = 'FakeCimProvider'; Factory = { param($RepositoryRoot) New-HDTFakeCimProvider -FixturePath (Join-Path -Path $RepositoryRoot -ChildPath 'tests/fixtures/cim') } }
)

Describe 'ICimProvider contract: <Name>' -ForEach $script:HDTImplementation {
    BeforeEach { $script:cim = & $Factory $script:repoRoot }
    ...
}
```

The factory is invoked as `& $Factory $repositoryRoot`. It is *passed* the root
rather than closing over it because a discovery-phase variable does not survive
into the run phase; declare `param($RepositoryRoot)` only if you use it.

Adding a real adapter later is one row, not a new test file:

```diff
 $script:HDTImplementation = @(
     @{ Name = 'FakeCimProvider'; Factory = { param($RepositoryRoot) New-HDTFakeCimProvider -FixturePath (Join-Path -Path $RepositoryRoot -ChildPath 'tests/fixtures/cim') } }
+    @{ Name = 'CimProvider';     Factory = { New-HDTCimProvider } }
 )
```

If the real adapter cannot pass a contract test, the contract was wrong — fix
the contract and the fake together, never fork the test.

## 7. Fakes never do real I/O

Every fake gets an explicit "never touches the real X" test. `FakeFileSystem`
writes to `C:\HDTLab\does-not-exist\x.txt` and then asserts `Test-Path` is
`$false` on the real disk; `FakeCimProvider` asserts that an unseeded
`Win32_OperatingSystem` — a class that certainly exists on the host — throws
rather than returning live data.

Without that test a fake can silently fall through to the real machine, and
every test above it becomes a lie.

## 8. Fixture honesty

Seed data is captured from real machines and sanitised, never invented
(DESIGN 12.2.3). `tests/fixtures/README.md` holds the capture command and the
sanitisation table. A fake may ship a convenient default shape, but the moment a
test asserts on a property value, that value comes from a fixture.

## 9. The self-check fixtures are deliberately red

`tests/selfcheck/` holds two files that exist to be *observed*, not to pass:

| File | Behaviour | Why |
|---|---|---|
| `DeliberateFailure.Tests.ps1` | one `It` that always fails | proves the harness catches a failing test |
| `DeliberatePass.Tests.ps1` | one `It` that always passes | proves the harness does not simply report failure for everything |
| `tests/fixtures/analyzer/AnalyzerBait.ps1` | four PSScriptAnalyzer violations | proves analyzer violations are detected, and that `PSUseCompatibleSyntax` is really targeting 5.1 |

**Do not "fix" any of them.** `build.ps1 -Task selfcheck` fails if the failing
one stops failing.

Two exclusions keep them harmless, and both must stay true:

- `tests/selfcheck` is **never in `Run.Path`** for `build.ps1 -Task test`. The
  self-check runs those files itself, once in-process and once in a child
  process with `Run.Exit` set, so the real exit-code path CI depends on is
  observed rather than assumed.
- `tests/fixtures/**` is excluded from `Get-HDTSourceFile`, so the bait is never
  linted, never name-checked and never parsed. That last one is load-bearing:
  the bait contains `??`, which is a **parse error** under Windows PowerShell
  5.1. Nothing may dot-source or `ParseFile` it — only `Invoke-ScriptAnalyzer`
  under pwsh 7 ever reads it.

`tests/unit/HarnessSelfCheck.Tests.ps1` asserts both exclusions, so a future
change that widens `Run.Path` or `Get-HDTSourceFile` turns the suite red instead
of quietly poisoning it.

## 10. Mock is reserved for the adapter boundary

Services get hand-written fakes; `Mock` is only for adapters — `Invoke-HDTDism`
and friends (DESIGN 12.2.3). Adapters stay branch-free precisely because they
are not unit tested, so mocking them is bounded and visible. Mocking a *service*
instead of faking it produces unreadable failures and couples the test to the
call shape rather than to the behaviour.

## 11. Real adapters are pscustomobjects, not classes

The first four real adapters landed in plan 02-01 (`New-HDTCimProvider`,
`New-HDTRegistryService`, `New-HDTEnvironmentProvider`, `New-HDTScriptInvoker`).
Everything below was probed on this machine under **both** pwsh 7.5.8 and
Windows PowerShell 5.1.26100.8655. They are facts. Do not re-derive them, and do
not "tidy" the code shapes they justify.

**F1. A real adapter is a `[pscustomobject]` with `ScriptMethod` members, not a
PowerShell class.** Classes dot-sourced from `Public/*.ps1` or `Private/*.ps1`
into `Hephaestus.psm1` are the known-flaky path across `-Force` re-imports (see
`01-03-SUMMARY.md`). A `pscustomobject` carrying `ScriptMethod` members
duck-types to the same contract, reloads cleanly, and behaves identically on both
engines. The **fakes stay classes** — they are never dot-sourced, they are
defined inline in `HDTFakes.psm1` (section 2).

**F2. `Get-Member -MemberType Method` does NOT list a `ScriptMethod`.** Every
"exposes every method the contract requires" assertion therefore uses:

```powershell
$method = @($service | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })
```

All five contract files carry that, each with a comment. Removing `ScriptMethod`
turns every real row red.

**F3. A `ScriptMethod` returning an array collapses a single-element array to a
scalar.** `return [object[]] @($x)` gives `-is [System.Array]` = `$false`;
`return , ([object[]] @($x))` gives `$true` for 0, 1 and 28 elements. **The unary
comma is mandatory in every array-returning `ScriptMethod`.** The `ICimProvider`
assertion *returns an array even for a single instance* exists to catch its
absence.

**F4. A `ScriptMethod` cannot be overloaded, and binds optional arguments
positionally.** One `GetInstance` with `param([string] $First, [string] $Second)`
serves both `ICimProvider` overloads: an empty `$Second` means the caller used
the one-argument form, so `$First` is the class and the namespace is `root/cimv2`.

**F7. `Get-CimInstance` does not name the class in its "invalid class" message.**
The message is exactly `Invalid class ` on both engines. The `ICimProvider`
contract requires the name — a vaguer message hides a typo in a fact gatherer,
and 01-03 proved that assertion goes red when the name is removed — so
`New-HDTCimProvider` catches and rethrows with the class and namespace attached.
That is a rethrow with the argument added, not a branch on data, so the adapter
is still dumb.

**F8. An exception thrown inside a `ScriptMethod` reaches the caller wrapped
twice.** See section 5, which is the rule this changed.

**F9. `Describe '<Name>' -ForEach $registry -Skip:$Skip` does NOT skip.** Verified
against Pester 5.7.1: `-Skip` is bound where `Describe` is *called*, before
`-ForEach` binds the row's keys, so `$Skip` is unset there and every row runs. A
row marked `Skip = $true` ran anyway — and silently, which is the whole danger.
Put the skip on a `Context` **inside** the block, where the row's keys are in
scope:

```powershell
Describe 'IRegistryService contract: <Name>' -ForEach $script:HDTImplementation {
    BeforeAll { ... }

    Context 'implementation' -Skip:$Skip {
        BeforeEach { $script:registry = & $Factory $script:repoRoot }
        It '...' { }
    }
}
```

All five contract files use that shape, including the two whose rows never skip
today, so there is one shape to copy and no second, broken one to copy by
mistake. `-Skip:` on a `Describe` with **no** `-ForEach` is fine: the variable is
then a file-scope one evaluated at discovery.

`$IsWindows` does not exist under Windows PowerShell 5.1. Use
`[System.Environment]::OSVersion.Platform -eq 'Win32NT'`.

**F10. PSScriptAnalyzer fails every `New-HDT*` function without a suppression.**
`PSUseShouldProcessForStateChangingFunctions` is a Warning, and
`PSScriptAnalyzerSettings.psd1` sets `Severity = @('Error', 'Warning')` with
`ExcludeRules = @()`, so it breaks `build.ps1 -Task lint` and therefore `-Task ci`.
Every factory — fake and real adapter alike — carries:

```powershell
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Builds a stateless service adapter object; it changes no state.')]
```

**Recording applies to real adapters too.** `New-HDTRegistryService`,
`New-HDTEnvironmentProvider` and `New-HDTScriptInvoker` each expose `$Operations`
and `GetOperationName()` and record before the call can throw, exactly as
section 4 requires of the fakes, so a provenance or query-order assertion in a
contract file holds against either implementation.
