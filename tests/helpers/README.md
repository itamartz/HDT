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
| `tests/helpers/HDTTestTools/` | Analysis helpers used by `build.ps1` and the contract tests: source discovery, name validation, the 5.1 compatibility scanner, the MDT scanner, the slow-suite skip scanner, the Pester configuration |
| `tests/helpers/HDTFakes/` | Hand-written service doubles — one class per service, all inline in `HDTFakes.psm1` |
| `tests/fixtures/` | Captured data the fakes are seeded from, and deliberately invalid source the scanners are pointed at. See `tests/fixtures/README.md` |

The fakes that exist, and the real adapter each is the double for:

| Fake | Interface | Real adapter | Seeded with |
|---|---|---|---|
| `New-HDTFakeFileSystem` | `IFileSystem` | `New-HDTFileSystem` | `-File`, `-Directory`, `-WriteFailure`, `-Hash` |
| `New-HDTFakeClock` | `IClock` | `New-HDTClock` | `-UtcNow`, `-TickMillisecond` |
| `New-HDTFakeCimProvider` | `ICimProvider` | `New-HDTCimProvider` | `-Instance`, `-FixturePath`, `-NamespaceFixturePath` |
| `New-HDTFakeRegistryService` | `IRegistryService` | `New-HDTRegistryService` | `-Value` |
| `New-HDTFakeEnvironmentProvider` | `IEnvironmentProvider` | `New-HDTEnvironmentProvider` | `-Variable` |
| `New-HDTFakeScriptInvoker` | `IScriptInvoker` | `New-HDTScriptInvoker -Root` | `-Result`, `-Transcript` |
| `New-HDTFakeProcessService` | `IProcessService` | `New-HDTProcessService` | `-Result` |
| `New-HDTFakePowerService` | `IPowerService` | `New-HDTPowerService -Command` | nothing |
| `New-HDTFakeLsaService` | `ILsaService` | `New-HDTLsaService` | `-Secret` |
| `New-HDTFakeDiskService` | `IDiskService` | `New-HDTDiskService` | `-Disk`, `-Partition`, `-Volume`, `-FixturePath`, `-Failure` |
| `New-HDTFakeImageService` | `IImageService` | `New-HDTImageService` | `-Image`, `-FixturePath`, `-Failure` |
| `New-HDTFakeContentProvider` | `IContentProvider` | `New-HDTLocalContentProvider`, `New-HDTSmbContentProvider` | `-Root`, `-Content`, `-Failure` |
| `New-HDTFakeSmbService` | `ISmbService` | `New-HDTSmbService` | `-Connection`, `-ClientConfiguration`, `-Failure` |
| `New-HDTFakeWdsService` | `IWdsService` | `New-HDTWdsService` — **never executed anywhere** | `-Image`, `-Failure` |
| `New-HDTFakeBootImageService` | `IBootImageService` | `New-HDTBootImageService` | `-FileSystem`, `-Image`, `-Package`, `-Driver`, `-Failure` |
| `New-HDTFakeRandomNumberGenerator` | `RandomNumberGenerator` (a .NET type, not an HDT service) | — | `-Byte` |

`IRegistryService` is six methods. `TestPath` and `GetValue` are the read subset
fact gathering needs; `NewKey`, `SetValue(path, name, value, type)`,
`RemoveValue` and `RemoveKey(path, recurse)` are the write half the autologon
lifecycle of DESIGN 4.5 runs on. `$type` is a `New-ItemProperty -PropertyType`
name — `String`, `ExpandString`, `DWord`, `QWord`, `Binary`, `MultiString`.

**Removing a value or key that is not there is not an error.** DESIGN 4.5.3's
teardown runs on machines in unknown states, and a teardown that throws on the
first absent value is a teardown that does not finish. `SetValue` creates the key
implicitly, because `New-ItemProperty` fails on a key that does not exist.

The fake's **seeding** methods are `SeedValue(path, name, value)` and
`SeedKey(path)` — renamed from `SetValue`/`AddKey` in 03-03 so the recorded
interface method could take the name it has in the contract. It also carries
`GetValueType(path, name)`, which is **not** part of `IRegistryService`: it is an
inspection helper so a test can prove `AutoLogonCount` was written as a `DWord`
rather than as the string `'3'`, which Winlogon would ignore. Like seeding, it
does not record.

