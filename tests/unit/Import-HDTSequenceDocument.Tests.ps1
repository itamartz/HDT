# Import-HDTSequenceDocument is the public front door to sequence.yaml: read
# through an injected IFileSystem, parse, validate, FLATTEN.
#
# FLATTENING IS THE DESIGN DECISION THIS FILE GUARDS. A group is not an
# execution unit; it is a naming and condition device. Flattening to a linear,
# 1-based list means DESIGN 4.3's "skips completed steps by index" works
# unchanged with nesting, and a group whose condition is false produces one
# step.skip record per contained step naming the group - which is what a
# technician reading the log needs, rather than one line that hides six steps.
#
# Nothing here touches the real disk: fixture text is read once by the test and
# seeded into a fake filesystem.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:fixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/sequences'
    $script:sequencePath = 'C:\HDTLab\does-not-exist\sequence.yaml'

    $script:fixture = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $script:fixtureRoot -Filter '*.yaml' -File)) {
        $script:fixture[$file.Name] = Get-Content -LiteralPath $file.FullName -Raw
    }

    # Seeds a fake filesystem with one fixture and imports it.
    $script:import = {
        param([string] $FixtureName)

        $fs = New-HDTFakeFileSystem -File @{ 'C:\HDTLab\does-not-exist\sequence.yaml' = $script:fixture[$FixtureName] }

        return (Import-HDTSequenceDocument -Path 'C:\HDTLab\does-not-exist\sequence.yaml' -FileSystem $fs)
    }
}

