# Resolve-HDTVariable is ROADMAP M1's exit criterion in one function: five-source
# precedence, first-match-wins per variable, %Var% expansion, setFrom: script
# rules - and a provenance record for every value.
#
# It takes NO filesystem service. The rule document and the machine override are
# loaded by their own functions and handed in, which is why every test in this
# file runs with no I/O double except the script invoker, and why the engine is
# pure enough to reason about.
#
# Rule documents are built by running real YAML through Import-HDTRuleDocument
# against a fake filesystem rather than by hand-assembling objects: the shape
# under test is then exactly the shape the workspace produces, normalisation
# included.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:rulesPath = 'C:\HDTLab\does-not-exist\ws\rules.yaml'

    function New-HDTTestRuleDocument {
        <#
            .SYNOPSIS
                Turns rules.yaml text into the document Resolve-HDTVariable consumes,
                through the real importer and a fake filesystem.
        #>
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true, Position = 0)]
            [string] $Yaml
        )

        $fs = New-HDTFakeFileSystem -File @{ $script:rulesPath = $Yaml }
        return (Import-HDTRuleDocument -Path $script:rulesPath -FileSystem $fs)
    }
}

Describe 'Resolve-HDTVariable' {

    Context 'precedence across all five sources' {

        BeforeEach {
            $script:rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Lab subnet
    set:
      HDTTaskSequenceID: RULE-CLIENT
'@

            # One variable, offered by every source at once. Each test removes
            # the sources above the one it is proving.
            $script:source = @{
                CommandLine     = @{ HDTTaskSequenceID = 'CMD-CLIENT' }
                MachineOverride = @{ HDTTaskSequenceID = 'OVR-CLIENT' }
                RuleDocument    = $script:rules
                Fact            = @{ HDTTaskSequenceID = 'FACT-CLIENT' }
                SequenceDefault = @{ HDTTaskSequenceID = 'DEF-CLIENT' }
            }
        }

        It 'prefers the command line over everything' {
            $result = Resolve-HDTVariable @script:source

            $result.Variable['HDTTaskSequenceID'] | Should -BeExactly 'CMD-CLIENT'
        }

        It 'prefers the machine override over rules, facts and defaults' {
            $script:source.Remove('CommandLine')

            $result = Resolve-HDTVariable @script:source

            $result.Variable['HDTTaskSequenceID'] | Should -BeExactly 'OVR-CLIENT'
        }

        It 'prefers a rule over facts and defaults' {
            $script:source.Remove('CommandLine')
            $script:source.Remove('MachineOverride')

            $result = Resolve-HDTVariable @script:source

            $result.Variable['HDTTaskSequenceID'] | Should -BeExactly 'RULE-CLIENT'
        }

        It 'prefers a fact over a sequence default' {
            $script:source.Remove('CommandLine')
            $script:source.Remove('MachineOverride')
            $script:source.Remove('RuleDocument')

            $result = Resolve-HDTVariable @script:source

            $result.Variable['HDTTaskSequenceID'] | Should -BeExactly 'FACT-CLIENT'
        }

        It 'falls back to the sequence default when nothing else supplies a value' {
            $result = Resolve-HDTVariable -SequenceDefault $script:source.SequenceDefault

            $result.Variable['HDTTaskSequenceID'] | Should -BeExactly 'DEF-CLIENT'
        }

        It 'records the winning source in provenance for each of the five cases' {
            $expected = @(
                @{ Remove = @(); Source = 'CommandLine' }
                @{ Remove = @('CommandLine'); Source = 'MachineOverride' }
                @{ Remove = @('CommandLine', 'MachineOverride'); Source = 'Rule' }
                @{ Remove = @('CommandLine', 'MachineOverride', 'RuleDocument'); Source = 'GatheredFact' }
                @{ Remove = @('CommandLine', 'MachineOverride', 'RuleDocument', 'Fact'); Source = 'SequenceDefault' }
            )

            foreach ($case in $expected) {
                $splat = @{}
                foreach ($key in @($script:source.Keys)) { $splat[$key] = $script:source[$key] }
                foreach ($key in @($case.Remove)) { $splat.Remove($key) }

                $result = Resolve-HDTVariable @splat

                $result.Provenance['HDTTaskSequenceID'].Source |
                    Should -BeExactly $case.Source -Because ('removing {0} must leave {1} winning' -f (@($case.Remove) -join ', '), $case.Source)
            }
        }

        It 'resolves a variable that only one source supplies' {
            $result = Resolve-HDTVariable @script:source

            $result.Variable.Contains('HDTTaskSequenceID') | Should -BeTrue
            @($result.Variable.Keys).Count | Should -Be 1
        }

        It 'resolves nothing when no source supplies anything' {
            $result = Resolve-HDTVariable

            @($result.Variable.Keys).Count | Should -Be 0
            @($result.Provenance.Keys).Count | Should -Be 0
        }
    }

    Context 'first match wins per variable' {

        It 'lets an earlier rule win a variable' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: First
    set:
      HDTComputerName: FIRST
  - name: Second
    set:
      HDTComputerName: SECOND
'@

            $result = Resolve-HDTVariable -RuleDocument $rules

            $result.Variable['HDTComputerName'] | Should -BeExactly 'FIRST'
            $result.Provenance['HDTComputerName'].Rule | Should -BeExactly 'First'
        }

        It 'lets a later rule fill a variable the earlier rule did not set' {
            # DESIGN 3.3's Fallback: a later rule acts as a fallback for exactly
            # the variables nothing above it set.
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Lab subnet
    set:
      HDTJoinDomain: lab.contoso.com
  - name: Fallback
    set:
      HDTJoinDomain: fallback.contoso.com
      HDTJoinWorkgroup: WORKGROUP
'@

            $result = Resolve-HDTVariable -RuleDocument $rules

            $result.Variable['HDTJoinDomain'] | Should -BeExactly 'lab.contoso.com'
            $result.Variable['HDTJoinWorkgroup'] | Should -BeExactly 'WORKGROUP'
            $result.Provenance['HDTJoinWorkgroup'].Rule | Should -BeExactly 'Fallback'
        }

        It 'applies set keys in document order' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Ordered
    set:
      HDTOne: 1
      HDTTwo: 2
      HDTThree: 3
'@

            $result = Resolve-HDTVariable -RuleDocument $rules

            @($result.Variable.Keys) | Should -Be @('HDTOne', 'HDTTwo', 'HDTThree')
            @(@($result.Provenance.Values) | ForEach-Object { $_.Order }) | Should -Be @(1, 2, 3)
        }

        It 'lets a later key in the same rule expand a value the earlier key set' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Site naming
    set:
      HDTSitePrefix: LAB
      HDTComputerName: "%HDTSitePrefix%-01"