`ILsaService` is three methods: `SetSecret(name, value)`, `GetSecret(name)`
returning `$null` for a name that was never set, and an idempotent
`RemoveSecret(name)`. The only secret HDT writes is `DefaultPassword`, with no
`L$`/`M$` prefix — the name Winlogon reads and the one Sysinternals'
`Autologon.exe` writes (DESIGN 4.5.2, proven against a real machine in
SPIKES.md S8).

**The real row of `LsaService.Contract.Tests.ps1` is opt-in and read-only.** It
runs only when the session is elevated **and** `$env:HDT_ALLOW_LSA_TEST -eq '1'`,
prints a warning naming both conditions when it does not, and even then only
calls `GetSecret` on a name that cannot exist. **The suite never writes an LSA
secret on anyone's machine.** For the same reason the real `IRegistryService` row
writes only under `HKCU:\Software\HDT-Contract-Test-<guid>`, which it removes in
`AfterAll`; `HKLM` is never written by the suite.

`IDiskService` is nine methods. `GetDisk`, `GetPartition` and `GetVolume` are
three **flat listings, with no filters and no joins** — the same decision
`ICimProvider` made when it refused a `-Filter`. A partition row carries its
`DiskNumber` and a volume row carries its `DriveLetter`, so the pure logic in
04-02 does the joining and the adapter stays a projection of three cmdlets. An
adapter that filtered would be an adapter with a branch in it. The other six —
`ClearDisk`, `InitializeDisk`, `NewPartition`, `SetPartitionDriveLetter`,
`SetPartitionType`, `FormatVolume` — are the whole of what `DiskPartition` needs.

**Two behaviours the fake models rather than documents, both from SPIKES.md S6:**

- **`InitializeDisk` with `GPT` creates a 16 MB `Reserved` partition of its own,**
  because `Initialize-Disk -PartitionStyle GPT` does. HDT never creates an MSR;
  PSD's `PSDPartition.ps1` creates one by hand right after initialising, which is
  how the spike ended up with a **duplicate** 16 MB partition. Because the fake
  creates it too, a step that "helpfully" creates one produces a duplicate the
  tests can see. The consequence a test must expect: **the first partition an
  author creates on a GPT disk is number 2, not 1** — a test that assumed 1 would
  pass against a naive fake and fail on metal.
- **`NewPartition` refuses a disk that is still `RAW`,** as `New-Partition` does,
  so a step that forgot `InitializeDisk` cannot pass here and fail on metal.

The fake's `-Failure` seeds a method with the message it throws, as a
`System.InvalidOperationException` — the type the real adapter throws when a
Storage cmdlet fails — exactly as `New-HDTFakeImageService` does. It is the only
way to make this fake fail: `ClearDisk` leaves the disk `RAW`, so every later
call finds precisely the state it wanted, and without the seam
`Invoke-HDTDiskPartitionStep`'s failure path would be unprovable (added in
04-03 for that reason).

A disk number nothing seeded throws `ArgumentOutOfRangeException`. A disk number
carried by **two** seeded rows throws `InvalidOperationException` naming the
ambiguity: `tests/fixtures/disk/` is a *catalogue* of captured rows rather than a
snapshot of one machine — this host's disk and the derived Gen2 VM disk are both
number 0 — and DESIGN 9.1's whole point is that HDT refuses an ambiguous target
rather than guessing which disk to wipe.

**The real row of `DiskService.Contract.Tests.ps1` is opt-in and read-only**, for
the same reason the `ILsaService` one is. It runs only when the session is
elevated **and** `$env:HDT_ALLOW_DISK_TEST -eq '1'`, and even then calls only
`GetDisk`, `GetPartition` and `GetVolume`. The destructive half is proven in
`tests/integration` (04-04) against a mounted scratch VHDX, never against
whatever disk the developer happens to have — which on this machine is a single
NVMe disk with `IsBoot` and `IsSystem` both true.

