# ONE EVENT NAME MEANT THREE DIFFERENT THINGS, IN TWO GRAMMARS, AT TWO SEVERITIES.
#
# Three commands wrote var.resolve and no two of them wrote it alike:
#
#   Write-HDTVariableLog       HDTModel = 'x' (Rule)                        Debug
#   Invoke-HDTSetVariableStep  HDTModel = 'x' (Step)                        Info
#   Invoke-HDTGatherStep       HDTModel: old -> new, from CIM.Win32_...     Debug
#
# and the gather also filed two things that are not variable resolutions at all
# under the same name - "kept the resolved value" and "could not be determined" -
# as did both of the others' "token was never supplied" warnings.
#
# IT IS THE SHAPE OF TWO DEFECTS ALREADY FIXED. run.end's tally drifted because
# one number had two producers; logLevel was inert because one setting had a
# writer and no reader. DESIGN 4.4.2 calls event "a controlled vocabulary, so the
# report renderer and the console filter on a known set rather than regexing
# prose" - and a name that means three things cannot be filtered on at all.
#
# THE CONSUMER ALREADY SHOWED THE DAMAGE. ConvertTo-HDTReport is the only command
# in src/ that filters on var.resolve, and it renders each one as a row of
# Name/Value/Source/Rule read out of data. The gather's change lines carried NO
# data whatsoever, so every one of them rendered as a BLANK ROW in the report's
# Variables table, and so did every "could not be determined" line.
#
# THE SPLIT, AND WHY IT IS ONE NEW NAME RATHER THAN THREE:
#
#   var.resolve      this variable TOOK this value, and here is where from.
#                    True of a rule resolution, a step assignment and a gathered
#                    fact alike - the discriminator is data.source, which two of
#                    the three already carried. Giving them a name each would
#                    force every consumer to filter three names to answer one
#                    question, and grow the vocabulary with every writer added.
#
#   var.unresolved   this variable did NOT take a value: a %Var% token nothing
#                    supplied, a fact the machine could not determine, or a
#                    resolved value KEPT because the gather's answer was a
#                    non-answer. These are the opposite of a resolution, which is
#                    exactly why filing them under var.resolve put blank rows in
#                    the report.
#
# AND EVERY ASSERTION HERE IS DRIVEN OFF THE SET OF EMITTERS, not off the three
# that happened to be fixed. A fourth writer of either name is added to the table
# below and is covered by every test in this file on the day it lands - which is
# the failure mode that produced the defect: a test naming one emitter passes for
# it and fails nobody after it.

