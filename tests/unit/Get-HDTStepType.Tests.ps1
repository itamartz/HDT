# Get-HDTStepType is DESIGN 4.2's "third-party step types can be dropped into
# Modules\ - the engine discovers them by convention, so extending HDT does not
# mean forking it".
#
# The convention, and the whole registry:
#
#   Invoke-HDT<Type>Step -Step -Context      required
#   Test-HDT<Type>StepApplicable -Step -Context   optional, default $true
#   Get-HDT<Type>StepDescription -Step       optional, default '<Type>: <name>'
#
# THE THIRD-PARTY TESTS SEED A MODULE IN MEMORY. New-Module | Import-Module
# registers a function in the session and Get-Command reports its ModuleName, so
# the extensibility claim is provable with no file written anywhere - which is
# also why it can be asserted in a unit test rather than only in an integration
# one.
#
# NO FUTURE HDT FUNCTION MAY BE NAMED Invoke-HDT*Step unless it is a step type.
# The name is the registry.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:stepFileRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Steps'
}

Describe 'Get-HDTStepType' {

    Context 'third-party types' {

        BeforeEach {
            New-Module -Name HDTThirdParty -ScriptBlock {
                function Invoke-HDTContosoBeepStep {
                    param($Step, $Context)
                    # The step contract requires both parameters; this double reads
                    # neither, and saying so keeps the analyzer honest about the rest.
                    $null = $Step, $Context
                    [pscustomobject] @{ Status = 'Completed'; ExitCode = 0; Message = 'beeped'; Data = $null }
                }
                function Test-HDTContosoBeepStepApplicable {
                    param($Step, $Context)
                    # The step contract requires both parameters; this double reads
                    # neither, and saying so keeps the analyzer honest about the rest.
                    $null = $Step, $Context
                    $true
                }
                function Get-HDTContosoBeepStepDescription {
                    param($Step)
                    # The step contract requires -Step; this double does not read it.
                    $null = $Step
                    'Beep once'
                }
                function Invoke-HDTContosoQuietStep {
                    param($Step, $Context)
                    # The step contract requires both parameters; this double reads
                    # neither, and saying so keeps the analyzer honest about the rest.
                    $null = $Step, $Context
                    [pscustomobject] @{ Status = 'Completed'; ExitCode = 0; Message = ''; Data = $null }
                }
                function Invoke-HDTContosoNotAType {
                    param($Step, $Context)
                    # The step contract requires both parameters; this double reads
                    # neither, and saying so keeps the analyzer honest about the rest.
                    $null = $Step, $Context
                    'this is not a step'
                }
                Export-ModuleMember -Function 'Invoke-HDTContosoBeepStep', 'Test-HDTContosoBeepStepApplicable',
                'Get-HDTContosoBeepStepDescription', 'Invoke-HDTContosoQuietStep', 'Invoke-HDTContosoNotAType'
            } | Import-Module -Force
        }

        AfterEach {
            Remove-Module -Name HDTThirdParty -Force -ErrorAction SilentlyContinue
        }

        It 'discovers a step type from another module' {
            @(Get-HDTStepType | ForEach-Object { $_.Type }) | Should -Contain 'ContosoBeep'
        }

        It 'derives the type name from the function name' {
            $type = @(Get-HDTStepType -Name 'ContosoBeep')[0]

            $type.Type | Should -BeExactly 'ContosoBeep'
            $type.InvokeCommand.Name | Should -BeExactly 'Invoke-HDTContosoBeepStep'
        }

        It 'reports the source module of a discovered type' {
            $type = @(Get-HDTStepType -Name 'ContosoBeep')[0]

            $type.Source | Should -BeExactly 'HDTThirdParty'
        }

        It 'discovers its optional Test and Description commands' {
            $type = @(Get-HDTStepType -Name 'ContosoBeep')[0]

            $type.TestCommand.Name | Should -BeExactly 'Test-HDTContosoBeepStepApplicable'
            $type.DescriptionCommand.Name | Should -BeExactly 'Get-HDTContosoBeepStepDescription'
        }

        It 'returns null for a test command that does not exist' {
            $type = @(Get-HDTStepType -Name 'ContosoQuiet')[0]

            $type.TestCommand | Should -BeNullOrEmpty
        }

        It 'returns null for a description command that does not exist' {
            $type = @(Get-HDTStepType -Name 'ContosoQuiet')[0]

            $type.DescriptionCommand | Should -BeNullOrEmpty
        }

        It 'filters by -Name' {
            @(Get-HDTStepType -Name 'ContosoBeep' | ForEach-Object { $_.Type }) | Should -Be @('ContosoBeep')
        }

        It 'filters by -Name case-insensitively' {
            @(Get-HDTStepType -Name 'contosobeep' | ForEach-Object { $_.Type }) | Should -Be @('ContosoBeep')
        }

        It 'returns nothing for an unknown name' {
            @(Get-HDTStepType -Name 'NoSuchTypeAnywhere') | Should -BeNullOrEmpty
        }

        It 'does not treat Invoke-HDTStep as a step type' {
            # The dispatcher must not discover itself: Invoke-HDTStep matches the
            # wildcard but not the pattern, because the type part is empty.
            @(Get-HDTStepType | ForEach-Object { $_.Type }) | Should -Not -Contain ''
            @(Get-HDTStepType | ForEach-Object { $_.InvokeCommand.Name }) | Should -Not -Contain 'Invoke-HDTStep'
        }

        It 'ignores a function that does not end in Step' {
            @(Get-HDTStepType | ForEach-Object { $_.InvokeCommand.Name }) | Should -Not -Contain 'Invoke-HDTContosoNotAType'
        }

        It 'returns the registry sorted by type' {
            $type = @(Get-HDTStepType | ForEach-Object { $_.Type })

            @($type) | Should -Be @($type | Sort-Object)
        }
    }

    Context 'a shadowed type' {

        AfterEach {
            Remove-Module -Name HDTVendorOne -Force -ErrorAction SilentlyContinue
            Remove-Module -Name HDTVendorTwo -Force -ErrorAction SilentlyContinue
        }

        It 'throws naming both sources when two modules export the same type' {
            # A third party silently shadowing ApplyImage is exactly the failure
            # that must not be quiet.
            New-Module -Name HDTVendorOne -ScriptBlock {
                function Invoke-HDTDuplicateStep {
                    param($Step, $Context)
                    # The step contract requires both parameters; this double reads
                    # neither, and saying so keeps the analyzer honest about the rest.
                    $null = $Step, $Context
                    'one'
                }
                Export-ModuleMember -Function Invoke-HDTDuplicateStep
            } | Import-Module -Force

            New-Module -Name HDTVendorTwo -ScriptBlock {
                function Invoke-HDTDuplicateStep {
                    param($Step, $Context)
                    # The step contract requires both parameters; this double reads
                    # neither, and saying so keeps the analyzer honest about the rest.
                    $null = $Step, $Context
                    'two'
                }
                Export-ModuleMember -Function Invoke-HDTDuplicateStep
            } | Import-Module -Force

            $record = $null
            try { Get-HDTStepType } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*HDTVendorOne*'
            $record.Exception.Message | Should -BeLike '*HDTVendorTwo*'
            $record.Exception.Message | Should -BeLike '*Duplicate*'
        }
    }

    Context "this module's own types" {

        It 'discovers every step file under Public/Steps' {
            $onDisk = @(Get-ChildItem -LiteralPath $script:stepFileRoot -Filter 'Invoke-HDT*Step.ps1' -File -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.BaseName -replace '^Invoke-HDT(.+)Step$', '$1' }) | Sort-Object

            $discovered = @(Get-HDTStepType | Where-Object { $_.Source -eq 'Hephaestus' } | ForEach-Object { $_.Type }) | Sort-Object

            ($discovered -join ',') | Should -BeExactly ($onDisk -join ',')
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name Get-HDTStepType -ErrorAction Stop

            $help.Name | Should -BeExactly 'Get-HDTStepType'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
