# NO VARIABLE RENDERS AS THE NAME OF ITS TYPE, ON ANY SURFACE A PERSON READS.
#
# FOUND ON A LIVE MACHINE. A multi-homed machine's resolved-variable output said
#
#     HDTIPAddress = 'System.Object[]' (GatheredFact)
#
# which is its own addresses rendered as a type name. The cause is the format
# operator: `'{1}' -f $name, $value, $source` builds an argument ARRAY, and an
# array argument NESTS instead of flattening, so {1} holds an Object[] and
# .ToString() on one is 'System.Object[]'. Nothing about that is specific to
# HDTIPAddress - every array-valued variable renders the same way, and the next
# one added will too.
#
# SO THE ASSERTIONS ARE DRIVEN OFF THE SET, NOT OFF HDTIPAddress. The fact table
# is enumerated as Get-HDTMachineFact produced it and EVERY array-valued key is
# asserted, so a fourth multi-valued fact added tomorrow is covered by these
# tests on the day it is added rather than by a test somebody remembers to
# write. Today the set is HDTMacAddress, HDTIPAddress and HDTDefaultGateway.
#
# AND OFF THE SET OF SURFACES. A variable reaches a person through the log
# stream, through the gather step's "what changed" lines, through the HTML
# report's variable table and through the provenance export. All four are
# asserted here; the export is JSON and holds a real array, which is the one
# shape a machine reads rather than a person.
#
# THE FIXTURE IS CAPTURED, NOT INVENTED. tests/fixtures/cim holds a real
# Win32_NetworkAdapterConfiguration capture with nine IP-enabled adapters and
# twenty-seven addresses between them - the multi-homed machine this defect
# needs, without one attached.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:cimFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim'
    $script:tpmFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim-microsofttpm'
    $script:tpmNamespace = 'root/cimv2/security/microsofttpm'

    $script:newCim = {
        $instance = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $script:cimFixturePath -Filter '*.json' -File)) {
            $instance[$file.BaseName] = [object[]] @(Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json)
        }

        return New-HDTFakeCimProvider -Instance $instance `
            -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }
    }

    # THE SET, computed rather than listed. Anything Get-HDTMachineFact stores
    # as a list is a candidate for this defect, whatever it is called.
    $script:multiValued = {
        param([System.Collections.IDictionary] $Fact)

        return @(@($Fact.Keys) | Where-Object {
                $value = $Fact[$_]
                ($null -ne $value) -and ($value -is [System.Collections.IList]) -and -not ($value -is [string])
            })
    }
}

Describe 'a multi-valued variable on a surface a person reads' {

    BeforeEach {
        $script:cim = & $script:newCim
        $script:registry = New-HDTFakeRegistryService
        $script:environment = New-HDTFakeEnvironmentProvider
        $script:fact = Get-HDTMachineFact -CimProvider $script:cim `
            -RegistryService $script:registry -EnvironmentProvider $script:environment

        $script:names = & $script:multiValued $script:fact
    }

    Context 'the fixture is the multi-homed machine this needs' {

        It 'gathers more than one address, or these assertions prove nothing' {
            @($script:fact['HDTIPAddress']).Count | Should -BeGreaterThan 1
        }

        It 'has at least one array valued fact to render' {
            @($script:names).Count | Should -BeGreaterThan 0
        }
    }

    Context 'the log stream, which is what a technician reads first' {

        BeforeEach {
            $script:fs = New-HDTFakeFileSystem
            $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 28, 9, 0, 0, [System.DateTimeKind]::Utc))
            $script:log = New-HDTLogContext -RunId 'run-render' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fs -Clock $script:clock -Level Debug

            $script:resolution = Resolve-HDTVariable -Fact $script:fact
            Write-HDTVariableLog -Context $script:log -Resolution $script:resolution

            $script:record = @(Get-HDTRunLogRecord -Context $script:log |
                    Where-Object { $_.Event -eq 'var.resolve' })
        }

        It 'writes no record whose message names a type instead of a value' {
            @($script:record | Where-Object { $_.Message -match 'System\.(Object|String)\[\]' }) |
                Should -BeNullOrEmpty
        }

        It 'writes every array valued fact as its comma delimited addresses' {
            foreach ($name in $script:names) {
                $entry = @($script:record | Where-Object { $_.Data.name -eq $name })
                $entry.Count | Should -Be 1 -Because ('{0} needs exactly one var.resolve record' -f $name)

                $expected = InModuleScope Hephaestus -Parameters @{ Value = $script:fact[$name] } {
                    param($Value)
                    ConvertTo-HDTVariableText -Value $Value
                }

                $entry[0].Message | Should -BeExactly ("{0} = '{1}' (GatheredFact)" -f $name, $expected)
            }
        }

        It 'writes the addresses themselves, not a count of them' {
            $entry = @($script:record | Where-Object { $_.Data.name -eq 'HDTIPAddress' })

            foreach ($address in @($script:fact['HDTIPAddress'])) {
                $entry[0].Message | Should -BeLike ('*{0}*' -f $address)
            }
        }

        It 'keeps the source in the message rather than an array element' {
            # The nested-array bug does not only render {1} wrongly; the
            # remaining arguments shift, so the source can be printed as the
            # second address of the machine.
            $entry = @($script:record | Where-Object { $_.Data.name -eq 'HDTIPAddress' })

            $entry[0].Message | Should -BeLike '*(GatheredFact)'
        }

        It 'still renders a single valued fact exactly as before' {
            $entry = @($script:record | Where-Object { $_.Data.name -eq 'HDTMake' })

            $entry[0].Message | Should -BeExactly ("HDTMake = '{0}' (GatheredFact)" -f $script:fact['HDTMake'])
        }
    }

    Context 'the gather step, which logs what moved between two gathers' {

        BeforeEach {
            $script:fs = New-HDTFakeFileSystem
            $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 28, 9, 0, 0, [System.DateTimeKind]::Utc))
            $script:catalog = New-HDTServiceCatalog -FileSystem $script:fs -Clock $script:clock `
                -Cim $script:cim -Registry $script:registry -Environment $script:environment
            $script:stepLog = New-HDTLogContext -RunId 'run-render' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fs -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $script:context = New-HDTExecutionContext -RunId 'run-render' -Phase WinPE `
                -WorkspaceRoot 'Z:\Deploy' -Variable $live -Service $script:catalog -Log $script:stepLog

            $script:step = [pscustomobject] @{
                Name            = 'Gather'
                Type            = 'Gather'
                Index           = 1
                GroupPath       = @('Initialization')
                RunIn           = 'WinPE'
                Condition       = ''
                Disabled        = $false
                ContinueOnError = $false
                Property        = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
        }

        It 'logs no change line that names a type instead of a value' {
            [void] (Invoke-HDTGatherStep -Step $script:step -Context $script:context)

            $line = @(Get-HDTRunLogRecord -Context $script:stepLog |
                    Where-Object { $_.Event -eq 'var.resolve' })

            @($line | Where-Object { $_.Message -match 'System\.(Object|String)\[\]' }) | Should -BeNullOrEmpty
        }

        It 'names the addresses it found in the change line' {
            [void] (Invoke-HDTGatherStep -Step $script:step -Context $script:context)

            $line = @(Get-HDTRunLogRecord -Context $script:stepLog |
                    Where-Object { $_.Event -eq 'var.resolve' -and $_.Message -like 'HDTIPAddress:*' })

            $line.Count | Should -Be 1
            $line[0].Message | Should -BeLike ('*{0}*' -f @($script:fact['HDTIPAddress'])[0])
        }

        It 'reports a second gather of the same machine as no change' {
            # The comparison behind the change line has to agree with the
            # rendering, or a multi-valued fact reports itself as having moved
            # on every gather.
            #
            # IT COUNTS CHANGE LINES, NOT EVERY var.resolve RECORD, and the
            # difference is the whole point of the assertion. This used to count
            # the event, which worked only while the change line was the sole
            # thing the step wrote under that name. It is not: a fact the machine
            # could not determine is reported on EVERY gather, correctly - "the
            # asset tag is still unreadable" does not stop being true the second
            # time somebody asks. Counting the event made a healthy second gather
            # look like a regression and would have to be re-edited every time a
            # fact was added.
            #
            # The arrow is what makes a record a change line, so that is what is
            # counted.
            [void] (Invoke-HDTGatherStep -Step $script:step -Context $script:context)

            $changeLine = {
                return @(Get-HDTRunLogRecord -Context $script:stepLog |
                        Where-Object { $_.Event -eq 'var.resolve' -and $_.Message -like '* -> *' })
            }

            $before = @(& $changeLine).Count

            [void] (Invoke-HDTGatherStep -Step $script:step -Context $script:context)

            @(& $changeLine).Count | Should -Be $before -Because (
                'nothing about the machine moved between the two gathers, so the second must report no change')
        }

        It 'still says what it could not determine on the second gather' {
            # THE OTHER HALF OF THE SAME RULE. A fact the machine cannot answer is
            # reported every time it is asked; a step that said so once and then
            # went quiet would leave the second gather looking like it succeeded
            # where the first did not.
            [void] (Invoke-HDTGatherStep -Step $script:step -Context $script:context)

            $undetermined = {
                return @(Get-HDTRunLogRecord -Context $script:stepLog |
                        Where-Object { $_.Event -eq 'var.resolve' -and $_.Message -like '*could not be determined*' })
            }

            $first = @(& $undetermined).Count

            [void] (Invoke-HDTGatherStep -Step $script:step -Context $script:context)

            @(& $undetermined).Count | Should -Be ($first * 2) -Because (
                'each gather reports its own outcome, so a fact that stayed unreadable is named again')
        }

        It 'writes every var.resolve record in a shape a reader can parse' {
            # ASSERTED OVER THE SET, so a record added later cannot arrive in a
            # shape nothing else uses. Three commands already write this event -
            # Write-HDTVariableLog, Invoke-HDTSetVariableStep and this step - and
            # a fourth format is how a consumer filtering on the name starts
            # getting lines it cannot read.
            [void] (Invoke-HDTGatherStep -Step $script:step -Context $script:context)

            $record = @(Get-HDTRunLogRecord -Context $script:stepLog |
                    Where-Object { $_.Event -eq 'var.resolve' })

            $record.Count | Should -BeGreaterThan 0

            foreach ($one in $record) {
                $one.Message | Should -Not -BeNullOrEmpty
                $one.Message | Should -Match '^HDT[A-Za-z0-9_]+:' -Because (
                    'every record this step writes names the fact it is about first')
                $one.Message | Should -Not -Match "`n" -Because (
                    'a multi-line message is unreadable in CMTrace and cannot be filtered')
            }
        }

        It 'accounts for every fact it could not determine, rather than a chosen few' {
            # THE SET AGAIN: the names reported as undetermined must be exactly
            # the facts that came back empty, not a list somebody maintains.
            [void] (Invoke-HDTGatherStep -Step $script:step -Context $script:context)

            $named = @(Get-HDTRunLogRecord -Context $script:stepLog |
                    Where-Object { $_.Event -eq 'var.resolve' -and $_.Message -like '*could not be determined*' } |
                    ForEach-Object { ([string] $_.Message -split ':')[0] })

            foreach ($name in $named) {
                $script:context.Variable.Contains($name) | Should -BeTrue -Because (
                    "$name is reported as undetermined and must still be a variable the sequence can read")
            }
        }
    }

    Context 'the HTML report, which is what somebody sends on afterwards' {

        BeforeEach {
            $script:fs = New-HDTFakeFileSystem
            $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 28, 9, 0, 0, [System.DateTimeKind]::Utc))
            $script:log = New-HDTLogContext -RunId 'run-render' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fs -Clock $script:clock -Level Debug

            $script:resolution = Resolve-HDTVariable -Fact $script:fact
            Write-HDTVariableLog -Context $script:log -Resolution $script:resolution

            [void] (ConvertTo-HDTReport -JsonlPath 'X:\HDT\Logs\HDT.jsonl' `
                    -Path 'X:\HDT\Logs\report.html' -FileSystem $script:fs)
            $script:html = $script:fs.ReadAllText('X:\HDT\Logs\report.html')
        }

        It 'renders no variable cell as the name of a type' {
            $script:html | Should -Not -Match 'System\.(Object|String)\[\]'
        }

        It 'renders a multi valued fact comma delimited, as the rule engine does' {
            $expected = InModuleScope Hephaestus -Parameters @{ Value = $script:fact['HDTIPAddress'] } {
                param($Value)
                ConvertTo-HDTVariableText -Value $Value
            }

            $script:html | Should -BeLike ('*{0}*' -f $expected)
        }
    }

    Context 'the provenance export, which is read by a machine' {

        It 'keeps a real JSON array rather than a rendered string' {
            $fs = New-HDTFakeFileSystem
            $resolution = Resolve-HDTVariable -Fact $script:fact

            Export-HDTVariableProvenance -Resolution $resolution -Path 'X:\HDT\Logs\provenance.json' `
                -FileSystem $fs -Timestamp ([datetime]::new(2026, 8, 28, 9, 0, 0, [System.DateTimeKind]::Utc))

            $document = $fs.ReadAllText('X:\HDT\Logs\provenance.json') | ConvertFrom-Json
            $entry = @($document.variable | Where-Object { $_.name -eq 'HDTIPAddress' })

            @($entry[0].value).Count | Should -Be @($script:fact['HDTIPAddress']).Count
        }
    }
}