# DISCOVERY TIME, DELIBERATELY. A $script: variable assigned in BeforeAll reads
# $null in a -ForEach, so the names the cases are generated from are assigned
# here and the records they are asserted against are built in BeforeAll.
$emitterName = @('Write-HDTVariableLog', 'Invoke-HDTSetVariableStep', 'Invoke-HDTGatherStep')

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:cimFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim'
    $script:tpmFixturePath = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim-microsofttpm'
    $script:tpmNamespace = 'root/cimv2/security/microsofttpm'

    # -BlankAssetTag is what makes the KEPT record happen at all. The captured
    # enclosure reports a real SMBIOSAssetTag, so a gather over it determines the
    # tag and simply writes it; blanking the property is the Dell of
    # LT-7FJ45S2-run-20260829-190105, where an empty SMBIOS answer was about to
    # erase a value a rule script had resolved.
    $script:newCim = {
        param([switch] $BlankAssetTag)

        # TWO STEPS, NOT A PIPELINE, AND IT IS NOT A STYLE CHOICE. Windows
        # PowerShell 5.1's ConvertFrom-Json emits a JSON array as ONE object, so
        # @( ... | ConvertFrom-Json ) wraps that array as a single element and
        # every instance ends up one level too deep. Assigning first and then
        # @($parsed) unrolls it, which is what every other fixture here does.
        $instance = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $script:cimFixturePath -Filter '*.json' -File)) {
            $parsed = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($file.FullName))
            $instance[$file.BaseName] = [object[]] @($parsed)
        }

        if ($BlankAssetTag) {
            $enclosure = $instance['Win32_SystemEnclosure']
            $enclosure[0].SMBIOSAssetTag = ''
        }

        return New-HDTFakeCimProvider -Instance $instance `
            -NamespaceFixturePath @{ $script:tpmNamespace = $script:tpmFixturePath }
    }

    $script:newLog = {
        param($FileSystem, $Clock)

        return New-HDTLogContext -RunId 'run-vocab' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $FileSystem -Clock $Clock -Level Debug
    }

    # -- run each emitter once, against fakes, and keep what it wrote ----------
    #
    # AT Debug, because var.resolve is written there and an Info context would
    # drop every record - which would pass this whole file by asserting over
    # nothing. The non-vacuity tests below are what stop that being silent.
    $script:recordFor = @{}

    # 1. The rule resolution. Its Unresolved list is primed with a token nothing
    #    supplies, because the "never supplied" warning is one of the records
    #    this split moves and a fixture with no unresolved token would not
    #    exercise it.
    $fs = New-HDTFakeFileSystem
    $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 29, 9, 0, 0, [System.DateTimeKind]::Utc))
    $log = & $script:newLog $fs $clock

    $cim = & $script:newCim
    $script:fact = Get-HDTMachineFact -CimProvider $cim `
        -RegistryService (New-HDTFakeRegistryService) -EnvironmentProvider (New-HDTFakeEnvironmentProvider)

    $script:resolution = Resolve-HDTVariable -Fact $script:fact `
        -CommandLine ([ordered] @{ HDTComputerName = 'PC-%HDTNothingSuppliesThis%' })

    Write-HDTVariableLog -Context $log -Resolution $script:resolution
    $script:recordFor['Write-HDTVariableLog'] = @(Get-HDTRunLogRecord -Context $log)

    # 2. The sequence assignment. Two variables, one of them carrying a token
    #    nothing supplies, for the same reason.
    $fs = New-HDTFakeFileSystem
    $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 29, 9, 0, 0, [System.DateTimeKind]::Utc))
    $log = & $script:newLog $fs $clock

    $context = New-HDTExecutionContext -RunId 'run-vocab' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
        -Variable ([System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)) `
        -Service (New-HDTServiceCatalog -FileSystem $fs -Clock $clock) -Log $log

    [void] (Invoke-HDTSetVariableStep -Context $context -Step ([pscustomobject] @{
                Name     = 'Enter the install stage'
                Type     = 'SetVariable'
                Index    = 1
                Property = [ordered] @{
                    variables = [ordered] @{
                        HDTStage        = 'install'
                        HDTComputerName = 'PC-%HDTNothingSuppliesThis%'
                    }
                }
            }))

    $script:recordFor['Invoke-HDTSetVariableStep'] = @(Get-HDTRunLogRecord -Context $log)

    # 3. The gather. Seeded with a resolved HDTAssetTag the fixture machine
    #    cannot determine, so the KEPT record is written as well as the change
    #    lines and the could-not-determine ones.
    $fs = New-HDTFakeFileSystem
    $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 29, 9, 0, 0, [System.DateTimeKind]::Utc))
    $log = & $script:newLog $fs $clock

    $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    $live['HDTAssetTag'] = 'ASSET-FROM-A-RULE'

    $context = New-HDTExecutionContext -RunId 'run-vocab' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
        -Variable $live -Log $log -Service (New-HDTServiceCatalog -FileSystem $fs -Clock $clock `
            -Cim (& $script:newCim -BlankAssetTag) -Registry (New-HDTFakeRegistryService) `
            -Environment (New-HDTFakeEnvironmentProvider))

    [void] (Invoke-HDTGatherStep -Context $context -Step ([pscustomobject] @{
                Name            = 'Gather local only'
                Type            = 'Gather'
                Index           = 1
                GroupPath       = @('Initialization')
                RunIn           = 'WinPE'
                Condition       = ''
                Disabled        = $false
                ContinueOnError = $false
                Property        = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            }))

    $script:recordFor['Invoke-HDTGatherStep'] = @(Get-HDTRunLogRecord -Context $log)

    $script:resolveRecord = { param([string] $Emitter)
        return @($script:recordFor[$Emitter] | Where-Object { $_.Event -eq 'var.resolve' })
    }

    $script:unresolvedRecord = { param([string] $Emitter)
        return @($script:recordFor[$Emitter] | Where-Object { $_.Event -eq 'var.unresolved' })
    }

    # THE ONE GRAMMAR, WRITTEN ONCE. A var.resolve message names the variable,
    # then its value in single quotes, then the source in brackets - and may add
    # detail after that, comma separated, on the same line. Every emitter's
    # records are held to it below.
    $script:grammar = "^HDT[A-Za-z0-9_]+ = '.*' \([A-Za-z]+\)(,.*)?$"
}

