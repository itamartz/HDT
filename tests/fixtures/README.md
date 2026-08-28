# tests/fixtures

Test data. Two kinds live here, and they follow opposite rules:

- **Captured data** — real shapes taken off real machines, sanitised. Fixtures
  exist so the fakes stay honest (DESIGN 12.2.3), which only works if the data
  was never invented.
- **Deliberately invalid source** — files that violate an HDT rule on purpose, so
  the scanner that detects the violation can be proven to detect it.

## Layout

| Directory | Holds | Kind |
|---|---|---|
| `adk/` | The Windows ADK's real layout and its real WinPE optional-component listing, taken off this host (DESIGN 5.1, SPIKES S1/S3) | captured |
| `cim/` | Captured `Get-CimInstance` output for the `root/cimv2` classes fact gathering uses (DESIGN 3.2.1), one JSON file per class | captured |
| `cim-microsofttpm/` | Captured `Win32_Tpm`, which lives in `root/cimv2/security/microsofttpm` — a **separate directory because it is a separate namespace**, not a subdirectory of `cim/` | captured |
| `cim-vm/` | A Hyper-V guest's `Win32_ComputerSystem` and `Win32_ComputerSystemProduct`, so `HDTIsVM` can be proven | **derived** — see below |
| `disk/` | Captured `Get-Disk`, `Get-Partition` and `Get-Volume` projections | captured |
| `image/` | Captured `Get-WindowsImage` output for both staged media trees, one file per WIM | captured |
| `scripts/` | `setFrom:` extension scripts the `IScriptInvoker` contract runs for real (DESIGN 3.3) | captured shape |
| `rules/` | `rules.yaml` documents, three that must load and ten that must be rejected (DESIGN 3.3) | authored, see below |
| `os/` | `os.yaml` documents, three that must load and eleven that must be rejected (DESIGN 2.1, 9.2) | authored, see below |
| `apps/` | `app.yaml` documents, seven that must load and nine that must be rejected (DESIGN 2.1, 8) | authored, see below |
| `unattend/` | The unattend SPIKES S7 actually deployed, tokenised | captured, see below |
| `naming/` | Source that breaks — and source that keeps — the `Verb-HDTNoun` rule (DESIGN 15.1), plus a class fixture proving class members are not commands | deliberately invalid |
| `compat/` | One file per PowerShell 7-only construct the 5.1 compatibility scanner must reject, plus a clean 5.1 control | deliberately invalid |
| `mdt/` | Source carrying banned MDT dependencies, plus an MDT-free control | deliberately invalid |
| `analyzer/` | Deliberate PSScriptAnalyzer bait (added in plan 01-04) | deliberately invalid |
| `bootstrap/` | `bootstrap.json` documents — the file the boot image carries and `Get-HDTBootstrapConfiguration` reads (DESIGN 6.3) | authored, see below |

## Fixtures are not source

`Get-HDTSourceFile` excludes `tests/fixtures/**` outright. Nothing under this
directory is subject to the naming contract, the PowerShell 5.1 compatibility
contract, the no-MDT contract or PSScriptAnalyzer — that is the entire point of
the deliberately invalid fixtures, and it is why they can sit in the repository
without turning the build red.

Consequence: a fixture is only ever *read* by a test. Never dot-source one into
the engine and never import one as a module.

## ADK fixtures

`adk/` is **captured**, from **ADK 10.1.26100.2454** on this host, and its whole
purpose is to keep the fake filesystem honest: `Get-HDTAdkPath` and
`Get-HDTBootImageComponent` are proven on a machine with no ADK installed, so
the tree their fake is seeded with has to be a tree that exists somewhere in the
world rather than one a test author invented.