`IImageService` is five methods: `GetImageInfo(imagePath)`,
`ApplyImage(imagePath, index, applyPath)`,
`InstallBootFile(osRoot, systemVolume, firmware)`,
`SetRecoveryImage(osRoot, recoveryPath)` and `SetBootOrderFirst()`. An image row
carries `Index`, `Name`, `Description`, `Edition`, `SizeBytes`, `Architecture`
and `Version`. **`SetBootOrderFirst` is SPIKES.md S6's fourth finding as an
API**: after apply, a machine that still has the boot media first in the
firmware order simply reboots into WinPE.

The fake's `-Failure` seeds a method with the message it throws, as a
`System.InvalidOperationException` — the type the real adapter throws when a
native tool exits non-zero — so a step's failure path is provable. An image path
that was never seeded throws `FileNotFoundException` naming it: a fake that
returned an empty list for a typo'd WIM would make a missing image look like an
image with no indices. Image paths are normalised exactly as
`New-HDTFakeScriptInvoker` normalises script paths, so one key serves both.

**The real row of `ImageService.Contract.Tests.ps1` calls `GetImageInfo` only**,
and is skipped with a printed warning where the staged media is absent — CI has
none. Applying an image, writing boot files, registering a recovery image and
reordering the firmware entries are proven in `tests/integration` (04-04); until
then `Expand-WindowsImage`, `bcdboot`, `bcdedit` and `reagentc` have **never
been executed by this repository**, and the summary says so rather than implying
otherwise.

`IContentProvider` is five methods: `ResolveContent(relativePath)`,
`TestContent(relativePath)`, `CopyContent(relativePath, destination)`,
`Connect()` and `Disconnect()`. **`Connect` and `Disconnect` are on the interface
even where they do nothing**, because DESIGN 6.2's claim is that media
generation is "a content projection plus a provider swap, not a parallel code
path" — and a provider where one implementation carries two extra methods is a
provider a step has to branch on. `Local` therefore has both, and `Connect` earns
its place by verifying the root: a USB stick that was never inserted fails there,
naming the root, rather than in the middle of an apply.

The resolution rules are identical in all three implementations: a relative path
is combined with `Root`, a **rooted** path is returned unchanged (DESIGN 9.3 —
media too large to bring into the share is registered where it stands), a `..`
that escapes `Root` is refused, and an empty path is refused. Segments are
collapsed by hand rather than by `[IO.Path]::GetFullPath`, which consults the
current directory for a volume-relative root and **silently clamps `..` at the
root of a UNC share** instead of reporting the escape —
`GetFullPath('\\server\Share\..\..\Windows')` is `\\server\Share\Windows` on both
engines.

**The error id travels in the message, not in an `ErrorRecord`.** A refusal
raised inside a PowerShell class method keeps its `FullyQualifiedErrorId`; the
same refusal raised inside a `ScriptMethod` — which is what every real adapter is
(F1) — arrives as `ScriptMethodRuntimeException` and loses it. Verified on both
engines. So `HDTConfigurationError` and `HDTSecurityError` are written into the
sentence, where the fake's class method and the adapter's `ScriptMethod` can both
carry them, and the contract asserts the exception *type* after unwrapping
(section 5).

`ISmbService` is four methods: `NewMapping(remotePath, userName, password)`,
`RemoveMapping(remotePath)`, `GetConnection(serverName)` returning rows of
`ServerName, ShareName, UserName, Dialect, Encrypted, Signed`, and
`GetClientConfiguration()` returning `EnableInsecureGuestLogons,
RequireSecuritySignature`. It is `SmbShare`, which DESIGN 5.1 records as
**present in WinPE** — `NetTCPIP`, `NetAdapter` and `DnsClient` are not, so
nothing may reach for those.

**A mapping becomes a connection**, and that is the point: `New-HDTSmbContentProvider`
maps and then reads the established identity back, so `-Connection` seeds what a
mapping *will become*. Seeding is authoritative — once a test has said what a
mapping becomes, a mapping to a server it did not name becomes nothing, which is
how "the mapping did not take" is staged. **The password is recorded as
`<redacted>`** on both the fake and the real adapter, exactly as
`ILsaService.SetSecret` redacts its value.