Describe 'the fixtures these assertions are made over' {

    # NON-VACUITY FIRST. Every test below filters, and a filter that matches
    # nothing passes silently - which is the one failure a vocabulary contract
    # cannot afford.

    It 'ran <_> and it wrote something' -ForEach $emitterName {
        @($script:recordFor[$_]).Count | Should -BeGreaterThan 0
    }

    It 'got at least one var.resolve record out of <_>' -ForEach $emitterName {
        @(& $script:resolveRecord $_).Count | Should -BeGreaterThan 0 -Because (
            '{0} writes var.resolve records and a fixture that produced none would pass every assertion here' -f $_)
    }

    It 'got at least one var.unresolved record out of <_>' -ForEach $emitterName {
        @(& $script:unresolvedRecord $_).Count | Should -BeGreaterThan 0 -Because (
            '{0} writes non-resolutions too, and this file exists to keep them off var.resolve' -f $_)
    }
}

Describe 'var.resolve, which means the variable took this value' {

    It 'writes every record in the one grammar, from <_>' -ForEach $emitterName {
        # THE HEADLINE. Three emitters, two grammars, and a consumer that has to
        # parse both is a consumer that parses neither reliably.
        foreach ($one in @(& $script:resolveRecord $_)) {
            $one.Message | Should -Match $script:grammar -Because (
                "{0} wrote a var.resolve message in a shape no other emitter uses: {1}" -f $_, $one.Message)
        }
    }

    It 'carries the name, the value and the source in data, from <_>' -ForEach $emitterName {
        # WHAT ConvertTo-HDTReport READS. It renders Name/Value/Source/Rule out
        # of data, so a record without them is a blank row in the Variables
        # table of the report somebody sends on - which is what the gather's
        # change lines were.
        foreach ($one in @(& $script:resolveRecord $_)) {
            $one.Data | Should -Not -BeNullOrEmpty -Because (
                '{0} wrote a var.resolve record with no data at all: {1}' -f $_, $one.Message)

            [string] $one.Data.name | Should -Not -BeNullOrEmpty -Because ('{0}: {1}' -f $_, $one.Message)
            [string] $one.Data.source | Should -Not -BeNullOrEmpty -Because ('{0}: {1}' -f $_, $one.Message)
            $one.Data.PSObject.Properties.Name | Should -Contain 'value' -Because (
                '{0} wrote a resolution with no value: {1}' -f $_, $one.Message)
        }
    }

    It 'names the variable in the message and in data alike, from <_>' -ForEach $emitterName {
        # A message that disagrees with its own data is worse than either alone.
        foreach ($one in @(& $script:resolveRecord $_)) {
            $one.Message | Should -BeLike ('{0} = *' -f [string] $one.Data.name)
        }
    }

    It 'says the source in the message and in data alike, from <_>' -ForEach $emitterName {
        foreach ($one in @(& $script:resolveRecord $_)) {
            $one.Message | Should -BeLike ('*({0})*' -f [string] $one.Data.source)
        }
    }

    It 'files no non-resolution under it, from <_>' -ForEach $emitterName {
        # THE SPLIT ITSELF. "kept the resolved value", "could not be determined"
        # and "never supplied" all say the variable did NOT take the value, and
        # they belong under var.unresolved.
        foreach ($one in @(& $script:resolveRecord $_)) {
            $one.Message | Should -Not -Match 'could not be determined|kept the resolved value|never supplied'
        }
    }

    It 'writes one record per line, from <_>' -ForEach $emitterName {
        foreach ($one in @(& $script:resolveRecord $_)) {
            $one.Message | Should -Not -Match "[`r`n]" -Because (
                'a multi-line message is unreadable in CMTrace, unfilterable, and carries no per-item data')
        }
    }
}