'@

            $result = Resolve-HDTVariable -RuleDocument $rules

            $result.Variable['HDTComputerName'] | Should -BeExactly 'LAB-01'
        }

        It 'lets a later rule match on a value an earlier rule set' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Site
    set:
      HDTSite: LAB
  - name: Site domain
    when: { HDTSite: LAB }
    set:
      HDTJoinDomain: lab.contoso.com
'@

            $result = Resolve-HDTVariable -RuleDocument $rules

            $result.Variable['HDTJoinDomain'] | Should -BeExactly 'lab.contoso.com'
        }

        It 'skips a rule whose when does not match' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Latitude naming
    when: { HDTModel: "Latitude*" }
    set:
      HDTDriverGroup: "Dell\\%HDTModel%"
'@

            $result = Resolve-HDTVariable -RuleDocument $rules -Fact @{ HDTModel = '82RF' }

            $result.Variable.Contains('HDTDriverGroup') | Should -BeFalse
        }

        It 'evaluates every rule even after one has matched' {
            # Rules are not short-circuited; only VARIABLES are. A rule further
            # down still applies to every variable nothing above it set.
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: First
    set:
      HDTOne: 1
  - name: Second
    set:
      HDTTwo: 2
  - name: Third
    set:
      HDTThree: 3
'@

            $result = Resolve-HDTVariable -RuleDocument $rules

            @($result.Variable.Keys) | Should -Be @('HDTOne', 'HDTTwo', 'HDTThree')
        }
    }

    Context 'facts and matching' {

        It 'matches a rule against a gathered fact' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Latitude naming
    when: { HDTModel: "Latitude*", HDTIsLaptop: true }
    set:
      HDTDriverGroup: "Dell\\%HDTModel%"
'@

            $result = Resolve-HDTVariable -RuleDocument $rules -Fact @{ HDTModel = 'Latitude 7450'; HDTIsLaptop = $true }

            $result.Variable['HDTDriverGroup'] | Should -BeExactly 'Dell\Latitude 7450'
        }

        It 'matches a rule against a value the machine override set' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Finance
    when: { HDTDepartment: Finance }
    set:
      HDTJoinDomain: fin.contoso.com
