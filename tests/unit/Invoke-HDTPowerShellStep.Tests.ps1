# The PowerShell step runs a user script from the workspace's Scripts directory.
#
# It is DESIGN 4.4.4's extensibility point, and the two behaviours that matter
# most are about honesty rather than execution:
#
#   * EVERYTHING THE SCRIPT WROTE lands in the per-step log, including a bare
#     Write-Host line, because real fleets carry years of scripts that trace that
#     way and rewriting them is not an option.
#   * A SCRIPT THAT THREW IS A FAILED STEP, not a failed run. continueOnError and
#     the retry policy are the loop's decision, so this step returns Failed and
#     does not rethrow.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:newStep = {
        param([string] $Name, [System.Collections.IDictionary] $Property, [string] $Log)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{ Index = 1; Name = $Name; Type = 'PowerShell'; Log = $Log; Property = $bag }
    }
}

Describe 'Invoke-HDTPowerShellStep' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, [System.DateTimeKind]::Utc))
        $script:invoker = New-HDTFakeScriptInvoker `
            -Result @{ 'X:/Deploy/Scripts/Set-CorpBaseline.ps1' = [pscustomobject] @{ HDTBiosBaseline = 'ok' } } `
            -Transcript @{ 'X:/Deploy/Scripts/Set-CorpBaseline.ps1' = @('checking vendor BIOS level') }

        $script:catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
            -ScriptInvoker $script:invoker

        $script:log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock

        $script:variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:variable['HDTSerialNumber'] = 'FIXTURE-SERIAL-0001'

        $script:context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'X:\Deploy' `
            -Variable $script:variable -Service $script:catalog -Log $script:log
        $script:context.SetStep(1, 'Custom', 'PowerShell', 'C:\HDT\Logs\Steps\001-Custom.log')

        $script:step = & $script:newStep 'Custom' ([ordered] @{ script = 'Scripts\Set-CorpBaseline.ps1' }) $null
    }

    It 'invokes the script through the injected invoker' {
        Invoke-HDTPowerShellStep -Step $script:step -Context $script:context | Out-Null

        @($script:invoker.GetOperationName()) | Should -Be @('Invoke')
    }

    It 'resolves the script path relative to the workspace root' {
        Invoke-HDTPowerShellStep -Step $script:step -Context $script:context | Out-Null

        @($script:invoker.Operations[0].Arguments)[0] | Should -BeExactly 'X:\Deploy\Scripts\Set-CorpBaseline.ps1'
    }

    It 'passes the live variables to the script' {
        Invoke-HDTPowerShellStep -Step $script:step -Context $script:context | Out-Null

        $passed = @($script:invoker.Operations[0].Arguments)[1]

        [object]::ReferenceEquals($passed, $script:variable) | Should -BeTrue
    }

    It 'returns Completed when the script returns' {
        (Invoke-HDTPowerShellStep -Step $script:step -Context $script:context).Status | Should -BeExactly 'Completed'
    }

    It 'returns what the script emitted in the result data' {
        $result = Invoke-HDTPowerShellStep -Step $script:step -Context $script:context

        $result.Data.HDTBiosBaseline | Should -BeExactly 'ok'
    }

    It 'writes the transcript into the step log' {
        # DESIGN 4.4.4: a script that only uses Write-Host still lands in the log.
        Invoke-HDTPowerShellStep -Step $script:step -Context $script:context | Out-Null

        $script:fileSystem.File['C:\HDT\Logs\Steps\001-Custom.log'] |
            Should -BeLike '*checking vendor BIOS level*'
    }

    It 'writes the transcript into the master log too' {
        Invoke-HDTPowerShellStep -Step $script:step -Context $script:context | Out-Null

        $script:fileSystem.File['C:\HDT\Logs\HDT.jsonl'] | Should -BeLike '*checking vendor BIOS level*'
    }

    It 'returns Failed with the message when the script throws' {
        $step = & $script:newStep 'Custom' ([ordered] @{ script = 'Scripts\NoSuchScript.ps1' }) $null

        $result = Invoke-HDTPowerShellStep -Step $step -Context $script:context

        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*NoSuchScript.ps1*'
    }

    It 'does not rethrow when the script throws' {
        # A failing user script is a failed STEP; continueOnError is the loop's
        # decision, not this step's.
        $step = & $script:newStep 'Custom' ([ordered] @{ script = 'Scripts\NoSuchScript.ps1' }) $null

        $record = $null
        try { Invoke-HDTPowerShellStep -Step $step -Context $script:context | Out-Null } catch { $record = $_ }

        $record | Should -BeNullOrEmpty
    }

    It 'fails when no script property was given' {
        $step = & $script:newStep 'Custom' $null $null

        $result = Invoke-HDTPowerShellStep -Step $step -Context $script:context

        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*script*'
    }

    It 'asks the catalog for the script invoker by name' {
        # A catalog without one must produce the pointed GetRequired error naming
        # both the service and the step type, not a StrictMode property error.
        $bare = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock
        $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'X:\Deploy' `
            -Variable $script:variable -Service $bare -Log $script:log

        $record = $null
        try { Invoke-HDTPowerShellStep -Step $script:step -Context $context } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.Exception.Message | Should -BeLike '*ScriptInvoker*'
        $record.Exception.Message | Should -BeLike '*PowerShell step*'
    }

    It 'runs no PowerShell process' {
        Invoke-HDTPowerShellStep -Step $script:step -Context $script:context | Out-Null

        @($script:invoker.Operations).Count | Should -Be 1
    }

    Context 'variable expansion' {

        # THIS STEP AND CommandLine WERE THE TWO THAT DID NOT EXPAND. A sequence
        # written as `script: Scripts\%HDTScriptName%.ps1` - the obvious way to
        # pick a per-model script, and the way ApplyDrivers' own template picks a
        # driver folder - failed with "Could not find script
        # 'X:\Deploy\Scripts\%HDTScriptName%.ps1'", which named the file it
        # looked for honestly and the reason not at all.

        It 'expands %Var% in script' {
            $script:variable['HDTScriptName'] = 'Set-CorpBaseline'
            $step = & $script:newStep 'Custom' ([ordered] @{ script = 'Scripts\%HDTScriptName%.ps1' }) $null

            Invoke-HDTPowerShellStep -Step $step -Context $script:context | Out-Null

            @($script:invoker.Operations[0].Arguments)[0] |
                Should -BeExactly 'X:\Deploy\Scripts\Set-CorpBaseline.ps1'
        }

        # A TOKEN NOBODY SET STAYS STANDING (Expand-HDTVariableToken), so the
        # refusal still quotes the path that was actually looked for. Blanking it
        # would leave a message about 'X:\Deploy\Scripts\.ps1' and no clue
        # which variable was missing.
        It 'leaves a token nobody set standing verbatim' {
            $step = & $script:newStep 'Custom' ([ordered] @{ script = 'Scripts\%HDTNobodySetThis%.ps1' }) $null

            $result = Invoke-HDTPowerShellStep -Step $step -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*%HDTNobodySetThis%*'
        }
    }

    Context 'the step contract' {

        It 'is discovered as a step type' {
            @(Get-HDTStepType -Name 'PowerShell')[0].Source | Should -BeExactly 'Hephaestus'
        }

        It 'declares an applicability function' {
            @(Get-HDTStepType -Name 'PowerShell')[0].TestCommand | Should -Not -BeNullOrEmpty
        }

        It 'is applicable when a script is declared' {
            Test-HDTStepApplicable -Step $script:step -Context $script:context | Should -BeTrue
        }

        It 'is not applicable when no script is declared' {
            $step = & $script:newStep 'Custom' $null $null

            Test-HDTStepApplicable -Step $step -Context $script:context | Should -BeFalse
        }

        It 'describes the script it will run' {
            Get-HDTStepDescription -Step $script:step | Should -BeLike '*Set-CorpBaseline.ps1*'
        }
    }
}