`IBootImageService` is nine methods: `MountImage`, `DismountImage`, `AddPackage`,
`AddDriver`, `GetPackage`, `GetImageInfo`, `ExportImage`, `SetScratchSpace` and
`NewIso`. It is `Mount-WindowsImage` and friends, plus `dism.exe
/Set-ScratchSpace` (there is no cmdlet for it) and `oscdimg.exe`.

**This is the one fake that models a mount, and it is a fake talking to a fake.**
`Update-HDTBootImage` *writes into* the mounted image — `startnet.cmd` into
`<mount>\Windows\System32`, the engine into `<mount>\HDT` — so a double that
recorded `MountImage` and did nothing else could not tell a builder that wrote
before mounting from one that wrote after. `MountImage` therefore seeds
`<MountPath>\Windows\System32` into the **injected `IFileSystem`**, and
`DismountImage($false)` takes the whole tree away again, so **a builder that
wrote after discarding is caught by a test** rather than by a boot image with no
launcher in it. `ExportImage` and `NewIso` likewise produce a *file* in that
filesystem, because DESIGN 6.1.1's mechanism is that the exported WIM is copied
into the media tree — one file, two homes, same bytes — and a fake whose export
wrote nothing would make the equivalence hash unprovable.

Seeding into the filesystem goes through the fake's `Seed*` methods, never
`CreateDirectory` or `WriteAllText`, so nothing the service does by itself
appears in the shared journal as an operation the builder performed. The one
exception is the discard, which really does remove the tree and records a
`FileSystem.RemoveItem` — as `Dismount-WindowsImage -Discard` does.

`AddPackage`, `AddDriver`, `SetScratchSpace` and `DismountImage` **refuse a path
that is not mounted**, as DISM does, so a builder that packaged before it mounted
cannot pass here and fail on metal fifteen minutes in.

**`SizeBytes` is the UNCOMPRESSED size, not the file size**, on this interface
and on `IImageService` alike — both project `Get-WindowsImage`'s `ImageSize`.
The ADK's `winpe.wim` is **340 134 390 bytes on disk** and reports
**2 009 251 937** here. The first draft of the contract asserted the file size
against the DISM number and went red on the real row, which is what the real row
is for.

**The real row of `BootImageService.Contract.Tests.ps1` calls `GetImageInfo`
only**, and is skipped with a printed warning where no ADK resolves. The other
eight mount a WIM, write into a mounted image, export half a gigabyte or burn an
ISO, and every one of them needs elevation; they are proven in
`tests/integration/BootImage.Integration.Tests.ps1`, which builds a real image and
re-mounts it read-only to read `startnet.cmd` back out of it.

`New-HDTFakeRandomNumberGenerator` doubles a .NET type rather than an HDT
service, so it has no real adapter row — but it follows every other convention
(factory, `$Operations`, `GetOperationName()`, `-Journal`, `ServiceName`) so
there is one shape to copy and no second one. It exists because
`New-HDTDeploymentPassword` takes its randomness as a parameter: that is what
makes "the same byte stream twice yields the same password" and "a byte in the
rejection window is discarded, not folded" testable at all.

`IFileSystem` is ten methods: `TestPath`, `ReadAllText`, `WriteAllText`,
`AppendAllText`, `CreateDirectory`, `RemoveItem`, `CopyItem`, `GetChildItem`,
`GetLength`, `GetHash`.

**`GetHash` is the tenth, added in 05-04, and it is the one widening this
interface has had.** DESIGN 6.1.1's claim — the WIM inside the ISO and the
standalone WIM have identical hashes — has to be *written into the boot image
manifest*, so an operator can check it without the test suite.
`Update-HDTBootImage` therefore hashes three files it produced. A 500 MB ISO
cannot go through `ReadAllText` (it is not text and it would sit in memory), and
a `Get-FileHash` call in the builder would be a call no fake could answer, which
is the exact shape PROJECT constraint 4 exists to prevent. Both implementations
return **the same 64-character uppercase hex string for the same content** — the
real one from `Get-FileHash -Algorithm SHA256`, the fake one from SHA256 over
the UTF-8 bytes of the content it holds, which are the bytes the real adapter
would have written — so "the copy has the same hash as its source" is provable
against the fake rather than only against a real ISO. The contract asserts the
value for `'hello'`, not merely the shape: a fake with its own hashing scheme
would let a builder that compared nothing pass.

