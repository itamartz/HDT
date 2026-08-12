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
| `cim/` | Captured `Get-CimInstance` output for the classes fact gathering uses (DESIGN 3.2.1), one JSON file per class | captured |
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
foreach ($class in 'Win32_ComputerSystem', 'Win32_ComputerSystemProduct', 'Win32_BaseBoard', 'Win32_BIOS') {
    $instance = @(Get-CimInstance -ClassName $class |
        Select-Object -Property * -ExcludeProperty Cim*, PS*, OEMLogoBitmap)
    ConvertTo-Json -InputObject $instance -Depth 4 |
        Set-Content -Path "tests/fixtures/cim/$class.json" -Encoding UTF8
}
```

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

Do the replacement over the whole JSON text, case-insensitively, so a serial
that also appears inside `SoftwareElementID` or `BIOSVersion` is caught too.
Then scan the result for the real serial, UUID, host name and user name before
staging.

Manufacturer, model, SKU, family and firmware version are **kept**: they are
hardware facts, not personal ones, and rule-matching tests need a realistic
`Model` to match on.