'@

            $result = Resolve-HDTVariable -RuleDocument $rules -MachineOverride @{ HDTDepartment = 'Finance' }

            $result.Variable['HDTJoinDomain'] | Should -BeExactly 'fin.contoso.com'
        }

        It 'expands a %Var% naming a fact' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Fallback
    set:
      HDTComputerName: "LT-%HDTSerialNumber%"
'@

            $result = Resolve-HDTVariable -RuleDocument $rules -Fact @{ HDTSerialNumber = 'FIXTURE-SERIAL-0001' }

            $result.Variable['HDTComputerName'] | Should -BeExactly 'LT-FIXTURE-SERIAL-0001'
        }

        It 'expands a %Var% naming a sequence default' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Layout note
    set:
      HDTLayoutNote: "layout=%HDTDiskLayout%"
'@

            $result = Resolve-HDTVariable -RuleDocument $rules -SequenceDefault @{ HDTDiskLayout = 'uefi-standard' }

            $result.Variable['HDTLayoutNote'] | Should -BeExactly 'layout=uefi-standard'
        }
    }

    Context 'setFrom' {

        BeforeEach {
            $script:setFromRules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Scripted name for laptops
    when: { HDTIsLaptop: true }
    setFrom: Scripts\Get-ComputerName.ps1
'@

            $script:fact = @{ HDTIsLaptop = $true; HDTSerialNumber = 'FIXTURE-SERIAL-0001' }

            $script:invoker = New-HDTFakeScriptInvoker -Result @{
                'Scripts/Get-ComputerName.ps1' = [pscustomobject] @{ HDTAssetTag = 'ASSET-FIXTURE-SERIAL-0001' }
            }
        }

        It 'sets the variables the script returned' {
            $result = Resolve-HDTVariable -RuleDocument $script:setFromRules -Fact $script:fact -ScriptInvoker $script:invoker

            $result.Variable['HDTAssetTag'] | Should -BeExactly 'ASSET-FIXTURE-SERIAL-0001'
        }

        It 'records the source as RuleScript' {
            $result = Resolve-HDTVariable -RuleDocument $script:setFromRules -Fact $script:fact -ScriptInvoker $script:invoker

            $result.Provenance['HDTAssetTag'].Source | Should -BeExactly 'RuleScript'
            $result.Provenance['HDTAssetTag'].Rule | Should -BeExactly 'Scripted name for laptops'
        }

        It 'records the script path as the File' {
            $result = Resolve-HDTVariable -RuleDocument $script:setFromRules -Fact $script:fact -ScriptInvoker $script:invoker

            $result.Provenance['HDTAssetTag'].File | Should -BeExactly 'Scripts\Get-ComputerName.ps1'
        }

        It 'passes the current scope to the invoker' {
            $null = Resolve-HDTVariable -RuleDocument $script:setFromRules -Fact $script:fact -ScriptInvoker $script:invoker

            $script:invoker.Operations.Count | Should -Be 1
            $script:invoker.Operations[0].Arguments[0] | Should -BeExactly 'Scripts\Get-ComputerName.ps1'
            $script:invoker.Operations[0].Arguments[1]['HDTSerialNumber'] | Should -BeExactly 'FIXTURE-SERIAL-0001'
        }

        It 'passes a copy, so a script cannot mutate engine state' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Scripted name for laptops
    when: { HDTIsLaptop: true }
    setFrom: Scripts\Get-ComputerName.ps1
  - name: Fallback
    set:
      HDTComputerName: "PC-%HDTSerialNumber%"
'@

            $tampering = [pscustomobject] @{ }
            $tampering | Add-Member -MemberType ScriptMethod -Name Invoke -Value {
                param([string] $Path, [System.Collections.IDictionary] $Variable)

                $Variable['HDTSerialNumber'] = 'TAMPERED'
                $Variable['HDTInjected'] = 'from the script'

                return [pscustomobject] @{ HDTAssetTag = 'ASSET-1' }
            }

            $result = Resolve-HDTVariable -RuleDocument $rules -Fact $script:fact -ScriptInvoker $tampering

            $result.Variable['HDTComputerName'] | Should -BeExactly 'PC-FIXTURE-SERIAL-0001'
            $result.Variable.Contains('HDTInjected') | Should -BeFalse
        }

        It 'accepts a hashtable return as well as a pscustomobject' {
            $invoker = New-HDTFakeScriptInvoker -Result @{
                'Scripts/Get-ComputerName.ps1' = @{ HDTAssetTag = 'ASSET-FROM-HASHTABLE' }
            }

            $result = Resolve-HDTVariable -RuleDocument $script:setFromRules -Fact $script:fact -ScriptInvoker $invoker

            $result.Variable['HDTAssetTag'] | Should -BeExactly 'ASSET-FROM-HASHTABLE'
        }

        It 'sets nothing when the script returns null' {
            $invoker = New-HDTFakeScriptInvoker -Result @{ 'Scripts/Get-ComputerName.ps1' = $null }

            $result = Resolve-HDTVariable -RuleDocument $script:setFromRules -Fact $script:fact -ScriptInvoker $invoker

            # The two gathered facts resolve; nothing else does. A $null return
            # is "the script ran and had nothing to say", not a failure.
            $result.Variable.Contains('HDTAssetTag') | Should -BeFalse
            @($result.Variable.Keys).Count | Should -Be 2
        }

        It 'does not overwrite an already-resolved variable' {
            $result = Resolve-HDTVariable -CommandLine @{ HDTAssetTag = 'ASSET-FROM-COMMAND-LINE' } `
                -RuleDocument $script:setFromRules -Fact $script:fact -ScriptInvoker $script:invoker

            $result.Variable['HDTAssetTag'] | Should -BeExactly 'ASSET-FROM-COMMAND-LINE'
            $result.Provenance['HDTAssetTag'].Source | Should -BeExactly 'CommandLine'
        }

        It 'does not invoke the script when the rule does not match' {
            $null = Resolve-HDTVariable -RuleDocument $script:setFromRules `
                -Fact @{ HDTIsLaptop = $false } -ScriptInvoker $script:invoker

            $script:invoker.Operations.Count | Should -Be 0
        }

        It 'throws a configuration error naming the rule when no script invoker was supplied' {
            $record = $null
            try {
                Resolve-HDTVariable -RuleDocument $script:setFromRules -Fact $script:fact
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike "*Scripted name for laptops*"
        }

        It 'throws a configuration error naming the rule and script when the script throws' {
            $failing = [pscustomobject] @{ }
            $failing | Add-Member -MemberType ScriptMethod -Name Invoke -Value {
                param([string] $Path, [System.Collections.IDictionary] $Variable)

                throw 'the script blew up'
            }

            $record = $null
            try {
                Resolve-HDTVariable -RuleDocument $script:setFromRules -Fact $script:fact -ScriptInvoker $failing
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*Scripted name for laptops*'
            $record.Exception.Message | Should -BeLike '*Scripts\Get-ComputerName.ps1*'
        }

        It 'keeps the script exception as the inner exception' {
            $failing = [pscustomobject] @{ }
            $failing | Add-Member -MemberType ScriptMethod -Name Invoke -Value {
                param([string] $Path, [System.Collections.IDictionary] $Variable)

                throw 'the script blew up'
            }

            $record = $null
            try {
                Resolve-HDTVariable -RuleDocument $script:setFromRules -Fact $script:fact -ScriptInvoker $failing
            } catch {
                $record = $_
            }

            $record.Exception.InnerException | Should -Not -BeNullOrEmpty
            $record.Exception.InnerException.Message | Should -BeLike '*the script blew up*'
        }

        It 'throws when the script returns an engine variable' {
            $engineVariable = [pscustomobject] @{ }
            $engineVariable | Add-Member -MemberType ScriptMethod -Name Invoke -Value {
                param([string] $Path, [System.Collections.IDictionary] $Variable)

                return [pscustomobject] @{ _HDTLogPath = 'X:\HDT\Logs' }
            }

            $record = $null
            try {
                Resolve-HDTVariable -RuleDocument $script:setFromRules -Fact $script:fact -ScriptInvoker $engineVariable
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.Exception.Message | Should -BeLike '*_HDTLogPath*'
            $record.Exception.Message | Should -BeLike '*Scripted name for laptops*'
        }
    }

    Context 'provenance' {

        BeforeEach {
            $script:rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Lab subnet
    when: { HDTDefaultGateway: "10.20.30.1" }
    set:
      HDTJoinDomain: lab.contoso.com
  - name: Fallback
    set:
      HDTComputerName: "PC-%HDTSerialNumber%"
'@

            $script:result = Resolve-HDTVariable `
                -CommandLine @{ HDTTaskSequenceID = 'CMD-CLIENT' } `
                -MachineOverride @{ HDTDepartment = 'Finance' } `
                -MachineOverridePath 'C:\ws\Control\machines\FIXTURE.yaml' `
                -RuleDocument $script:rules `
                -Fact @{ HDTSerialNumber = 'FIXTURE-SERIAL-0001'; HDTDefaultGateway = @('10.20.30.254', '10.20.30.1') } `
                -SequenceDefault @{ HDTDiskLayout = 'uefi-standard' }
        }

        It 'produces a provenance record for every resolved variable' {
            foreach ($name in @($script:result.Variable.Keys)) {
                $script:result.Provenance.Contains($name) | Should -BeTrue -Because "$name was resolved and must be explained"
            }

            @($script:result.Provenance.Keys).Count | Should -Be @($script:result.Variable.Keys).Count
        }

        It 'produces no provenance record for a variable nothing set' {
            $script:result.Provenance.Contains('HDTNeverSet') | Should -BeFalse
        }

        It 'orders provenance records by resolution order' {
            $order = @(@($script:result.Provenance.Values) | ForEach-Object { $_.Order })

            $order | Should -Be @(1..$order.Count)
        }

        It 'records only sources from the closed set' {
            $closed = @('CommandLine', 'MachineOverride', 'Rule', 'RuleScript', 'GatheredFact', 'SequenceDefault')

            foreach ($record in @($script:result.Provenance.Values)) {
                $closed | Should -Contain $record.Source
            }
        }

        It 'records the rules file as the File for a rule-sourced variable' {
            $script:result.Provenance['HDTJoinDomain'].Source | Should -BeExactly 'Rule'
            $script:result.Provenance['HDTJoinDomain'].File | Should -BeExactly $script:rulesPath
        }

        It 'records the rule index' {
            $script:result.Provenance['HDTJoinDomain'].RuleIndex | Should -Be 1
            $script:result.Provenance['HDTComputerName'].RuleIndex | Should -Be 2
        }
    }

    Context 'unresolved tokens' {

        BeforeEach {
            $script:rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Fallback
    set:
      HDTComputerName: "PC-%HDTNeverGathered%"
      HDTDriverGroup: "Dell\\%HDTNeverGathered%"
      HDTJoinDomain: "%HDTSite%.contoso.com"
'@
        }

        It 'reports an unresolved token in Unresolved' {
            $result = Resolve-HDTVariable -RuleDocument $script:rules -Fact @{ HDTSite = 'lab' }

            $result.Unresolved | Should -Contain 'HDTNeverGathered'
        }

        It 'leaves the token literal in the value' {
            $result = Resolve-HDTVariable -RuleDocument $script:rules -Fact @{ HDTSite = 'lab' }

            $result.Variable['HDTComputerName'] | Should -BeExactly 'PC-%HDTNeverGathered%'
        }

        It 'reports each unresolved token once' {
            $result = Resolve-HDTVariable -RuleDocument $script:rules -Fact @{ HDTSite = 'lab' }

            @($result.Unresolved).Count | Should -Be 1
        }

        It 'reports nothing in Unresolved when every token resolved' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Fallback
    set:
      HDTComputerName: "PC-%HDTSerialNumber%"
'@

            $result = Resolve-HDTVariable -RuleDocument $rules -Fact @{ HDTSerialNumber = 'FIXTURE-SERIAL-0001' }

            @($result.Unresolved).Count | Should -Be 0
        }
    }

    Context 'the shape of the result' {

        It 'returns Variable, Provenance and Unresolved' {
            $result = Resolve-HDTVariable -CommandLine @{ HDTTaskSequenceID = 'CMD-CLIENT' }

            @($result.PSObject.Properties.Name) | Should -Be @('Variable', 'Provenance', 'Unresolved')
            $result.Variable | Should -BeOfType ([System.Collections.Specialized.OrderedDictionary])
            $result.Provenance | Should -BeOfType ([System.Collections.Specialized.OrderedDictionary])
        }

        It 'looks a variable up case-insensitively' {
            $result = Resolve-HDTVariable -CommandLine @{ HDTTaskSequenceID = 'CMD-CLIENT' }

            $result.Variable['hdttasksequenceid'] | Should -BeExactly 'CMD-CLIENT'
            $result.Provenance['hdttasksequenceid'].Source | Should -BeExactly 'CommandLine'
        }

        It 'preserves resolution order in Variable' {
            $rules = New-HDTTestRuleDocument @'
schemaVersion: 1
rules:
  - name: Ordered
    set:
      HDTOne: 1
      HDTTwo: 2
'@

            $result = Resolve-HDTVariable -CommandLine @{ HDTZero = 0 } -RuleDocument $rules -SequenceDefault @{ HDTLast = 'last' }

            @($result.Variable.Keys) | Should -Be @('HDTZero', 'HDTOne', 'HDTTwo', 'HDTLast')
        }

        It 'has comment-based help with a synopsis' {
            # Get-Command first: Get-Help alone answers with a stub for a command
            # that does not exist, and this assertion was observed passing before
            # the function was written.
            $command = Get-Command -Name Resolve-HDTVariable -Module Hephaestus -ErrorAction Stop
            $help = Get-Help -Name $command.Name -ErrorAction Stop

            $help.Synopsis | Should -Not -BeNullOrEmpty
            $help.Synopsis | Should -Not -Match 'Resolve-HDTVariable \['
        }

        It 'requires no parameters' {
            # Resolving nothing is a valid, empty answer rather than an error:
            # the engine calls this before it knows which sources exist.
            $mandatory = @((Get-Command -Name Resolve-HDTVariable).Parameters.Values |
                    Where-Object { @($_.Attributes | Where-Object { ($_ -is [System.Management.Automation.ParameterAttribute]) -and $_.Mandatory }).Count -gt 0 })

            $mandatory.Count | Should -Be 0
            { Resolve-HDTVariable } | Should -Not -Throw
        }
    }
}