Describe 'var.unresolved, which means the variable did not' {

    It 'writes no record in the var.resolve grammar, from <_>' -ForEach $emitterName {
        # The two names must be told apart by a reader as well as by a filter.
        foreach ($one in @(& $script:unresolvedRecord $_)) {
            $one.Message | Should -Not -Match $script:grammar
        }
    }

    It 'carries data a consumer can act on, from <_>' -ForEach $emitterName {
        foreach ($one in @(& $script:unresolvedRecord $_)) {
            $one.Data | Should -Not -BeNullOrEmpty -Because (
                '{0} wrote a var.unresolved record with no data: {1}' -f $_, $one.Message)
        }
    }

    It 'writes one record per line, from <_>' -ForEach $emitterName {
        foreach ($one in @(& $script:unresolvedRecord $_)) {
            $one.Message | Should -Not -Match "[`r`n]"
        }
    }
}

Describe 'the severities, which are deliberate and not an accident of the split' {

    It 'writes a rule resolution at Debug' {
        # DESIGN 4.4.2: "Debug adds every variable resolution with its provenance
        # and every native command line executed in full". A context at the
        # default Info level drops them, which is intended.
        @(& $script:resolveRecord 'Write-HDTVariableLog' | Where-Object { $_.Level -ne 'Debug' }) |
            Should -BeNullOrEmpty
    }

    It 'writes a step assignment at Info' {
        # PRESERVED ON PURPOSE, and the reasoning is in the step's own help: "an
        # authored mid-sequence assignment is a decision somebody made, not a
        # derivation". A sequence author setting a variable is a step doing work,
        # so it survives a run that is not in Debug.
        @(& $script:resolveRecord 'Invoke-HDTSetVariableStep' | Where-Object { $_.Level -ne 'Info' }) |
            Should -BeNullOrEmpty
    }

    It 'writes a gathered fact at Debug' {
        @(& $script:resolveRecord 'Invoke-HDTGatherStep' | Where-Object { $_.Level -ne 'Debug' }) |
            Should -BeNullOrEmpty
    }

    It 'warns about a token nothing supplied, rather than whispering it' {
        # 02-03 settled that an unresolved %Var% is surfaced and left in place
        # rather than ending the deployment. It is emitted at Warning so it
        # survives a non-Debug verbosity: this is the one part of provenance an
        # administrator needs without turning Debug on first.
        @(& $script:unresolvedRecord 'Write-HDTVariableLog' |
                Where-Object { $_.Message -match 'never supplied' -and $_.Level -ne 'Warning' }) |
            Should -BeNullOrEmpty
    }
}