| File | Holds |
|---|---|
| `adk-layout-10.1.26100.2454.json` | `KitsRoot10` as the registry reports it (**with its trailing separator**), the ADK root, and every file under `Oscdimg\` and the amd64 WinPE add-on — path relative to the ADK root, plus its size |
| `winpe-ocs-amd64.json` | One row per `WinPE_OCs\*.cab`: `Name`, `SizeBytes`, and **`HasEnUs`** — whether `en-us\<name>_en-us.cab` is there |

**`WinPE-FMAPI` is the row with `HasEnUs = false`, and it is the reason the
builder probes rather than assumes.** DESIGN 5.1 says "some components have
none, so the builder must probe"; this fixture is that sentence as data, and
`tests/unit/Get-HDTBootImageComponent.Tests.ps1` asserts on that exact
component by name.

Nothing is sanitised: an ADK layout carries no machine identity. Recaptured
with:

```powershell
# adk-layout-10.1.26100.2454.json
$root = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
[pscustomobject] @{
    kitsRoot10 = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots').KitsRoot10
    adkRoot    = $root
    adkVersion = '10.1.26100.2454'
    file       = @(Get-ChildItem -LiteralPath $root -Recurse -File -Depth 4 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'Oscdimg|Windows Preinstallation Environment\\amd64\\(en-us|Media\\bootmgr|WinPE_OCs)' } |
        ForEach-Object { [pscustomobject] @{ Path = $_.FullName.Substring($root.Length); SizeBytes = [long] $_.Length } })
} | ConvertTo-Json -Depth 4

# winpe-ocs-amd64.json - through the command, not through a literal path
$oc = Get-HDTAdkPath -Asset WinPeOptionalComponent
@(Get-ChildItem -LiteralPath $oc -Filter *.cab | ForEach-Object {
    $n = [IO.Path]::GetFileNameWithoutExtension($_.Name)
    [pscustomobject] @{
        Name      = $n
        SizeBytes = [long] $_.Length
        HasEnUs   = Test-Path -LiteralPath (Join-Path $oc ('en-us\{0}_en-us.cab' -f $n))
    }
}) | Sort-Object Name | ConvertTo-Json -Depth 3
```

### Where the dependency table came from

`Get-HDTBootImageComponentDependency` is **not** a fixture — it ships in
`src/Hephaestus/Private/` — but its provenance belongs beside these two. Each
`WinPE_OCs\*.cab` contains an `update.mum` package manifest declaring the
packages it is a child of, and that is Microsoft's own metadata, on this
machine, rather than a table typed from memory:

```powershell
$oc = Get-HDTAdkPath -Asset WinPeOptionalComponent
foreach ($cab in Get-ChildItem -LiteralPath $oc -Filter *.cab) {
    $dir = Join-Path $env:TEMP ([IO.Path]::GetFileNameWithoutExtension($cab.Name))
    & "$env:SystemRoot\System32\expand.exe" -f:*.mum $cab.FullName $dir
    # //package/parent/assemblyIdentity/@name
}
```

Six components declare a parent that is itself an optional component. The three
`Microsoft-Windows-*-Package` parents are WinPE itself and are deliberately not
rows. **A dependency this repository cannot cite is omitted, never guessed** —
an invented dependency refuses a build that would have worked.

The layout capture is the **one** place in this repository, outside
documentation, where an ADK path is written down literally. Everywhere else
resolves it — that is what `Get-HDTAdkPath` is for, and PROJECT.md's "the layout
has moved between ADK releases" is why.

## CIM fixtures

Captured with, and re-capturable by, the equivalent of:

```powershell
foreach ($class in 'Win32_ComputerSystem', 'Win32_ComputerSystemProduct', 'Win32_BaseBoard', 'Win32_BIOS', 'Win32_SystemEnclosure') {
    $instance = @(Get-CimInstance -ClassName $class |
        Select-Object -Property * -ExcludeProperty Cim*, PS*, OEMLogoBitmap)
    ConvertTo-Json -InputObject $instance -Depth 4 |
        Set-Content -Path "tests/fixtures/cim/$class.json" -Encoding UTF8
}