**There is no `TestDirectory`, and `GetLength` is how a directory is told from a
file.** `TestPath` answers for both, and `GetChildItem` returns an empty array
for an empty directory, so neither distinguishes one. Both implementations throw
`System.IO.FileNotFoundException` for a path that is not a file — the real
adapter because `[System.IO.File]::Exists` is false for a directory, the fake
because its `File` dictionary has no such key — and that parity is what makes
`Copy-HDTContentTree` (04-02) classify a child the same way against either
implementation. Widening a nine-method interface in order to copy a tree would
have been the larger change; if a later phase needs the distinction on its own,
that is the moment to add the method, not before. `IClock` is two: `GetUtcNow`, `Sleep`. `Sleep` is on the interface
so retry backoff is provable without a test that waits — the fake advances its
own clock and returns immediately.

`IProcessService` is one method:

```
Start($FilePath, $Argument, $WorkingDirectory, $TimeoutMillisecond)
  -> ExitCode, StandardOutput, StandardError, TimedOut, DurationMs
```

`TimeoutMillisecond` 0 is unbounded; on timeout the process is killed, `TimedOut`
is `$true` and `ExitCode` is `-1`. The fake is seeded by COMMAND LINE - the file
and its arguments joined by one space - and an unseeded command throws
`System.ComponentModel.Win32Exception`, which is what `Process.Start` throws for
a missing executable (section 5). A fake that returned exit 0 for a command
nobody seeded would make a typo in a step look like success.

`IPowerService` is two: `Restart($DelaySecond)`, `Stop($DelaySecond)`. **The real
row of its contract is skipped permanently and deliberately** - a contract test
may not reboot the machine running it, and there is no dry-run form of
`shutdown.exe` that exercises the same path. The reason is written into
`PowerService.Contract.Tests.ps1` rather than left to be rediscovered.

`IScriptInvoker` is two: `Invoke($Path, $Variable)` and `GetTranscript()`.
`GetTranscript` returns the captured output of the **last** `Invoke`, replaced on
the next one, and `@()` before any. It exists because DESIGN 4.4.4 requires that
"an existing script that only uses `Write-Host` still lands in the log without
modification". The fake is seeded with `-Transcript`, whose keys are normalised
exactly as `-Result` keys are, so one key serves both hashtables. The real
adapter captures `*>&1` and returns the last item that is not a stream record -
a branch inside an adapter, which the "adapters stay dumb" rule tolerates only
because the contract proves it on both implementations.

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
- **One exception to "the arguments, verbatim": a secret value is redacted.**
  `ILsaService.SetSecret` records `@($Name, '<redacted>')` on both the fake and
  the real adapter. `$Operations` is printed verbatim in a Pester failure
  message, and DESIGN 4.5.2's whole point is that the deployment password does
  not sit in plaintext anywhere it does not have to. A contract test asserts the
  value is absent from the recording.

### The shared journal

`$Operations` answers "what was *this* service asked to do". DESIGN 12.2.1's
headline assertion asks a different question — "in what order did the engine
touch the services" — and no per-fake list can answer it. So every
`New-HDTFake*` factory, and every real adapter, takes:

```
-Journal [System.Collections.ArrayList]
```

When supplied, `Record()` appends to it **in addition to** `$Operations`:

| Property | Meaning |
|---|---|
| `Sequence` | 1-based position in the journal, across every service |
| `Service` | the fake's `ServiceName` — `FileSystem`, `Clock`, `CimProvider`, `RegistryService`, `EnvironmentProvider`, `ScriptInvoker`, `ProcessService`, `PowerService` |
| `Operation` | the method name |
| `Arguments` | `object[]`, in declaration order |

Rules that must hold, and that `tests/unit/FakeJournal.Tests.ps1` asserts over a
`-ForEach` list of **every** factory, so a fake added later that forgets
`-Journal` turns the suite red:

- Seeding is never recorded, in either sink.
- `$Operations` keeps its own independent 1-based `Sequence`. The journal's
  numbering is global; the per-fake numbering is not.