Describe 'the one consumer, which is where the defect was visible' {

    # ConvertTo-HDTReport IS THE ONLY COMMAND IN src/ THAT FILTERS THIS EVENT -
    # grepped, not assumed. It renders each var.resolve record as a row of
    # Name/Value/Source/Rule read out of data, so a record filed under the name
    # without those fields is not merely mislabelled: it is a BLANK ROW in the
    # report somebody emails on.
    #
    # ASSERTED OVER THE SET, by rendering a report from a stream that every
    # emitter wrote into. A test built from one emitter's records would have
    # passed throughout the period the defect existed.

    BeforeAll {
        $script:reportFs = New-HDTFakeFileSystem
        $script:reportClock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 29, 9, 0, 0, [System.DateTimeKind]::Utc))
        $script:reportLog = New-HDTLogContext -RunId 'run-report' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:reportFs -Clock $script:reportClock -Level Debug

        Write-HDTVariableLog -Context $script:reportLog -Resolution $script:resolution

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $live['HDTAssetTag'] = 'ASSET-FROM-A-RULE'

        $context = New-HDTExecutionContext -RunId 'run-report' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
            -Variable $live -Log $script:reportLog -Service (New-HDTServiceCatalog `
                -FileSystem $script:reportFs -Clock $script:reportClock `
                -Cim (& $script:newCim -BlankAssetTag) -Registry (New-HDTFakeRegistryService) `
                -Environment (New-HDTFakeEnvironmentProvider))

        [void] (Invoke-HDTGatherStep -Context $context -Step ([pscustomobject] @{
                    Name            = 'Gather local only'
                    Type            = 'Gather'
                    Index           = 1
                    GroupPath       = @('Initialization')
                    RunIn           = 'WinPE'
                    Condition       = ''
                    Disabled        = $false
                    ContinueOnError = $false
                    Property        = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                }))

        [void] (Invoke-HDTSetVariableStep -Context $context -Step ([pscustomobject] @{
                    Name     = 'Enter the install stage'
                    Type     = 'SetVariable'
                    Index    = 2
                    Property = [ordered] @{ variables = [ordered] @{ HDTStage = 'install' } }
                }))

        [void] (ConvertTo-HDTReport -JsonlPath 'X:\HDT\Logs\HDT.jsonl' -Path 'X:\HDT\Logs\report.html' `
                -FileSystem $script:reportFs)

        $script:reportHtml = [string] $script:reportFs.ReadAllText('X:\HDT\Logs\report.html')

        $script:variableRow = @([regex]::Matches($script:reportHtml, '<tr class="var">(.*?)</tr>') |
                ForEach-Object { $_.Groups[1].Value })
    }

    It 'rendered a report with variable rows in it at all' {
        @($script:variableRow).Count | Should -BeGreaterThan 0 -Because (
            'a report with no variable rows would pass the assertions below over nothing')
    }

    It 'writes no variable row with an empty name, value and source' {
        # THE DEFECT, SEEN FROM THE OUTSIDE. Every gather change line, every
        # kept value, every could-not-determine record and both unresolved-token
        # warnings drew one of these.
        $blank = @($script:variableRow | Where-Object { $_ -match '^(<td></td>){2}' })

        ($blank -join ' | ') | Should -BeExactly ''
    }

    It 'names a source on every variable row' {
        foreach ($row in $script:variableRow) {
            $cell = @([regex]::Matches($row, '<td[^>]*>(.*?)</td>') | ForEach-Object { $_.Groups[1].Value })

            $cell.Count | Should -BeGreaterOrEqual 4
            $cell[1] | Should -Not -BeNullOrEmpty -Because ('the Name cell is empty in: {0}' -f $row)
            $cell[3] | Should -Not -BeNullOrEmpty -Because ('the Source cell is empty in: {0}' -f $row)
        }
    }

    It 'still says in the log what it could not determine' {
        # THE OTHER HALF: moving those records off the Variables table must not
        # have moved them out of the report altogether. The Log section carries
        # every record, reason included.
        $script:reportHtml | Should -BeLike '*could not be determined*'
        $script:reportHtml | Should -BeLike '*var.unresolved*'
    }
}

Describe 'what the gather says it did not do' {

    It 'reports the value it kept under var.unresolved, with the name in data' {
        $kept = @(& $script:unresolvedRecord 'Invoke-HDTGatherStep' |
                Where-Object { $_.Message -match 'kept the resolved value' })

        $kept.Count | Should -BeGreaterThan 0
        [string] $kept[0].Data.name | Should -BeExactly 'HDTAssetTag'
        $kept[0].Data.kept | Should -BeTrue
    }

    It 'reports what it could not determine under var.unresolved, with the reason in data' {
        $undetermined = @(& $script:unresolvedRecord 'Invoke-HDTGatherStep' |
                Where-Object { $_.Message -match 'could not be determined' })

        $undetermined.Count | Should -BeGreaterThan 0
        [string] $undetermined[0].Data.name | Should -Not -BeNullOrEmpty
        [string] $undetermined[0].Data.reason | Should -Not -BeNullOrEmpty -Because (
            'the message already names the reason; a consumer should not have to parse prose for it')
        $undetermined[0].Data.determined | Should -BeFalse
    }

    It 'still keeps the value it declined to overwrite' {
        # The split must not have moved the behaviour along with the record.
        @(& $script:resolveRecord 'Invoke-HDTGatherStep' |
                Where-Object { [string] $_.Data.name -eq 'HDTAssetTag' }) | Should -BeNullOrEmpty
    }

    It 'names where a changed fact came from, on the same line' {
        # "HDTMake = 'LENOVO' (Gather)" names the value and leaves the reader to
        # guess what moved it; the CIM property is the difference between editing
        # rules.yaml and hunting a class.
        $changed = @(& $script:resolveRecord 'Invoke-HDTGatherStep' |
                Where-Object { -not [string]::IsNullOrEmpty([string] $_.Data.origin) })

        $changed.Count | Should -BeGreaterThan 0
        $changed[0].Message | Should -BeLike ('*from {0}' -f [string] $changed[0].Data.origin)
    }
}