Describe 'a multi-valued fact round trips into a when clause' {

    BeforeEach {
        $script:cim = & $script:newCim
        $script:fact = Get-HDTMachineFact -CimProvider $script:cim `
            -RegistryService (New-HDTFakeRegistryService) `
            -EnvironmentProvider (New-HDTFakeEnvironmentProvider)

        $script:fs = New-HDTFakeFileSystem
    }

    It 'fires a rule keyed on the second address of a multi-homed machine' {
        # THE QUESTION THE DEFECT RAISED: could `when: { HDTIPAddress: ... }`
        # ever have matched? It could, and it still must. Test-HDTRuleMatch
        # matches a list on ANY element, so the rendering defect never reached
        # rule matching - the list arrives at the comparison intact.
        $second = @($script:fact['HDTIPAddress'])[2]

        $yaml = @'
schemaVersion: 1
rules:
  - name: Second address
    when:
      HDTIPAddress: "__ADDRESS__"
    set:
      HDTDriverGroup: Bench
'@
        $yaml = $yaml.Replace('__ADDRESS__', $second)
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\rules.yaml' = $yaml }

        $document = Import-HDTRuleDocument -Path 'C:\ws\rules.yaml' -FileSystem $fs
        $resolution = Resolve-HDTVariable -Fact $script:fact -RuleDocument $document

        $resolution.Variable['HDTDriverGroup'] | Should -BeExactly 'Bench'
        $resolution.Provenance['HDTDriverGroup'].Rule | Should -BeExactly 'Second address'
    }

    It 'does not fire on an address the machine does not have' {
        $yaml = @'
schemaVersion: 1
rules:
  - name: Second address
    when:
      HDTIPAddress: "203.0.113.9"
    set:
      HDTDriverGroup: Bench
'@
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\rules.yaml' = $yaml }

        $document = Import-HDTRuleDocument -Path 'C:\ws\rules.yaml' -FileSystem $fs
        $resolution = Resolve-HDTVariable -Fact $script:fact -RuleDocument $document

        $resolution.Variable.Contains('HDTDriverGroup') | Should -BeFalse
    }

    It 'substitutes the whole list into a rule that names the variable' {
        $yaml = @'
schemaVersion: 1
rules:
  - name: Record the addresses
    set:
      HDTBenchNote: "seen %HDTIPAddress%"
'@
        $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\rules.yaml' = $yaml }

        $document = Import-HDTRuleDocument -Path 'C:\ws\rules.yaml' -FileSystem $fs
        $resolution = Resolve-HDTVariable -Fact $script:fact -RuleDocument $document

        $expected = InModuleScope Hephaestus -Parameters @{ Value = $script:fact['HDTIPAddress'] } {
            param($Value)
            ConvertTo-HDTVariableText -Value $Value
        }

        $resolution.Variable['HDTBenchNote'] | Should -BeExactly ('seen {0}' -f $expected)
    }
}