- A fake created without `-Journal`, or with `$null`, behaves exactly as before.
- Every fake and every real adapter exposes `[string] $ServiceName`, so the
  journal entry and a test can both name it without a type literal.

The canonical cross-service assertion:

```powershell
$journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation } |
    Should -Be @('FileSystem.ReadAllText', 'Clock.GetUtcNow', 'FileSystem.AppendAllText')
```

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

### `New-HDTFakeWdsService` — the fake with no real counterpart to check against

Every other fake in the table has a **contract row** that runs the same
assertions against the real adapter, which is how the two are kept honest
(section 6). `IWdsService` has none, `tests/contract/` carries no file for it,
and that is a deliberate refusal rather than an omission:

- **This host has no WDS.** It is Windows 11 Pro; the WDS PowerShell module and
  `wdsutil.exe` ship with a Windows **Server** role. `Get-Module -ListAvailable
  WDS` returns nothing, asserted in
  `tests/integration/PxePayload.Integration.Tests.ps1`.
- **Standing one up is forbidden.** `PROJECT.md` rule 3 confines PXE/WDS testing
  to the isolated `HDT Lab` switch, because `CM01` already runs a PXE responder
  on `Default Switch`. A second responder there would either break the user's
  SCCM lab or answer our test VMs and silently invalidate the test.

So **no WDS import has ever executed**, anywhere in this repository. The one
thing this machine can prove is asserted against the **real**
`New-HDTWdsService` in `tests/unit/Import-HDTBootImageToWds.Tests.ps1`: on a host
with no WDS module the constructor refuses with a named `HDTDependencyError`
naming the module and the role. Everything else about the WDS path — and in
particular the replace-in-place ordering ROADMAP M4 names — is asserted against
this fake alone, and `05-05-SUMMARY.md` and `ROADMAP.md` M4 say so in plain
sentences.

**The fake is a store, not a recorder, and it does not de-duplicate.**
`ImportBootImage` adds a row `GetBootImage` then answers with, so "importing the
same boot image twice leaves **one** image" is an assertion about the command.
A fake that quietly replaced would report green for a command that never called
`RemoveBootImage` — which is the exact defect the test exists to catch.

### `SeedHash` — the corrupt copy nothing else can stage

`FakeFileSystem.CopyItem` copies content exactly, as the real one does when it
works. So "the destination does not hash equal to the source" cannot be arranged
by seeding content: it has to be **stated**.

```powershell
$fs = New-HDTFakeFileSystem -File @{ 'C:\adk\boot.sdi' = 'bytes' }
$fs.SeedHash('D:\tftproot\Boot\x64\boot.sdi', 'DEADBEEF')
```

The path still holds whatever content it holds and every other method behaves
normally; only `GetHash` disagrees — which is what a truncated or bit-rotted file
looks like to code that verifies by hash. `New-HDTPxePayload` verifies every copy
because **a truncated `boot.sdi` on a TFTP server is a machine that hangs at boot
with no message on the screen and no line in any log**, and this is what makes
"fails rather than warns on a hash mismatch" provable.

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

### `Get-HDTSlowSuiteSkipViolation` — the S9.15 guard

`tests/contract/SlowSuiteSkip.Contract.Tests.ps1` runs it over every file in
`tests/integration` and `tests/e2e`, in the **normal** suite, because the files it
judges are the ones nobody runs on an ordinary day.

What it refuses: a `$script:` variable **assigned in `BeforeDiscovery` and read
inside `BeforeAll`** without being reassigned there first. Pester's discovery and
run phases do not share a scope. Under `./build.ps1`, which sets
`Set-StrictMode -Version Latest`, that read throws inside `BeforeAll` and takes
the whole container down; without StrictMode it is `$null`, `if (-not $null)` is
TRUE, and the expensive body runs on a machine that was supposed to be skipping
it (SPIKES S9.15). The fix, and the shape the scanner treats as correct, is to
recompute the condition inside `BeforeAll`.

It is AST-based, because the assignment and the read are the same token and a
text scan cannot tell them apart; a file that does not parse falls back to a line
scan and says so in the message, so a syntax error cannot hide a violation.
`tests/fixtures/slowskip/` holds one file per case, including a deliberately
unparseable one.

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

