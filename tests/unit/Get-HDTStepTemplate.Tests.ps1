# THE ADD MENU IS THE ENGINE'S, NOT THE WINDOW'S.
#
# The console is a wrapper around this command line. When an administrator picks
# a step from the Add drop-down, what is behind it is the engine deciding what a
# new step of that type looks like on disk - so a type the ENGINE cannot author
# must not be offerable, no matter what the window would like to show.
#
# That makes the rule testable rather than a convention: a step type is addable
# if and only if it exports Get-HDT<Type>StepTemplate, and Get-HDTStepType says
# so on the row. A third-party type that ships only Invoke-HDT<Type>Step still
# RUNS - an existing sequence naming it executes exactly as before - it just
# cannot be created from a menu, because nothing knows what to write.
#
# The templates are asserted by ROUND TRIP, not by string. What matters is not
# the exact indentation but that Import-HDTSequenceDocument reads the emitted
# lines back as one step of the right type. A template that produces a document
# the engine cannot re-read is the failure that would strand the editor holding
# an unparseable file.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:probePath = 'C:\HDTLab\does-not-exist\sequence.yaml'

    # The lines a template returns are a fragment: a list item that belongs under
    # a sequence's steps:. This wraps one into the smallest legal document and
    # seeds it into a fake filesystem, so Import-HDTSequenceDocument can be
    # pointed at it without touching a disk.
    function Get-HDTTemplateProbe {
        param([string[]] $Line)

        $text = New-Object -TypeName System.Collections.ArrayList
        [void] $text.Add('schemaVersion: 1')
        [void] $text.Add('id: TEMPLATE')
        [void] $text.Add('name: Template probe')
        [void] $text.Add('steps:')

        foreach ($one in $Line) {
            [void] $text.Add('  ' + $one)
        }

        $fileSystem = New-HDTFakeFileSystem -File @{ 'C:\HDTLab\does-not-exist\sequence.yaml' = (@($text) -join "`n") }

        return (Import-HDTSequenceDocument -Path 'C:\HDTLab\does-not-exist\sequence.yaml' -FileSystem $fileSystem)
    }
}

Describe 'the step template contract' {

    Context 'every type this engine ships' {

        # Read off the registry rather than listed here, so a step type added
        # tomorrow fails this suite until it can be authored as well as run.
        BeforeAll {
            $script:shipped = @(Get-HDTStepType | Where-Object { $_.Source -eq 'Hephaestus' })
        }

        It 'has at least the ten types that shipped' {
            @($script:shipped).Count | Should -BeGreaterOrEqual 10
        }

        It 'exports a template command for every one of them' {
            $missing = @($script:shipped | Where-Object { $null -eq $_.TemplateCommand } |
                    ForEach-Object { $_.Type })

            $missing -join ', ' | Should -BeNullOrEmpty
        }

        It 'reports CanAdd true for every one of them' {
            $notAddable = @($script:shipped | Where-Object { -not $_.CanAdd } |
                    ForEach-Object { $_.Type })

            $notAddable -join ', ' | Should -BeNullOrEmpty
        }
    }

    Context 'what a template produces' {

        BeforeAll {
            $script:shipped = @(Get-HDTStepType | Where-Object { $_.Source -eq 'Hephaestus' })
        }

        It 'returns a string array of at least a name and a type' {
            foreach ($type in $script:shipped) {
                $line = @(& $type.TemplateCommand)

                $line.Count | Should -BeGreaterOrEqual 2 -Because ('{0} must emit a name and a type' -f $type.Type)
                $line[0] | Should -BeOfType ([string])
            }
        }

        It 'reads back through Import-HDTSequenceDocument as one step of that type' {
            foreach ($type in $script:shipped) {
                $document = Get-HDTTemplateProbe -Line @(& $type.TemplateCommand)

                @($document.Step).Count | Should -Be 1 -Because ('{0} must emit exactly one step' -f $type.Type)
                $document.Step[0].Type | Should -Be $type.Type
            }
        }

        It 'gives the step a non-empty name' {
            foreach ($type in $script:shipped) {
                $document = Get-HDTTemplateProbe -Line @(& $type.TemplateCommand)

                $document.Step[0].Name | Should -Not -BeNullOrEmpty -Because ('{0} must name its step' -f $type.Type)
            }
        }

        It 'takes an overriding name' {
            foreach ($type in $script:shipped) {
                $document = Get-HDTTemplateProbe -Line @(& $type.TemplateCommand -Name 'Chosen name')

                $document.Step[0].Name | Should -Be 'Chosen name' -Because ('{0} must honour -Name' -f $type.Type)
            }
        }

        It 'produces a step the validator accepts' {
            foreach ($type in $script:shipped) {
                $document = Get-HDTTemplateProbe -Line @(& $type.TemplateCommand)
                $finding = @(Test-HDTTaskSequence -Sequence $document |
                        Where-Object { $_.Severity -eq 'Error' })

                $finding.Count | Should -Be 0 -Because ('{0}: {1}' -f $type.Type, (@($finding | ForEach-Object { $_.Message }) -join '; '))
            }
        }
    }

    Context 'a type that cannot be authored' {

        BeforeAll {
            # A third party that shipped only the runner. It is a real step type -
            # a sequence naming it executes - but nothing in the session knows
            # what YAML to write for a new one.
            New-Module -Name HDTNoTemplateVendor -ScriptBlock {
                function Invoke-HDTContosoOpaqueStep {
                    param($Step, $Context)

                    $null = $Step, $Context
                    return $null
                }

                Export-ModuleMember -Function Invoke-HDTContosoOpaqueStep
            } | Import-Module -Force -Global
        }

        AfterAll {
            Remove-Module -Name HDTNoTemplateVendor -Force -ErrorAction SilentlyContinue
        }

        It 'is still discovered as a step type' {
            @(Get-HDTStepType -Name 'ContosoOpaque').Count | Should -Be 1
        }

        It 'has no template command' {
            (Get-HDTStepType -Name 'ContosoOpaque').TemplateCommand | Should -BeNullOrEmpty
        }

        It 'reports CanAdd false' {
            (Get-HDTStepType -Name 'ContosoOpaque').CanAdd | Should -BeFalse
        }
    }

    Context 'a template from another module' {

        BeforeAll {
            New-Module -Name HDTTemplateVendor -ScriptBlock {
                function Invoke-HDTContosoBeepStep {
                    param($Step, $Context)

                    $null = $Step, $Context
                    return $null
                }

                function Get-HDTContosoBeepStepTemplate {
                    param([string] $Name = 'Beep')

                    return [string[]] @(
                        ('- name: {0}' -f $Name)
                        '  type: ContosoBeep'
                    )
                }

                Export-ModuleMember -Function Invoke-HDTContosoBeepStep, Get-HDTContosoBeepStepTemplate
            } | Import-Module -Force -Global
        }

        AfterAll {
            Remove-Module -Name HDTTemplateVendor -Force -ErrorAction SilentlyContinue
        }

        It 'reports CanAdd true' {
            (Get-HDTStepType -Name 'ContosoBeep').CanAdd | Should -BeTrue
        }

        It 'carries the vendor template command' {
            (Get-HDTStepType -Name 'ContosoBeep').TemplateCommand.Name |
                Should -Be 'Get-HDTContosoBeepStepTemplate'
        }
    }
}
