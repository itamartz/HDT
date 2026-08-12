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
| `cim/` | Captured `Get-CimInstance` output for the `root/cimv2` classes fact gathering uses (DESIGN 3.2.1), one JSON file per class | captured |
| `cim-microsofttpm/` | Captured `Win32_Tpm`, which lives in `root/cimv2/security/microsofttpm` — a **separate directory because it is a separate namespace**, not a subdirectory of `cim/` | captured |
| `cim-vm/` | A Hyper-V guest's `Win32_ComputerSystem` and `Win32_ComputerSystemProduct`, so `HDTIsVM` can be proven | **derived** — see below |
| `scripts/` | `setFrom:` extension scripts the `IScriptInvoker` contract runs for real (DESIGN 3.3) | captured shape |
| `naming/` | Source that breaks — and source that keeps — the `Verb-HDTNoun` rule (DESIGN 15.1), plus a class fixture proving class members are not commands | deliberately invalid |
| `compat/` | One file per PowerShell 7-only construct the 5.1 compatibility scanner must reject, plus a clean 5.1 control | deliberately invalid |
| `mdt/` | Source carrying banned MDT dependencies, plus an MDT-free control | deliberately invalid |
| `analyzer/` | Deliberate PSScriptAnalyzer bait (added in plan 01-04) | deliberately invalid |

## Fixtures are not source

`Get-HDTSourceFile` excludes `tests/fixtures/**` outright. Nothing under this
directory is subject to the naming contract, the PowerShell 5.1 compatibility
contract, the no-MDT contract or PSScriptAnalyzer — that is the entire point of
the deliberately invalid fixtures, and it is why they can sit in the repository
without turning the build red.

Consequence: a fixture is only ever *read* by a test. Never dot-source one into
the engine and never import one as a module.

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

## Derived fixtures

`tests/fixtures/cim-vm/` is **derived, not captured**, and that has to be said
out loud because everything else under this directory is captured (DESIGN
12.2.3, `tests/helpers/README.md` section 8).

There is no HDT test VM yet — phase 04 builds the first one — and the lab's
`CM01` and `DC01` are off-limits under the PROJECT Hyper-V safety rules. So
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
