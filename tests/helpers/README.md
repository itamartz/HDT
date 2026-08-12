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
contract test asserts the type, not the message:

```powershell
{ $fs.ReadAllText($missing) } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
```

`FakeFileSystem` throws `FileNotFoundException`, `DirectoryNotFoundException`,
`UnauthorizedAccessException` and `IOException` exactly where
`System.IO` would. Verified on both engines: an exception thrown inside a
PowerShell class method reaches the caller unwrapped, so `-ExceptionType` works
under 5.1 and 7 alike.

Messages are free to differ, and should still be useful — `FakeCimProvider`
names the missing class the way `Get-CimInstance` does, because a vaguer message
would hide a typo in a fact gatherer.

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
