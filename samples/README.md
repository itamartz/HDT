# HDT samples

## `workspace/` — the variable and rule sample

A minimal workspace showing every feature of the resolution engine (DESIGN 3.1
and 3.3). Copy it and edit; it is the shape a real deployment share has, with the
parts M1 covers filled in.

```
workspace/
  rules.yaml                                              the rules
  Control/machines/4C4C4544-0031-3610-8052-B7C04F515A31.yaml   a per-machine override
  Scripts/Get-ComputerName.ps1                            a setFrom: extension script
```

### What each file is for

**`rules.yaml`** is DESIGN 3.3's example plus one `setFrom` rule, so the four
rules between them exercise everything:

| Rule | Shows |
|---|---|
| `Lab subnet` | matching a **list-valued** fact — `HDTDefaultGateway` is a list on a multi-NIC machine and any element may match |
| `Latitude naming` | **multi-key** `when` (AND) and a **wildcard**, plus `%Var%` expansion into a value |
| `Scripted name for laptops` | `setFrom:` — a rule that needs real logic calls a script and the object it emits becomes variables |
| `Fallback` | no `when`, so it always applies — but only to variables nothing above it set |

**`Control/machines/<UUID>.yaml`** is the file-based equivalent of the MDT
database: one machine made an exception without editing `rules.yaml`. The file
name is the machine's `HDTUUID`. This one matches the UUID in
`tests/fixtures/cim/Win32_ComputerSystemProduct.json`, so the sample and the test
fixtures describe the same machine.

**`Scripts/Get-ComputerName.ps1`** is a *user* extension point, so it
deliberately carries no `HDT` command prefix — DESIGN 15.1 governs HDT's own
commands, not a customer's scripts. The contract it honours:

- one parameter, the current variable scope, as an `IDictionary`;
- emit exactly **one** object; every property becomes a variable;
- a property named `_HDT*` is a configuration error — those are engine-owned;
- emitting nothing is allowed and sets nothing.

### Resolving it

```powershell
Import-Module ./src/Hephaestus/Hephaestus.psd1 -Force
Import-Module ./tests/helpers/HDTFakes/HDTFakes.psd1 -Force

$fact  = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
                            -RegistryService (New-HDTRegistryService) `
                            -EnvironmentProvider (New-HDTEnvironmentProvider)
$fs    = New-HDTFakeFileSystem -File @{ 'C:\ws\rules.yaml' = (Get-Content ./samples/workspace/rules.yaml -Raw) }
$rules = Import-HDTRuleDocument -Path 'C:\ws\rules.yaml' -FileSystem $fs
$r     = Resolve-HDTVariable -RuleDocument $rules -Fact $fact `
                             -ScriptInvoker (New-HDTFakeScriptInvoker -Result @{ 'Scripts/Get-ComputerName.ps1' = $null })

Get-HDTVariableProvenance -Resolution $r | Format-Table Order, Name, Value, Source, Rule -AutoSize
```

On the development machine this repository was built on — a Lenovo laptop that is
not on the lab subnet — that prints:

```
Order Name                 Value                                           Source       Rule
----- ----                 -----                                           ------       ----
    1 HDTComputerName      PC-1ABC234                                     Rule         Fallback
    2 HDTJoinWorkgroup     WORKGROUP                                       Rule         Fallback
    3 HDTMake              LENOVO                                          GatheredFact
    4 HDTModel             82RF                                            GatheredFact
    5 HDTProduct           LNVNB161216                                     GatheredFact
    6 HDTSerialNumber      1ABC234                                        GatheredFact
    7 HDTUUID              4C4C4544-0042-3910-8051-B7C04F503332            GatheredFact
    8 HDTSystemSKU         LENOVO_MT_82RF_BU_idea_FM_Legion 5 Pro 16IAH7H  GatheredFact
    9 HDTMemory            65260                                           GatheredFact
   10 HDTArchitecture      x64                                             GatheredFact
   11 HDTIsUEFI            True                                            GatheredFact
   12 HDTSecureBootEnabled True                                            GatheredFact
   13 HDTTPMVersion        2.0                                             GatheredFact
   14 HDTIsDesktop         False                                           GatheredFact
   15 HDTIsLaptop          True                                            GatheredFact
   16 HDTIsServer          False                                           GatheredFact
   17 HDTIsVM              False                                           GatheredFact
   18 HDTMacAddress        {...}                                           GatheredFact
   19 HDTIPAddress         {...}                                           GatheredFact
   20 HDTDefaultGateway    {...}                                           GatheredFact
```

Read the first two rows: `HDTComputerName` is `PC-<serial>` **because** the
`Fallback` rule set it — the value *and* the reason, which is the whole point of
this milestone. `Lab subnet` and `Latitude naming` do not appear because neither
matched: this machine is not on `10.20.30.1` and is not a Latitude.

The fake filesystem is used above only so the command runs against a checked-out
repository rather than a real share. In a deployment the real adapter is passed
instead, and the whole workspace is read from `\\server\HdtShare`.

### Writing the provenance out

```powershell
Export-HDTVariableProvenance -Resolution $r `
    -Path 'X:\HDT\Logs\Gather\provenance.json' -FileSystem (New-HDTFileSystem)
```

That is DESIGN 4.4's `Gather\provenance.json`: `schemaVersion`, `generated`, and
one entry per variable carrying its source, rule, file, raw value and order.