# Win32_NetworkAdapterConfiguration is projected: the full property set is 58 KB
# of scaffolding, the thirteen properties below are 13.5 KB. EVERY adapter is
# captured, IP enabled or not - the ICimProvider contract has no -Filter, so the
# fact gatherer does the filtering and the fixture must contain what it filters out.
$adapter = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration |
    Select-Object Index, InterfaceIndex, Description, ServiceName, SettingID,
                  IPEnabled, DHCPEnabled, MACAddress, IPAddress, IPSubnet,
                  DefaultIPGateway, DNSDomain, DNSServerSearchOrder)
ConvertTo-Json -InputObject $adapter -Depth 4 |
    Set-Content -Path 'tests/fixtures/cim/Win32_NetworkAdapterConfiguration.json' -Encoding UTF8

# Win32_Tpm is in another NAMESPACE, so it goes in another DIRECTORY:
# New-HDTFakeCimProvider -FixturePath seeds root/cimv2 only, and ignores
# subdirectories. -NamespaceFixturePath seeds this one.
$tpm = @(Get-CimInstance -Namespace root/cimv2/security/microsofttpm -ClassName Win32_Tpm |
    Select-Object -Property * -ExcludeProperty Cim*, PS*)
ConvertTo-Json -InputObject $tpm -Depth 4 |
    Set-Content -Path 'tests/fixtures/cim-microsofttpm/Win32_Tpm.json' -Encoding UTF8
