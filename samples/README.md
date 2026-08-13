# HDT samples

## `workspace/` — the variable and rule sample

A minimal workspace showing every feature of the resolution engine (DESIGN 3.1
and 3.3). Copy it and edit; it is the shape a real deployment share has, with the
parts M1 covers filled in.

```
workspace/
  rules.yaml                                                   the rules
  Control/machines/4C4C4544-0031-3610-8052-B7C04F515A31.yaml   a per-machine override
  Scripts/Get-ComputerName.ps1                                 a setFrom: extension script
  Scripts/Set-CorpBaseline.ps1                                 a PowerShell step script
  TaskSequences/DEMO-M2/sequence.yaml                          the runnable demonstration sequence
  TaskSequences/STD-CLIENT/sequence.yaml                       the realistic client build
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
not on the lab subnet — that prints the following. The serial is shown as the
repository's fixture serial rather than the real one, so that copying this file
does not publish a machine's identity; on your machine the two rows carrying it
read whatever `Win32_BIOS` reports:

```
Order Name                 Value                                           Source       Rule
----- ----                 -----                                           ------       ----
    1 HDTComputerName      PC-FIXTURE-SERIAL-0001                          Rule         Fallback
    2 HDTJoinWorkgroup     WORKGROUP                                       Rule         Fallback
    3 HDTMake              LENOVO                                          GatheredFact
    4 HDTModel             82RF                                            GatheredFact
    5 HDTProduct           LNVNB161216                                     GatheredFact
    6 HDTSerialNumber      FIXTURE-SERIAL-0001                             GatheredFact
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

---

## `workspace/TaskSequences/` — the sequence samples

Two sequences, for two different jobs.

### `DEMO-M2` — the one that runs today

Every step type M2 ships, nothing destructive, and every behaviour the execution
loop has: grouping, a group condition, `runIn` phase filtering, retry with
exponential backoff, `continueOnError`, and **two reboots with resume**. Three
legs come out of it: `Preinstall` in WinPE, `Install` after the first restart,
`State Restore` after the second — with `WinPE Only Task` skipped on phase,
`Optional Task` failing and tolerated, and both `Server Only` steps skipped on
the group condition.

It is the sequence `tests/unit/TaskSequence.EndToEnd.Tests.ps1` runs, seeded from
**this file's text**, so the sample and the test can never drift apart.

Two details worth copying correctly:

- `command:` on a `CommandLine` step carries the **bare** command line. The step
  wraps it in `%ComSpec% /c` itself, so writing `cmd.exe /c echo ...` would
  double-wrap it.
- a `condition:` is a **single-quoted** YAML scalar, because the condition
  grammar carries double quotes as part of itself.

Running it against fakes, from the repository root:

```powershell
Import-Module ./src/Hephaestus/Hephaestus.psd1 -Force
Import-Module ./tests/helpers/HDTFakes/HDTFakes.psd1 -Force
Import-Module ./tests/helpers/HDTTestTools/HDTTestTools.psd1 -Force

$harness = New-HDTSequenceTestHarness `
    -Yaml (Get-Content ./samples/workspace/TaskSequences/DEMO-M2/sequence.yaml -Raw) `
    -ProcessResult @{ 'cmd.exe /c echo HDT demo installer' = @{ ExitCode = 0 } }

$run = Invoke-HDTTaskSequence -Sequence $harness.Sequence -Context $harness.Context -State $harness.State

$run.Status                                   # RebootPending - the first leg ends at the Restart
$run.Result | Format-Table Index, Name, Type, Status, Attempt, Reason -AutoSize

ConvertTo-HDTReport -JsonlPath $harness.Log.JsonlPath -Path 'C:\HDTLab\scratch\report.html' `
    -FileSystem (New-HDTFileSystem) -State $run.State -Title 'DEMO-M2 leg 1'
```

Nothing there touches a machine: the process, power, registry and LSA services
are all doubles, and the only file that leaves the fake filesystem is the report
you asked for.

### `STD-CLIENT` — the realistic one

DESIGN 4.1's client build, as an administrator would actually write it:
`Validate`, `DiskPartition`, `ApplyImage`, `ApplyDrivers`, `ApplyUnattend`,
`ConfigureBoot`, `Restart`, then applications, Windows Update and a `PowerShell`
step.

**Most of those step types do not exist yet** — they arrive in phases 04 to 07 —
and that is the point of shipping it now: it imports and schema-validates today,
and `Test-HDTTaskSequence` reports each missing type as an `Error` finding, which
is the authoring lint doing its job.

```powershell
$fs = New-HDTFakeFileSystem -File @{
    'C:\ws\sequence.yaml' = (Get-Content ./samples/workspace/TaskSequences/STD-CLIENT/sequence.yaml -Raw) }

$sequence = Import-HDTSequenceDocument -Path 'C:\ws\sequence.yaml' -FileSystem $fs
Test-HDTTaskSequence -Sequence $sequence | Format-Table Severity, Step, Message -AutoSize
```

Its domain join is commented out and it defaults to a workgroup build, because
HDT's test lab switch is deliberately isolated from a domain controller
(`.planning/PROJECT.md`). Uncomment the step when you have a reachable DC.