**F11. `Set-Content -Encoding UTF8` writes a BOM under 5.1 and none under
pwsh 7.** Verified: `239,187,191` under Windows PowerShell 5.1.26100.8655,
`120,...` under pwsh 7.5.8. The engine writes its logs under 5.1 in WinPE and
its tests under 7 on a desk, so a BOM would land in exactly the files a parser
reads. `[System.IO.File]::WriteAllText` and `::AppendAllText` with
`New-Object System.Text.UTF8Encoding($false)` are BOM-free on both, and that is
what `New-HDTFileSystem` uses. **`Set-Content`, `Add-Content`, `Out-File` and
`Tee-Object` are banned in the filesystem adapter and in every log writer.**
This is SPIKES.md S6's UTF-16 `Tee-Object` trap in a different disguise, and the
IFileSystem contract asserts the first three bytes are not the BOM.

`::AppendAllText` also **creates a missing file** but **throws** for a missing
parent directory, so both the adapter and the fake create the parent first.

**F12. Under Windows PowerShell 5.1 `ConvertFrom-Json` writes a top-level JSON
array to the pipeline WITHOUT enumerating it.** So `@(ConvertFrom-Json $text)`
is **one** element — the whole array — while pwsh 7 gives one element per row.
Through a variable it is the array itself on both engines:

```powershell
$content = ConvertFrom-Json -InputObject $text     # correct
foreach ($row in @($content)) { ... }

$content = @(ConvertFrom-Json -InputObject $text)  # WRONG: 1 element under 5.1
```

Observed in 04-01: a four-partition fixture arrived as a single nonsense row
under 5.1 while the pwsh 7 leg was green, and the fake happily reported one
partition where the machine has four. `New-HDTFakeCimProvider` was already
written the correct way, which is why this had not bitten before. Every fixture
loader assigns first and wraps second.

**Recording applies to real adapters too.** `New-HDTRegistryService`,
`New-HDTEnvironmentProvider` and `New-HDTScriptInvoker` each expose `$Operations`
and `GetOperationName()` and record before the call can throw, exactly as
section 4 requires of the fakes, so a provenance or query-order assertion in a
contract file holds against either implementation.

## 12. Two assertions that pass for the wrong reason

Both were observed in plan 02-02, against code that did not exist yet. Copy the
fixed shapes, not the broken ones.

**`Get-Help` falls back to a fuzzy search.** `Get-Help -Name Assert-HDTRuleDocument
-ErrorAction Stop` returned **`Get-HDTVariableMap`'s** help — a different command
entirely — so `$help.Synopsis | Should -Not -BeNullOrEmpty` passed for a command
that had not been written. Every comment-based-help test asserts the name first:

```powershell
$help = Get-Help -Name Import-HDTRuleDocument -ErrorAction Stop
$help.Name | Should -BeExactly 'Import-HDTRuleDocument'
$help.Synopsis | Should -Not -BeNullOrEmpty
```

(It throws `HelpNotFoundException` only when nothing resembling the name exists,
which is why this trap appears exactly when a sibling command is added.)

**"It threw" is not an assertion.** A test that only checks *that* a call failed
passes against `CommandNotFoundException`, which is what a missing implementation
produces — so it is green before the code exists and green after it is deleted.
Assert the identity of the failure:

```powershell
$record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
```

The rule that catches both: **every new test must be watched failing for the
right reason.** A test that passes on its first run is a defect in the test.

## 13. Lab helpers

`tests/helpers/HDTTestTools/tools/*HDTLab*.ps1` are the only code in the
repository allowed to call Hyper-V. They exist so that **PROJECT.md's Hyper-V
lab safety rules are enforced in code, before any Hyper-V call, rather than
remembered by the person running the test.**

This host runs the user's live lab. `CM01` is a Configuration Manager server
with a PXE responder; `DC01` is the domain controller. Damaging either is worse
than failing a test.