```

**Never assign a one-element array to a property straight from an `if`
statement** while sanitising. A statement's output is enumerated, so
`$a.DefaultIPGateway = if (...) { @('10.20.30.1') }` silently writes a *scalar*
and `ConvertTo-Json` then emits `"10.20.30.1"` instead of `["10.20.30.1"]` —
which is not the shape CIM returns, and the fact gatherer would be tested
against a lie. Assign through a variable.

Rules, all of them load-bearing:

1. **Every file is a JSON array**, even for a single instance, so
   `ICimProvider.GetInstance` always has an array to return and a test never has
   to care whether a machine had one disk or four.
2. **The file base name is the class name.** `New-HDTFakeCimProvider -FixturePath`
   seeds `root/cimv2` from exactly that.
3. **`Cim*` and `PS*` properties are excluded.** They are serialisation
   scaffolding, not facts, and they do not survive a JSON round trip intact.
4. **`OEMLogoBitmap` is excluded** from `Win32_ComputerSystem`: a half-megabyte
   byte array that no test will ever read.

### Sanitisation — mandatory before committing

This machine's identifiers must never enter git history. Replace the value,
**keep the property present and its type identical** — a fact gatherer that
reads `SerialNumber` must still find a string there:

| Property | Replacement |
|---|---|
| `SerialNumber` | `FIXTURE-SERIAL-0001` |
| `IdentifyingNumber` | `FIXTURE-SERIAL-0001` |
| `UUID` | `4C4C4544-0031-3610-8052-B7C04F515A31` |
| `Name` / `Caption` / `DNSHostName` holding the host name | `FIXTUREPC` |
| `UserName` | `FIXTUREPC\Fixture` |
| `PrimaryOwnerName` | `Fixture` |
| `SMBIOSAssetTag` | `FIXTURE-ASSET-0001` |
| `MACAddress` | `00:15:5D:0A:00:NN`, `NN` = the adapter's `Index` as two hex digits |
| `SettingID` | `{00000000-0000-0000-0000-0000000000NN}`, same `NN` |
| IPv4 in `IPAddress` | `10.20.30.<100 + Index>`, second and later IPv4 on one adapter `10.20.31.<100 + Index>` |
| IPv6 in `IPAddress` | `fe80::NN`, second and later `fe80::<n>:NN` |
| `DefaultIPGateway`, first adapter that has one | `["10.20.30.1"]` |
| `DefaultIPGateway`, any further adapter | `["10.20.30.254"]` |
| `DNSDomain` | `null` |
| `DNSServerSearchOrder` | `["10.20.30.2"]` |

Two notes on the network rows, both deliberate:

- The IPv4 octet is `100 + Index` rather than the bare index. `Index` runs 0-27
  here, and `10.20.30.0` is not an address while `10.20.30.1`, `.2` and `.254`
  are already spoken for by the gateway and DNS rows. The offset keeps every
  address valid and keeps a host address from colliding with the gateway.
- The first gateway is `10.20.30.1` **on purpose**: that is the value DESIGN
  3.3's `Lab subnet` rule matches, so plan 02-03's end-to-end test runs against
  the design's own worked example instead of an invented one.

Do the replacement over the whole JSON text, case-insensitively, so a serial
that also appears inside `SoftwareElementID` or `BIOSVersion` is caught too.
Then scan the result for the real serial, UUID, host name, user name, MAC
addresses and adapter `SettingID` GUIDs before staging.

Manufacturer, model, SKU, family, firmware version, `Description`,
`ServiceName`, `IPEnabled`, `DHCPEnabled`, `IPSubnet`, `Index`, `ChassisTypes`
and `Version` are **kept**: they are hardware facts, not personal ones, and
rule-matching tests need a realistic `Model` and a realistic chassis type to
match on.

## Disk fixtures

`disk/` is a **catalogue of rows, not a snapshot of one machine.** The base
name's suffix chooses which `IDiskService` listing a file seeds, and
`New-HDTFakeDiskService -FixturePath` accepts either the directory or a single
file:

| File | Rows | Kind |
|---|---|---|
| `host-nvme-disk.json` | this machine's own disk — `NVMe`, `GPT`, **`IsBoot` and `IsSystem` both true** | captured |
| `host-vhdx-disk.json` | `C:\HDTLab\scratch\imgtest-a.vhdx` mounted read-only — `BusType` `File Backed Virtual` | captured |
| `gen2-vm-raw-disk.json` | `HDT-M3-Deploy`'s virgin target disk — `SAS`, `RAW`, 64 GB, no serial | captured |
| `host-partition.json` | this machine's four partitions: ESP, MSR, Windows, Recovery | captured |
| `host-volume.json` | this machine's lettered volumes | captured |

`host-nvme-disk.json` is the row 04-02's selection rule must refuse
**unconditionally**: the developer machine is the disk most likely to be in
front of this code, and it is the one disk on it.

Two files each carry a disk numbered `0`, so loading the whole directory yields
an ambiguous disk 0 — and `New-HDTFakeDiskService` throws for it rather than
picking one, which is DESIGN 9.1's refusal to guess, enforced in the fake.

Captured with, and re-capturable by, the equivalent of:

```powershell
# host-nvme-disk.json - the eleven documented GetDisk properties.
@(Get-Disk | Select-Object Number, FriendlyName, SerialNumber,
    @{n='SizeBytes';e={[long]$_.Size}}, BusType, PartitionStyle,
    IsBoot, IsSystem, IsReadOnly, IsOffline, OperationalStatus) |
  ConvertTo-Json -Depth 3

# host-vhdx-disk.json - the same projection of a VHDX mounted READ ONLY and
# dismounted again in a finally. IsReadOnly is true in the fixture BECAUSE the
# capture used -Access ReadOnly; that is the honest value for how it was taken.
Mount-DiskImage -ImagePath C:\HDTLab\scratch\imgtest-a.vhdx -Access ReadOnly -StorageType VHDX -NoDriveLetter

