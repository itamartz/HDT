# The three dispatchers every step goes through: Invoke-HDTStep,
# Test-HDTStepApplicable and Get-HDTStepDescription. DESIGN 4.2's
# Test-Applicable / Invoke-Step / Get-StepDescription triple, resolved by
# convention rather than by a hard-coded switch.
#
# ALL THREE TAKE THE SAME OPTIONAL -StepType REGISTRY so 03-04's loop discovers
# once per run and hands the result to each of them, rather than re-enumerating
# Get-Command on every step of every sequence.
#
# Invoke-HDTStep DOES NOT CATCH. Classifying a thrown exception as Transient,
# Configuration or Environment (DESIGN 12.1) belongs to the loop, which owns the
# retry policy and continueOnError. Swallowing it here would hide it from both.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:newStep = {
        param([string] $Type, [string] $Name, [object] $Applicable)

        return [pscustomobject] @{
            Index      = 1
            Name       = $Name
            Type       = $Type
            Applicable = $Applicable
            Property   = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
    }
}

Describe 'the step dispatchers' {

    BeforeEach {
        New-Module -Name HDTThirdParty -ScriptBlock {
            function Invoke-HDTContosoBeepStep {
                param($Step, $Context)
                [pscustomobject] @{
                    Status   = 'Completed'
                    ExitCode = 7
                    Message  = 'beeped'
                    Data     = [pscustomobject] @{ Step = $Step; Context = $Context }
                }
            }
            function Test-HDTContosoBeepStepApplicable {
                param($Step, $Context)
                # The step contract requires -Context; this double does not read it.
                $null = $Context
                $Step.Applicable
            }
            function Get-HDTContosoBeepStepDescription {
                param($Step)
                'Beep for {0}' -f $Step.Name
            }
            function Invoke-HDTContosoQuietStep {
                param($Step, $Context)
                # The step contract requires both parameters; this double reads
                # neither.
                $null = $Step, $Context
                [pscustomobject] @{ Status = 'Completed'; ExitCode = 0; Message = ''; Data = $null }
            }
            function Invoke-HDTContosoAngryStep {
                param($Step, $Context)
                # The step contract requires both parameters; this double reads
                # neither.
                $null = $Step, $Context
                throw 'the vendor tool exploded'
            }
            Export-ModuleMember -Function 'Invoke-HDTContosoBeepStep', 'Test-HDTContosoBeepStepApplicable',
            'Get-HDTContosoBeepStepDescription', 'Invoke-HDTContosoQuietStep', 'Invoke-HDTContosoAngryStep'
        } | Import-Module -Force

        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::Parse('2026-08-13T00:11:02.481Z').ToUniversalTime())
        $script:catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock
        $script:log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fileSystem -Clock $script:clock

        $script:variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'X:\Deploy' `
            -Variable $script:variable -Service $script:catalog -Log $script:log
    }

    AfterEach {
        Remove-Module -Name HDTThirdParty -Force -ErrorAction SilentlyContinue
    }

    Context 'Invoke-HDTStep' {

        It 'calls the invoke command for the step type' {
            $step = & $script:newStep 'ContosoBeep' 'Make a noise' $true

            $result = Invoke-HDTStep -Step $step -Context $script:context

            $result.Message | Should -BeExactly 'beeped'
        }

        It 'passes the step and the context through' {
            $step = & $script:newStep 'ContosoBeep' 'Make a noise' $true

            $result = Invoke-HDTStep -Step $step -Context $script:context

            [object]::ReferenceEquals($result.Data.Step, $step) | Should -BeTrue
            [object]::ReferenceEquals($result.Data.Context, $script:context) | Should -BeTrue
        }

        It 'returns the step result unchanged' {
            $step = & $script:newStep 'ContosoBeep' 'Make a noise' $true

            $result = Invoke-HDTStep -Step $step -Context $script:context

            $result.Status | Should -BeExactly 'Completed'
            $result.ExitCode | Should -Be 7
        }

        It 'throws a configuration error naming an unknown type' {
            $step = & $script:newStep 'NoSuchStepType' 'A typo' $true

            $record = $null
            try { Invoke-HDTStep -Step $step -Context $script:context } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*NoSuchStepType*'
            $record.Exception.Message | Should -BeLike '*A typo*'
        }

        It 'lists the known types in that error' {
            # A typo in sequence.yaml should print the alternatives, not just a
            # refusal.
            $step = & $script:newStep 'NoSuchStepType' 'A typo' $true

            $record = $null
            try { Invoke-HDTStep -Step $step -Context $script:context } catch { $record = $_ }

            $record.Exception.Message | Should -BeLike '*ContosoBeep*'
        }

        It 'accepts a pre-built registry through -StepType' {
            $registry = @(Get-HDTStepType)
            $step = & $script:newStep 'ContosoBeep' 'Make a noise' $true

            $result = Invoke-HDTStep -Step $step -Context $script:context -StepType $registry

            $result.Message | Should -BeExactly 'beeped'
        }

        It 'does not catch an exception the step threw' {
            $step = & $script:newStep 'ContosoAngry' 'Explode' $true

            { Invoke-HDTStep -Step $step -Context $script:context } |
                Should -Throw -ExpectedMessage '*the vendor tool exploded*'
        }
    }

    Context 'Test-HDTStepApplicable' {

        It 'returns true when the type declares no applicability function' {
            $step = & $script:newStep 'ContosoQuiet' 'Say nothing' $false

            Test-HDTStepApplicable -Step $step -Context $script:context | Should -BeTrue
        }

        It 'calls the applicability function when one exists' {
            $step = & $script:newStep 'ContosoBeep' 'Make a noise' $false

            Test-HDTStepApplicable -Step $step -Context $script:context | Should -BeFalse
        }

        It 'returns what that function returned' {
            $step = & $script:newStep 'ContosoBeep' 'Make a noise' $true

            Test-HDTStepApplicable -Step $step -Context $script:context | Should -BeTrue
        }

        It 'coerces the result to a boolean' {
            $step = & $script:newStep 'ContosoBeep' 'Make a noise' 1

            $applicable = Test-HDTStepApplicable -Step $step -Context $script:context

            $applicable | Should -BeOfType ([bool])
            $applicable | Should -BeTrue
        }

        It 'accepts a pre-built registry through -StepType' {
            $registry = @(Get-HDTStepType)
            $step = & $script:newStep 'ContosoBeep' 'Make a noise' $false

            Test-HDTStepApplicable -Step $step -Context $script:context -StepType $registry | Should -BeFalse
        }

        It 'returns true for a type that is not in the registry' {
            # Applicability is not where an unknown type is reported.
            # Invoke-HDTStep owns that error, and reporting it from two places
            # would give the loop two different messages for one fault.
            $step = & $script:newStep 'NoSuchStepType' 'A typo' $true

            Test-HDTStepApplicable -Step $step -Context $script:context | Should -BeTrue
        }
    }

    Context 'Get-HDTStepDescription' {

        It 'returns Type: name when the type declares no description function' {
            $step = & $script:newStep 'ContosoQuiet' 'Say nothing' $true

            Get-HDTStepDescription -Step $step | Should -BeExactly 'ContosoQuiet: Say nothing'
        }

        It 'calls the description function when one exists' {
            $step = & $script:newStep 'ContosoBeep' 'Make a noise' $true

            Get-HDTStepDescription -Step $step | Should -BeExactly 'Beep for Make a noise'
        }

        It 'returns Type: name for a type that is not in the registry' {
            $step = & $script:newStep 'NoSuchStepType' 'A typo' $true

            Get-HDTStepDescription -Step $step | Should -BeExactly 'NoSuchStepType: A typo'
        }

        It 'accepts a pre-built registry through -StepType' {
            $registry = @(Get-HDTStepType)
            $step = & $script:newStep 'ContosoBeep' 'Make a noise' $true

            Get-HDTStepDescription -Step $step -StepType $registry | Should -BeExactly 'Beep for Make a noise'
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis for <_>' -ForEach @('Invoke-HDTStep', 'Test-HDTStepApplicable', 'Get-HDTStepDescription', 'Import-HDTStepModule') {
            $help = Get-Help -Name $_ -ErrorAction Stop

            $help.Name | Should -BeExactly $_
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Get-HDTStepDescription over every discovered type' {

    # -ForEach at DISCOVERY time, so a step type added later is held to this
    # without editing the file.
    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    }

    It 'returns a non-empty string for <Type>' -ForEach @(
        Get-ChildItem -LiteralPath (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'src/Hephaestus/Public/Steps') -Filter 'Invoke-HDT*Step.ps1' -File -ErrorAction SilentlyContinue |
        ForEach-Object { @{ Type = ($_.BaseName -replace '^Invoke-HDT(.+)Step$', '$1') } }) {

        # Property is part of the flattened step record, so every step type may
        # assume it: Import-HDTSequenceDocument always produces one.
        $step = [pscustomobject] @{
            Index    = 1
            Name     = 'A step'
            Type     = $Type
            Property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        }

        Get-HDTStepDescription -Step $step | Should -Not -BeNullOrEmpty
    }
}