| Helper | Does |
|---|---|
| `Assert-HDTLabVmName` | the name guard: refuses a wildcard, `CM01`, `DC01`, and anything not `HDT-*` |
| `Assert-HDTLabVmPath` | the **delete** guard: refuses the VM root itself, anything outside it, and anything in it that is not this VM's own folder |
| `Assert-HDTLabScratchDisk` | the disk guard: refuses a row that is `IsBoot` or `IsSystem` |
| `New-HDTLabScratchDisk` / `Remove-HDTLabScratchDisk` | a VHDX under `C:\HDTLab`, created, mounted and destroyed by the test that uses it |
| `New-HDTLabVirtualMachine` / `Remove-HDTLabVirtualMachine` | a Generation 2 VM on `HDT Lab`, files under `C:\HDTLab\vms` |
| `New-HDTLabContentDisk` | the workspace, the module and the launcher as an attachable VHDX |
| `Send-HDTLabVmText` | SPIKES S4's `Msvm_Keyboard` `TypeText`/`TypeKey` |
| `Save-HDTLabVmScreen` | SPIKES S4's thumbnail, as a PNG for a human to read |
| `Wait-HDTLabVmState` | a power state, or an integration-services heartbeat |
| `Get-HDTLabOfflineComputerName` | mounts a VHDX read-only, `reg load`s its `SYSTEM` hive, unloads in a `finally` |

### The rules, and where each is enforced

1. **Every Hyper-V command is module-qualified** — `Hyper-V\Get-VM`, never
   `Get-VM`. PowerCLI is installed on this host and shadows `Get-VM`
   (SPIKES S8). A unit test parses every lab helper and fails on a bare
   `*-VM` command.
2. **No unfiltered pipeline.** Every `Hyper-V\Get-VM` in a lab helper names a VM
   or a name filter; a unit test asserts it. `Get-VM | Remove-VM` is the failure
   mode PROJECT.md rule 1 exists to prevent.
3. **`HDT-*` only, and never `CM01` or `DC01`.** `Assert-HDTLabVmName` runs
   before the first Hyper-V call in both VM helpers — asserted by comparing AST
   offsets, so a refactor that moves the guard down is caught.
4. **A wildcard name is refused.** `HDT-*` is a legal Hyper-V filter and would
   remove every test VM at once.
5. **`HDT Lab` switch only, Generation 2 only, files under `C:\HDTLab\vms`
   only, 8 GB per VM and 12 GB across every running `HDT-*` VM.**
6. **A delete may only touch `<vmRoot>\<Name>` and what is inside it.**
   `Assert-HDTLabVmPath` refuses the VM root itself, anything outside it, and
   anything in it belonging to another VM — including a VHDX sitting loose
   beside the VM folders, which is exactly where `HDT-PE-Test-osdisk.vhdx`
   lived.

   **Why it exists.** During 04-04 the contents of `C:\HDTLab\vms` were lost:
   `HDT-PE-Test`, its SPIKES S7/S8 deployed disk, and a leftover spike folder.
   The cause was never established — no helper names anything but the exact VM
   it is given, and the developer was working in the same lab at the time — but
   the delete was not narrow enough to make the accident *impossible*, and that
   is a defect in the one piece of code whose whole job is to make it
   impossible. `CM01` and `DC01` were never at risk: they are refused by name,
   and they do not live under `C:\HDTLab\vms` at all.

### Why the guard tests use no `Mock`

The plan for these tests asked for a `Mock` on `Hyper-V\New-VM`, asserting it
was never invoked when a helper refuses. **It cannot work.** A module-qualified
call resolves straight into the module and never consults the function table
Pester's `Mock` injects into, so the mock is never hit — and an assertion that
is never consulted is one that always passes. That is worse than no assertion at
all (section 12's subject).

What replaces it runs everywhere and is stronger: the AST assertions above prove
every Hyper-V command is module-qualified **and** that the safety guard is called
before the first one. Every refusal test then passes arguments that are invalid
by name, so the refusal is proven by the message it throws rather than by a
mock's call count.

### Nothing in `tests/unit` or `tests/contract` calls Hyper-V

Every assertion about the lab helpers in the normal suite is a **refusal**, and
every refusal happens before the first Hyper-V call. So
`tests/unit/New-HDTLabVirtualMachine.Tests.ps1` and
`tests/unit/New-HDTLabScratchDisk.Tests.ps1` run in a two-second suite on a
machine with no Hyper-V, no VHDX and no elevation — and create, start and remove
nothing.