Describe 'Import-HDTSequenceDocument' {

    Context 'reading' {

        It 'reads through the injected filesystem' {
            $fs = New-HDTFakeFileSystem -File @{ $script:sequencePath = $script:fixture['valid-flat.yaml'] }

            $null = Import-HDTSequenceDocument -Path $script:sequencePath -FileSystem $fs

            $fs.GetOperationName() | Should -Contain 'ReadAllText'
            Test-Path -LiteralPath $script:sequencePath | Should -BeFalse
        }

        It 'throws ObjectNotFound naming the file when it does not exist' {
            $fs = New-HDTFakeFileSystem

            $record = $null
            try { Import-HDTSequenceDocument -Path $script:sequencePath -FileSystem $fs } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.CategoryInfo.Category | Should -Be ([System.Management.Automation.ErrorCategory]::ObjectNotFound)
            $record.TargetObject | Should -BeExactly $script:sequencePath
        }

        It 'reports a YAML syntax error with the file and the line' {
            $record = $null
            try { & $script:import 'unparseable-indentation.yaml' } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.Exception.Message | Should -BeLike '*sequence.yaml(*)*'
        }
    }

    Context 'the document' {

        It 'returns the id, name, description and schema version' {
            $document = & $script:import 'valid-design-example.yaml'

            $document.Path | Should -BeExactly $script:sequencePath
            $document.Id | Should -BeExactly 'STD-CLIENT'
            $document.Name | Should -BeExactly 'Standard Windows 11 Client'
            $document.Description | Should -BeExactly 'Bare-metal client build'
            $document.SchemaVersion | Should -Be 1
            $document.SchemaVersion | Should -BeOfType ([int])
        }

        It 'returns the sequence variables as an ordered dictionary' {
            $document = & $script:import 'valid-design-example.yaml'

            @($document.Variable.Keys) | Should -Be @('HDTOSImage', 'HDTDiskLayout')
            $document.Variable['HDTOSImage'] | Should -BeExactly 'Win11-24H2-Ent'
        }

        It 'looks a sequence variable up case-insensitively' {
            $document = & $script:import 'valid-design-example.yaml'

            $document.Variable['hdtosimage'] | Should -BeExactly 'Win11-24H2-Ent'
        }

        It 'returns an empty variable dictionary when the document declares none' {
            $document = & $script:import 'valid-flat.yaml'

            $document.Variable | Should -Not -BeNullOrEmpty
            @($document.Variable.Keys).Count | Should -Be 0
        }
    }

    Context 'flattening' {

        It 'numbers steps from one in execution order' {
            $document = & $script:import 'valid-flat.yaml'

            @($document.Step | ForEach-Object { $_.Index }) | Should -Be @(1, 2, 3)
            @($document.Step | ForEach-Object { $_.Name }) | Should -Be @('First', 'Second', 'Third')
        }

        It 'flattens a nested group into the linear list' {
            $document = & $script:import 'valid-nested-groups.yaml'

            @($document.Step | ForEach-Object { $_.Name }) |
                Should -Be @('Root Step', 'Outer Step', 'Inner Step', 'Inner Override', 'Sibling Step')
        }

        It 'preserves document order across sibling groups' {
            $document = & $script:import 'valid-nested-groups.yaml'

            $sibling = @($document.Step | Where-Object { $_.Name -eq 'Sibling Step' })[0]
            $inner = @($document.Step | Where-Object { $_.Name -eq 'Inner Step' })[0]

            $sibling.Index | Should -BeGreaterThan $inner.Index
        }

        It 'records the group path outermost first' {
            $document = & $script:import 'valid-nested-groups.yaml'

            $inner = @($document.Step | Where-Object { $_.Name -eq 'Inner Step' })[0]

            @($inner.GroupPath) | Should -Be @('Outer', 'Middle', 'Inner')
        }

        It 'records an empty group path for a root-level step' {
            $document = & $script:import 'valid-nested-groups.yaml'

            $root = @($document.Step | Where-Object { $_.Name -eq 'Root Step' })[0]

            @($root.GroupPath).Count | Should -Be 0
        }

        It 'carries the group condition onto every step inside it' {
            $document = & $script:import 'valid-design-example.yaml'

            foreach ($name in @('Join Domain', 'Install Applications', 'Windows Update', 'Custom')) {
                $step = @($document.Step | Where-Object { $_.Name -eq $name })[0]

                @($step.GroupCondition).Count | Should -Be 1
                @($step.GroupCondition)[0].Group | Should -BeExactly 'State Restore'
                @($step.GroupCondition)[0].Condition | Should -BeExactly '"%_HDTPhase%" == "FullOS"'
            }
        }

        It 'carries every ancestor condition, outermost first' {
            $document = & $script:import 'valid-nested-groups.yaml'

            $inner = @($document.Step | Where-Object { $_.Name -eq 'Inner Step' })[0]

            @($inner.GroupCondition | ForEach-Object { $_.Group }) | Should -Be @('Middle', 'Inner')
        }

        It 'does not carry a sibling group condition' {
            $document = & $script:import 'valid-nested-groups.yaml'

            $sibling = @($document.Step | Where-Object { $_.Name -eq 'Sibling Step' })[0]

            @($sibling.GroupCondition | ForEach-Object { $_.Group }) | Should -Be @('Sibling')
        }

        It 'inherits runIn from the nearest ancestor group' {
            $document = & $script:import 'valid-nested-groups.yaml'

            $inner = @($document.Step | Where-Object { $_.Name -eq 'Inner Step' })[0]

            $inner.RunIn | Should -BeExactly 'FullOS'
        }

        It 'lets a step override an inherited runIn' {
            $document = & $script:import 'valid-nested-groups.yaml'

            $override = @($document.Step | Where-Object { $_.Name -eq 'Inner Override' })[0]

            $override.RunIn | Should -BeExactly 'WinPE'
        }

        It 'records one entry per group node' {
            $document = & $script:import 'valid-nested-groups.yaml'

            @($document.Group | ForEach-Object { $_.Path -join '/' }) |
                Should -Be @('Outer', 'Outer/Middle', 'Outer/Middle/Inner', 'Sibling')
        }

        It 'counts every step of the DESIGN 4.1 example' {
            $document = & $script:import 'valid-design-example.yaml'

            @($document.Step | ForEach-Object { $_.Name }) | Should -Be @(
                'Validate',
                'Format and Partition',
                'Apply OS',
                'Inject Drivers',
                'Apply Unattend',
                'Prepare Boot',
                'Join Domain',
                'Install Applications',
                'Windows Update',
                'Custom')
        }
    }

    Context 'defaults' {

        BeforeEach {
            $script:flat = & $script:import 'valid-flat.yaml'
            $script:first = @($script:flat.Step)[0]
        }

        It 'defaults continueOnError to false' {
            $script:first.ContinueOnError | Should -BeFalse
            $script:first.ContinueOnError | Should -BeOfType ([bool])
        }

        It 'defaults runIn to Any' {
            $script:first.RunIn | Should -BeExactly 'Any'
        }

        It 'defaults timeoutMinutes to zero' {
            $script:first.TimeoutMinutes | Should -Be 0
        }

        It 'defaults retry to zero attempts' {
            $script:first.Retry.Count | Should -Be 0
            $script:first.Retry.DelaySecond | Should -Be 0
            $script:first.Retry.Backoff | Should -BeExactly 'fixed'
        }

        It 'defaults resumable to false' {
            $script:first.Resumable | Should -BeFalse
        }

        It 'defaults the condition to null' {
            $script:first.Condition | Should -BeNullOrEmpty
        }

        It 'defaults the step log to null' {
            $script:first.Log | Should -BeNullOrEmpty
        }

        It 'reads every common property when they are all present' {
            $document = & $script:import 'valid-retry-and-timeout.yaml'
            $step = @($document.Step)[0]

            $step.Condition | Should -BeExactly '"%_HDTPhase%" == "FullOS"'
            $step.ContinueOnError | Should -BeTrue
            $step.TimeoutMinutes | Should -Be 45
            $step.RunIn | Should -BeExactly 'FullOS'
            $step.Resumable | Should -BeTrue
            $step.Log | Should -BeExactly 'FlakyThing.log'
            $step.Retry.Count | Should -Be 3
            $step.Retry.DelaySecond | Should -Be 15
            $step.Retry.Backoff | Should -BeExactly 'exponential'
        }
    }

    Context 'step properties' {

        It 'puts type-specific keys in Property' {
            $document = & $script:import 'valid-design-example.yaml'
            $applyOs = @($document.Step | Where-Object { $_.Name -eq 'Apply OS' })[0]

            $applyOs.Property['os'] | Should -BeExactly 'Win11-24H2-Ent'
            $applyOs.Property['index'] | Should -Be 3
            $applyOs.Property['target'] | Should -BeExactly 'primary'
        }

        It 'keeps no common property in Property' {
            $document = & $script:import 'valid-retry-and-timeout.yaml'
            $step = @($document.Step)[0]

            foreach ($common in @('name', 'type', 'condition', 'continueOnError', 'timeoutMinutes', 'runIn', 'retry', 'resumable', 'log')) {
                $step.Property.Contains($common) | Should -BeFalse
            }

            @($step.Property.Keys) | Should -Be @('message')
        }

        It 'preserves the order of type-specific keys' {
            $document = & $script:import 'valid-design-example.yaml'
            $applyOs = @($document.Step | Where-Object { $_.Name -eq 'Apply OS' })[0]

            @($applyOs.Property.Keys) | Should -Be @('os', 'index', 'target')
        }

        It 'looks a step property up case-insensitively' {
            $document = & $script:import 'valid-design-example.yaml'
            $applyOs = @($document.Step | Where-Object { $_.Name -eq 'Apply OS' })[0]

            $applyOs.Property['OS'] | Should -BeExactly 'Win11-24H2-Ent'
        }

        It 'keeps a type-specific property called group' {
            # DESIGN 4.1's ApplyDrivers step declares `group: "%HDTDriverGroup%"`.
            # A node is a GROUP when it declares steps, so this stays a step
            # property rather than turning the node into a group.
            $document = & $script:import 'valid-design-example.yaml'
            $drivers = @($document.Step | Where-Object { $_.Name -eq 'Inject Drivers' })[0]

            $drivers.Type | Should -BeExactly 'ApplyDrivers'
            $drivers.Property['group'] | Should -BeExactly '%HDTDriverGroup%'
            @($drivers.GroupPath) | Should -Be @('Install')
        }
    }

    Context 'unknown step types' {

        It 'imports a sequence whose type this engine does not implement' {
            # The pluggability property: authoring does not require the step type
            # to be installed on the machine doing the authoring, and an unknown
            # type fails the STEP at execution, not the whole document at import.
            $document = & $script:import 'valid-design-example.yaml'

            @($document.Step | ForEach-Object { $_.Type }) | Should -Contain 'JoinDomain'
            (Get-Command -Name 'Invoke-HDTJoinDomainStep' -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        }
    }

    Context 'help' {

        It 'has comment-based help with a synopsis' {
            $help = Get-Help -Name Import-HDTSequenceDocument -ErrorAction Stop

            $help.Name | Should -BeExactly 'Import-HDTSequenceDocument'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
