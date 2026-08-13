# The SetVariable step assigns deployment variables mid-sequence.
#
# IT IS NOT A SIXTH PROVENANCE SOURCE. 02-03 closed Add-HDTResolvedVariable's
# Source set deliberately, and that function REFUSES to overwrite - first writer
# wins, because rule precedence is a precedence order, not a race. A SetVariable
# step is the opposite: an imperative assignment that MUST be able to overwrite,
# because "set HDTStage to 2 now that stage 1 finished" is its whole job.
#
# So it writes $Context.Variable directly and its provenance is the var.resolve
# record on the JSONL stream, carrying data.source = 'Step' and the step name.
# Add-HDTResolvedVariable's ValidateSet is not touched.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:newStep = {
        param([string] $Name, [System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{ Index = 1; Name = $Name; Type = 'SetVariable'; Property = $bag }
    }

    # Every JSONL record written so far, as objects.
    $script:jsonlRecord = {
        param($FileSystem)

        $text = ''
        if ($FileSystem.File.ContainsKey('X:\HDT\Logs\HDT.jsonl')) {
            $text = [string] $FileSystem.File['X:\HDT\Logs\HDT.jsonl']
        }

        return @(@($text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
                ForEach-Object { $_ | ConvertFrom-Json })
    }
}

Describe 'Invoke-HDTSetVariableStep' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, [System.DateTimeKind]::Utc))
        $script:catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock
        $script:log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock

        $script:variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:variable['HDTSerialNumber'] = 'FIXTURE-SERIAL-0001'

        $script:context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'X:\Deploy' `
            -Variable $script:variable -Service $script:catalog -Log $script:log
    }

    Context 'assignment' {

        It 'sets a variable from the variables mapping' {
            $step = & $script:newStep 'Set stage' ([ordered] @{ variables = [ordered] @{ HDTStage = 'preinstall' } })

            (Invoke-HDTSetVariableStep -Step $step -Context $script:context).Status | Should -BeExactly 'Completed'
            $script:variable['HDTStage'] | Should -BeExactly 'preinstall'
        }

        It 'sets several variables in document order' {
            $step = & $script:newStep 'Set several' ([ordered] @{
                    variables = [ordered] @{ HDTFirst = 'one'; HDTSecond = 'two'; HDTThird = 'three' }
                })

            Invoke-HDTSetVariableStep -Step $step -Context $script:context | Out-Null

            $record = @(& $script:jsonlRecord $script:fileSystem | Where-Object { $_.event -eq 'var.resolve' })
            @($record | ForEach-Object { $_.data.name }) | Should -Be @('HDTFirst', 'HDTSecond', 'HDTThird')
        }

        It 'sets a variable from the variable and value pair' {
            $step = & $script:newStep 'Set stage' ([ordered] @{ variable = 'HDTStage'; value = 'preinstall' })

            Invoke-HDTSetVariableStep -Step $step -Context $script:context | Out-Null

            $script:variable['HDTStage'] | Should -BeExactly 'preinstall'
        }

        It 'overwrites a variable that already has a value' {
            # Deliberately unlike Add-HDTResolvedVariable, which refuses: a
            # SetVariable step is an imperative mid-sequence assignment, and
            # "set HDTStage to 2 now that stage 1 finished" is its whole job.
            $script:variable['HDTStage'] = 'preinstall'
            $step = & $script:newStep 'Advance stage' ([ordered] @{ variable = 'HDTStage'; value = 'install' })

            Invoke-HDTSetVariableStep -Step $step -Context $script:context | Out-Null

            $script:variable['HDTStage'] | Should -BeExactly 'install'
        }

        It 'expands a %Var% in the value' {
            $step = & $script:newStep 'Name the machine' ([ordered] @{
                    variable = 'HDTComputerName'; value = 'PC-%HDTSerialNumber%'
                })

            Invoke-HDTSetVariableStep -Step $step -Context $script:context | Out-Null

            $script:variable['HDTComputerName'] | Should -BeExactly 'PC-FIXTURE-SERIAL-0001'
        }

        It 'expands against a variable an earlier key in the same step set' {
            $step = & $script:newStep 'Chain' ([ordered] @{
                    variables = [ordered] @{ HDTSitePrefix = 'LAB'; HDTComputerName = '%HDTSitePrefix%-0001' }
                })

            Invoke-HDTSetVariableStep -Step $step -Context $script:context | Out-Null

            $script:variable['HDTComputerName'] | Should -BeExactly 'LAB-0001'
        }

        It 'leaves an unresolved token literal and logs it' {
            # 02-03's rule: emptying a token silently is how a machine ends up
            # named 'PC-'.
            $step = & $script:newStep 'Name the machine' ([ordered] @{
                    variable = 'HDTComputerName'; value = 'PC-%HDTNoSuchThing%'
                })

            Invoke-HDTSetVariableStep -Step $step -Context $script:context | Out-Null

            $script:variable['HDTComputerName'] | Should -BeExactly 'PC-%HDTNoSuchThing%'
            $script:fileSystem.File['X:\HDT\Logs\HDT.jsonl'] | Should -BeLike '*HDTNoSuchThing*'
        }
    }

    Context 'provenance' {

        It 'writes a var.resolve record per variable' {
            $step = & $script:newStep 'Set two' ([ordered] @{
                    variables = [ordered] @{ HDTFirst = 'one'; HDTSecond = 'two' }
                })

            Invoke-HDTSetVariableStep -Step $step -Context $script:context | Out-Null

            @(& $script:jsonlRecord $script:fileSystem | Where-Object { $_.event -eq 'var.resolve' }).Count |
                Should -Be 2
        }

        It 'records the source as Step in that record' {
            $step = & $script:newStep 'Set stage' ([ordered] @{ variable = 'HDTStage'; value = 'preinstall' })

            Invoke-HDTSetVariableStep -Step $step -Context $script:context | Out-Null

            $record = @(& $script:jsonlRecord $script:fileSystem | Where-Object { $_.event -eq 'var.resolve' })[0]

            $record.data.source | Should -BeExactly 'Step'
        }

        It 'records the step name in that record' {
            $step = & $script:newStep 'Set stage' ([ordered] @{ variable = 'HDTStage'; value = 'preinstall' })

            Invoke-HDTSetVariableStep -Step $step -Context $script:context | Out-Null

            $record = @(& $script:jsonlRecord $script:fileSystem | Where-Object { $_.event -eq 'var.resolve' })[0]

            $record.data.step | Should -BeExactly 'Set stage'
        }

        It 'records the value it assigned' {
            $step = & $script:newStep 'Set stage' ([ordered] @{ variable = 'HDTStage'; value = 'preinstall' })

            Invoke-HDTSetVariableStep -Step $step -Context $script:context | Out-Null

            $record = @(& $script:jsonlRecord $script:fileSystem | Where-Object { $_.event -eq 'var.resolve' })[0]

            $record.data.value | Should -BeExactly 'preinstall'
        }
    }

    Context 'what it refuses' {

        It 'refuses to set an engine variable' {
            $step = & $script:newStep 'Move the log' ([ordered] @{ variable = '_HDTLogPath'; value = 'C:\Elsewhere' })

            $record = $null
            try { Invoke-HDTSetVariableStep -Step $step -Context $script:context } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*_HDTLogPath*'
        }

        It 'refuses a name that does not start with HDT' {
            $step = & $script:newStep 'Set something' ([ordered] @{ variable = 'OSImage'; value = 'Win11' })

            $record = $null
            try { Invoke-HDTSetVariableStep -Step $step -Context $script:context } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*OSImage*'
        }

        It 'fails rather than throwing for a missing variables property' {
            # An authoring mistake that reached execution should end the STEP,
            # not the process: the loop decides what a failed step means.
            $step = & $script:newStep 'Set nothing' $null

            $result = $null
            { $result = Invoke-HDTSetVariableStep -Step $step -Context $script:context } | Should -Not -Throw

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*Set nothing*'
        }
    }

    Context 'the step contract' {

        It 'is discovered as a step type' {
            @(Get-HDTStepType -Name 'SetVariable')[0].Source | Should -BeExactly 'Hephaestus'
        }

        It 'describes what it will set' {
            $step = & $script:newStep 'Set stage' ([ordered] @{ variable = 'HDTStage'; value = 'preinstall' })

            Get-HDTStepDescription -Step $step | Should -BeLike '*HDTStage*'
        }
    }
}