# host-partition.json / host-volume.json - the documented GetPartition and
# GetVolume projections. GetVolume reports only volumes with a drive letter, so
# the capture filters to those.
```

`SerialNumber` is replaced with `FIXTURE-SERIAL-0001` in every disk row, exactly
as the CIM fixtures do. `FriendlyName`, `BusType`, `SizeBytes`,
`PartitionStyle`, the GPT type GUIDs and the volume labels are hardware facts
and are kept — the GUIDs in particular are what 04-02 and 04-03 assert against.

### `gen2-vm-raw-disk.json` — the debt 04-04 paid

This file used to be **derived**: the property shape was this host's real
`Get-Disk` projection, but the values came from SPIKES S6's notes, because there
was no HDT test VM to capture from.

**It is now a true capture.** `tests/e2e/Deployment.E2E.Tests.ps1` reads the
target disk of `HDT-M3-Deploy` through `IDiskService` — the same eleven-property
projection — from inside WinPE, a moment before the deployment repartitions it,
and writes it to `C:\HDTLab\scratch\e2e\DISK-BEFORE.json`. That run also asserts
the row against this file, so the fixture cannot drift from the machine.

The derivation was accurate on every property but one:

| Property | Derived | Captured |
|---|---|---|
| `BusType` | `SAS` | `SAS` ✅ (not `SCSI`, not `Virtual` — never filter on a VM-specific bus type) |
| `PartitionStyle` | `RAW` | `RAW` ✅ |
| `SizeBytes` | 68719476736 | 68719476736 ✅ |
| `FriendlyName` | `Msft Virtual Disk` | `Msft Virtual Disk` ✅ |
| every flag | false | false ✅ |
| **`SerialNumber`** | `FIXTURE-SERIAL-0001` (placeholder) | **empty string** |

**A Generation 2 VM's virtual disk reports no serial number at all.** That is
the honest value and it is kept unredacted, because there is nothing to redact.
Nothing in disk selection may key on a serial: on the machines HDT is tested
against there is not one.

## Image fixtures

`image/` holds the index catalogue of each staged WIM, one file per medium.
These are what 04-02's index resolution is proven against, so PROJECT.md's
"index 1 = Windows 11 Enterprise LTSC" and "index 2 = Standard Desktop
Experience" stop being documentation and become fixtures.

| File | Medium | Indices |
|---|---|---|
| `win11-ltsc-2024-install.json` | `C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim` | 1 Enterprise LTSC (`EnterpriseS`), 2 Enterprise N LTSC |
| `ws2025-std-install.json` | `C:\HDTLab\media\WS2025-Std\sources\install.wim` | 1 Standard, **2 Standard (Desktop Experience)**, 3 Datacenter, 4 Datacenter (Desktop Experience) |

Captured with, and re-capturable by, the equivalent of:

```powershell
$summary = @(Get-WindowsImage -ImagePath $wim)
$row = foreach ($image in $summary) {
    # EditionId, Architecture and Version come only from the PER-INDEX form;
    # the summary does not carry them.
    $detail = Get-WindowsImage -ImagePath $wim -Index $image.ImageIndex
    [pscustomobject] @{
        Index = [int] $image.ImageIndex;      Name = [string] $image.ImageName
        Description = [string] $image.ImageDescription
        Edition = [string] $detail.EditionId; SizeBytes = [long] $image.ImageSize
        Architecture = [string] $detail.Architecture; Version = [string] $detail.Version
    }
}
ConvertTo-Json -InputObject @($row) -Depth 3
```

Nothing is sanitised: a WIM's index catalogue carries no machine identity.

**`Architecture` is a numeric DISM code, not a string.** Both media report `9`,
which is amd64. It is recorded as it arrives rather than prettified — a fixture
that improved on the tool would be a fixture that lied about it, and 04-02 has
to match on the value the tool actually returns.

`tests/contract/ImageService.Contract.Tests.ps1` seeds its fake row from
`win11-ltsc-2024-install.json` and points its real row at the WIM itself, and
asserts the same things about both. So this fixture cannot drift from the media
without the suite going red.

## Rules fixtures

`rules/` is the test data for the whole authoring half of the rule engine:
`ConvertFrom-HDTYaml`, `Assert-HDTRuleDocument`, `Import-HDTRuleDocument` and
`tests/contract/RulesSchema.Contract.Tests.ps1` all read from it. Unlike the CIM
fixtures these are **authored, not captured** — a rules document is something an
administrator writes, so there is no machine to capture one from. The one that
matters most is copied verbatim from a document rather than invented:
`valid-design-example.yaml` **is** DESIGN 3.3's worked example, character for
character, and plan 02-03's precedence tests run against it. Do not "improve" it.

The prefix is a contract, and the schema contract test depends on it:

| Prefix | Meaning |
|---|---|
| `valid-` | parses, passes `schemas/rules.schema.json`, passes `Assert-HDTRuleDocument` |
| `invalid-` | parses, **fails** `Assert-HDTRuleDocument` — and fails the schema too, except where noted below |
| `unparseable-` | does not parse at all: `ConvertFrom-HDTYaml` throws |

Every file under `rules/` is UTF-8 and is stored in git with LF line endings. A
working copy may show CRLF where `core.autocrlf` converts on checkout, so no test
may depend on the line ending — the one test that depends on a *line number*
(`unparseable-indentation.yaml`, error on **line 4**) is unaffected by it.

Each `invalid-` file isolates exactly one authoring mistake, so a rejection
message can be asserted without ambiguity:

| File | The one mistake |
|---|---|
| `invalid-missing-schemaversion.yaml` | no `schemaVersion` |
| `invalid-newer-schemaversion.yaml` | `schemaVersion: 99`, newer than the engine (DESIGN 12.3) |
| `invalid-rule-without-name.yaml` | a rule with no `name` |
| `invalid-rule-without-assignment.yaml` | neither `set` nor `setFrom` |
| `invalid-rule-with-both-assignments.yaml` | both `set` and `setFrom` |
| `invalid-unknown-rule-key.yaml` | `priority: 10`, the INI habit HDT deliberately does not have |
| `invalid-engine-variable.yaml` | assigns `_HDTLogPath`, which is engine-owned (DESIGN 3.2) |
| `invalid-duplicate-rule-name.yaml` | two rules named `Fallback`, which makes provenance ambiguous |
| `unparseable-indentation.yaml` | `set:` mis-indented under `name:` — parser error on line 4 |
| `unparseable-duplicate-key.yaml` | `schemaVersion` twice — YamlDotNet reports `Duplicate key` |

**One schema blind spot, stated rather than hidden.** JSON Schema draft-07 cannot
express "no two rules share a `name`", so `invalid-duplicate-rule-name.yaml` is
the single `invalid-` file the schema *accepts*. The engine rejects it. The
contract test carries it in an explicit blind-spot list and asserts both halves,
so if the schema ever gains the ability the test goes red and the file must be
moved out of the list rather than quietly forgotten.

## Operating system fixtures

`os/` is the test data for the operating system catalog: `os.yaml` documents read
by `Assert-HDTOperatingSystemDocument`, `Get-HDTOperatingSystem` and
`tests/contract/OsSchema.Contract.Tests.ps1`. Like `rules/` they are **authored,
not captured** — an `os.yaml` is something `Import-HDTOperatingSystem` writes or
an administrator edits — but the two indices in `valid-win11-ltsc.yaml` are
copied from the real capture in `image/win11-ltsc-2024-install.json` rather than
invented, so the fixture and the media agree.

The prefix contract is the same as `rules/`: `valid-` parses and passes both
validators, `invalid-` parses and fails the engine, `unparseable-` does not parse.

| File | The one mistake |
|---|---|
| `invalid-missing-schemaversion.yaml` | no `schemaVersion` |
| `invalid-missing-id.yaml` | no `id` |
| `invalid-missing-name.yaml` | no `name` |
| `invalid-bad-type.yaml` | `type: iso`, and there is no third apply path |
| `invalid-bad-architecture.yaml` | `architecture: ia64` |
| `invalid-empty-images.yaml` | `images: []` |
| `invalid-bad-index.yaml` | `index: 0` — WIM indices are 1-based |
| `invalid-unknown-key.yaml` | `priority: 1`, the same INI habit `rules/` rejects |
| `invalid-duplicate-index.yaml` | two **identical** images at index 1 |
| `invalid-duplicate-index-distinct.yaml` | two **differing** images at index 1 |
| `invalid-default-index-absent.yaml` | `defaultIndex: 7`, which no image carries |
| `unparseable-indentation.yaml` | `name:` over-indented under `- index:` |

**Two schema blind spots, stated rather than hidden**, and both listed in
`$script:HDTSchemaBlindSpot` in the contract file:

- `invalid-default-index-absent.yaml` — draft-07 has no cross-field reference, so
  it cannot check `defaultIndex` against the `images` array.
- `invalid-duplicate-index-distinct.yaml` — `uniqueItems` compares **whole
  items**, so it cannot express "no two images share an index" when the entries
  differ elsewhere. `invalid-duplicate-index.yaml` exists alongside it precisely
  to show where the schema *does* reach: its two entries are identical, so
  `uniqueItems` catches them.

The engine rejects all three. If a future schema gains either ability, the
blind-spot test goes red and the file must be moved out of the list rather than
quietly forgotten.

## Application fixtures

`apps/` is the test data for the application catalog: `app.yaml` documents read by
`Assert-HDTApplicationDocument`, `Get-HDTApplication` and
`tests/contract/AppSchema.Contract.Tests.ps1`. **Authored, not captured** — an
`app.yaml` is what an administrator writes.

The prefix contract is the same as `os/`: `valid-` parses and passes both
validators, `invalid-` parses and fails the engine.

The seven valid fixtures exist to cover what is **optional**, which is where this
schema differs from every other one in the workspace. `valid-no-detect.yaml` is
the important one: DESIGN 8 makes `detect:` optional, so an application declaring
none must load, and it installs every time the step reaches it. It is also the
minimal legal document, so it doubles as proof that `successCodes`, `rebootCodes`
and `runIn` default in the engine rather than in the file.

| File | The one mistake |
|---|---|
| `invalid-empty.yaml` | no document at all |
| `invalid-unknown-key.yaml` | `installCommand:`, what an administrator coming from another toolkit types |
| `invalid-missing-install.yaml` | no `install`, and there is no default command to guess |
| `invalid-bad-id.yaml` | `id: ../../Windows/System32` — the id becomes a folder name |
| `invalid-detect-unknown-type.yaml` | `type: wmi`, a detection rule HDT cannot run |
| `invalid-detect-missing-field.yaml` | `msiProduct` with no `productCode` |
| `invalid-runin.yaml` | `runIn: Windows`, which is not one of the three phases |
| `invalid-success-code-not-integer.yaml` | `successCodes: ['0', 'reboot']` — a string matches no exit code |
| `invalid-dependency-self.yaml` | an application that depends on itself |

**One schema blind spot**, listed in `$script:HDTSchemaBlindSpot` in the contract
file: `invalid-dependency-self.yaml`. Draft-07 has no cross-field reference from
the `dependencies` array back to `id`, so the schema cannot see the cycle. The
engine rejects it at authoring time, which is why `Resolve-HDTApplicationOrder`
never has to survive a cycle of length one.

`invalid-empty.yaml` is worth one note: an empty YAML document parses to `$null`,
and `ConvertTo-Json` emits nothing for it, which `Test-Json` refuses to bind. The
contract file converts it to the JSON literal `null` — the honest representation
of "the file held no document" — and the schema rejects it because the root must
be an object. Both gates therefore reject it for the same reason rather than one
of them erroring on the way to an answer.

## Unattend fixtures

`unattend/win11-client.xml` is the document SPIKES.md **S7** deployed to a real
Windows 11 Enterprise LTSC machine, captured from
`C:\HDTLab\Share\unattend-test.xml` rather than written from memory. S7 observed
it applying `ComputerName` in the `specialize` pass, skipping OOBE, enabling the
built-in Administrator, running `FirstLogonCommands` and arming autologon with
the password held as an **LSA secret** rather than in the registry.

Two changes, both stated in a comment at the top of the file: the two literals
became `%HDTComputerName%` and `%HDTAdminPassword%`, and the spike's own
`FirstLogonCommands` instrumentation was removed. `%HDTAdminPassword%` appears
**twice** - once under `UserAccounts` and once inside `AutoLogon`, because Setup
reads them separately - which is the case that catches an implementation minting
one password per token instead of one per run.

`samples/workspace/TaskSequences/DEMO-M3/unattend.xml` is the same document.
The sample is what 04-04 deploys; this copy is what the unit tests read.

## Bootstrap fixtures

`bootstrap/` is **authored, not captured**, and it is the one directory here
where that is not a compromise: nothing has ever written a `bootstrap.json`,
because **05-04's `Update-HDTBootImage` is what writes it** and 05-03 is what
reads it. There is no machine in the world to capture one off yet.

The naming follows `state/` exactly — `valid-*`, `invalid-*`, `unparseable-*` —
and every file is read by `tests/unit/Get-HDTBootstrapConfiguration.Tests.ps1`.

| File | What it proves |
|---|---|
| `valid-smb.json` | the full document: `Smb`, a UNC `deployRoot`, an embedded credential, an explicit `contentMarker` and `sequenceId` |
| `valid-local.json` | `Local` with a **rooted** `deployRoot` — what a build host uses — and no credential block at all |
| `valid-local-volume-relative.json` | `Local` with a **volume-relative** `deployRoot` (`\Share`). **This is the form a boot image should carry** (SPIKES S9.1: WinPE gave the content disk `C:` and the RAM disk `X:`, so a letter written at build time is a guess about a machine that has not booted yet). `Resolve-HDTDeployRoot` turns it into a real path at boot |
| `valid-prompt.json` | `promptForCredential: true` with no credential block — DESIGN 6.3's deliberately-not-unattended build |
| `invalid-unknown-provider.json` | `provider: Ftp`; the reader names the file, the value and the two legal names |
| `invalid-missing-deployroot.json` | an empty `deployRoot` |
| `unparseable-truncated.json` | truncated mid-object. The reader must produce `HDTConfigurationError` naming the file, **not** a raw `ConvertFrom-Json` exception — this file is read on a machine with no operator and its failure is the last thing anyone will see |

`valid-smb.json`'s `credential.protected` is a real
`Protect-HDTShareSecret` blob over the string `Fixture-P@ssw0rd-01`, produced by
the module's own AES-over-a-module-constant obfuscation (DESIGN 6.3 — it is
obfuscation, not protection, and the deployment account is least-privileged for
exactly that reason). It is a fixture password and it authenticates to nothing.

**05-04 carries a test that the `bootstrap.json` it writes is accepted by this
reader**, so these fixtures and the real writer cannot drift apart.

## Derived fixtures

`tests/fixtures/cim-vm/` is **derived, not captured**, and that has to be said
out loud because everything else under this directory is captured (DESIGN
12.2.3, `tests/helpers/README.md` section 8).

There is no HDT test VM yet — phase 04 builds the first one — and every VM on
this host outside `HDT-*` is off-limits under the PROJECT Hyper-V safety rules.
So
`HDTIsVM` has no honest capture available today, and it is exactly the fact that
cannot be proven without one.

What was done: `cim/Win32_ComputerSystem.json` and
`cim/Win32_ComputerSystemProduct.json` were copied, and **four** properties
replaced with the values PSD documents for a Hyper-V guest
(`Scripts/PSDGather.psm1`, the `IsVM` block):

| File | Property | Value |
|---|---|---|
| `Win32_ComputerSystem.json` | `Manufacturer` | `Microsoft Corporation` |
| `Win32_ComputerSystem.json` | `Model` | `Virtual Machine` |
| `Win32_ComputerSystemProduct.json` | `Vendor` | `Microsoft Corporation` |
| `Win32_ComputerSystemProduct.json` | `Version` | `Hyper-V UEFI Release v4.1` |

Every other property, and the whole shape, is the real capture. Fixture honesty
is a rule about not inventing *shapes*; the shape here is real and the four
substitutions are recorded above.

**Replace this directory with a real capture from the first `HDT-*` VM in phase
04**, and delete this note when you do.
