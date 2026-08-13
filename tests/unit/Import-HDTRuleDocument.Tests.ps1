# Import-HDTRuleDocument is the public front door to rules.yaml: read through an
# injected IFileSystem, parse, validate, normalise.
#
# The normalisation is load-bearing rather than cosmetic. Plan 02-03 resolves
# variables in DOCUMENT ORDER and looks keys up CASE-INSENSITIVELY, and it must
# not have to care what the YAML parser handed back - so When and Set are
# re-materialised into an OrderedDictionary built with StringComparer::
# OrdinalIgnoreCase before they ever leave this function.
#
# Nothing here touches the real disk: the fixture text is read once by the test
# and seeded into a fake filesystem, and one test proves the engine never fell
# through to a real file.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:fixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/rules'
    $script:workspacePath = 'C:\HDTLab\does-not-exist\rules.yaml'

    $script:fixture = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $script:fixtureRoot -Filter '*.yaml' -File)) {
        $script:fixture[$file.Name] = Get-Content -LiteralPath $file.FullName -Raw
    }
}

Describe 'Import-HDTRuleDocument' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{
            $script:workspacePath = $script:fixture['valid-design-example.yaml']
        }
    }

    It 'reads the file through the injected filesystem' {
        $null = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $script:fileSystem

        $script:fileSystem.GetOperationName() | Should -Contain 'ReadAllText'
        Test-Path -LiteralPath $script:workspacePath | Should -BeFalse
    }

    It 'throws a configuration error when the file does not exist' {
        $empty = New-HDTFakeFileSystem

        { Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $empty } |
            Should -Throw -ExpectedMessage '*rules.yaml*'
    }

    It 'uses the HDTConfigurationError error id for a missing file' {
        $empty = New-HDTFakeFileSystem

        $record = $null
        try { Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $empty } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        $record.TargetObject | Should -BeExactly $script:workspacePath
    }

    It 'returns the path it was given' {
        $document = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $script:fileSystem

        $document.Path | Should -BeExactly $script:workspacePath
    }

    It 'returns the schemaVersion' {
        $document = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $script:fileSystem

        $document.SchemaVersion | Should -Be 1
        $document.SchemaVersion | Should -BeOfType ([int])
    }

    It 'returns one entry per rule, in document order' {
        $document = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $script:fileSystem

        @($document.Rule).Count | Should -Be 3
        @($document.Rule | ForEach-Object { $_.Name }) | Should -Be @('Lab subnet', 'Latitude naming', 'Fallback')
    }

    It 'numbers rules from one' {
        $document = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $script:fileSystem

        @($document.Rule | ForEach-Object { $_.Index }) | Should -Be @(1, 2, 3)
    }

    It 'returns When as an ordered dictionary' {
        $document = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $script:fileSystem

        @($document.Rule)[1].When | Should -BeOfType ([System.Collections.Specialized.OrderedDictionary])
        @(@($document.Rule)[1].When.Keys) | Should -Be @('HDTModel', 'HDTIsLaptop')
    }

    It 'returns Set in document order' {
        $document = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $script:fileSystem

        @(@($document.Rule)[0].Set.Keys) | Should -Be @('HDTJoinDomain', 'HDTTaskSequenceID', 'HDTSkipWizard')
    }

    It 'looks a Set key up case-insensitively' {
        $document = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $script:fileSystem

        @($document.Rule)[0].Set['hdtjoindomain'] | Should -BeExactly 'lab.contoso.com'
    }

    It 'looks a When key up case-insensitively' {
        $document = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $script:fileSystem

        @($document.Rule)[1].When['HDTMODEL'] | Should -BeExactly 'Latitude*'
    }

    It 'keeps the value types the parser produced' {
        $document = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $script:fileSystem

        @($document.Rule)[0].Set['HDTSkipWizard'] | Should -BeOfType ([bool])
        @($document.Rule)[1].When['HDTIsLaptop'] | Should -BeOfType ([bool])
    }

    It 'returns an empty When for a rule with no when' {
        $document = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $script:fileSystem

        $fallback = @($document.Rule)[2]
        $fallback.When | Should -Not -BeNullOrEmpty
        $fallback.When | Should -BeOfType ([System.Collections.Specialized.OrderedDictionary])
        @($fallback.When.Keys).Count | Should -Be 0
    }

    It 'returns SetFrom null for a rule that uses set' {
        $document = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $script:fileSystem

        @($document.Rule)[0].SetFrom | Should -BeNullOrEmpty
    }

    It 'returns SetFrom for a rule that uses setFrom' {
        $fs = New-HDTFakeFileSystem -File @{ $script:workspacePath = $script:fixture['valid-setfrom.yaml'] }

        $document = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $fs

        @($document.Rule)[0].SetFrom | Should -BeExactly 'Scripts\Get-ComputerName.ps1'
        @($document.Rule)[0].Set | Should -BeNullOrEmpty
    }

    It 'propagates the parse error for an unparseable document' {
        $fs = New-HDTFakeFileSystem -File @{ $script:workspacePath = $script:fixture['unparseable-indentation.yaml'] }

        { Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $fs } |
            Should -Throw -ExpectedMessage '*rules.yaml(4)*could not be parsed*'
    }

    It 'propagates the validation error for an invalid document' {
        $fs = New-HDTFakeFileSystem -File @{ $script:workspacePath = $script:fixture['invalid-engine-variable.yaml'] }

        { Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $fs } |
            Should -Throw -ExpectedMessage '*rules.yaml*_HDTLogPath*'
    }

    It 'rejects every invalid fixture' {
        $failure = @()

        foreach ($name in @($script:fixture.Keys | Where-Object { $_ -like 'invalid-*' -or $_ -like 'unparseable-*' })) {
            $fs = New-HDTFakeFileSystem -File @{ $script:workspacePath = $script:fixture[$name] }

            $record = $null
            try { Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $fs } catch { $record = $_ }

            # The error id is asserted, not merely the fact that something threw.
            # Without it this test passes against ANY failure - it was observed
            # passing against CommandNotFoundException before the implementation
            # existed, which is exactly the sort of green that means nothing.
            if ($null -eq $record -or $record.FullyQualifiedErrorId -notlike 'HDTConfigurationError*') {
                $failure += $name
            }
        }

        $failure -join ', ' | Should -BeExactly ''
    }

    It 'accepts every valid fixture' {
        $failure = @()

        foreach ($name in @($script:fixture.Keys | Where-Object { $_ -like 'valid-*' })) {
            $fs = New-HDTFakeFileSystem -File @{ $script:workspacePath = $script:fixture[$name] }

            try {
                $null = Import-HDTRuleDocument -Path $script:workspacePath -FileSystem $fs
            } catch {
                $failure += ('{0}: {1}' -f $name, $_.Exception.Message)
            }
        }

        $failure -join '; ' | Should -BeExactly ''
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Import-HDTRuleDocument -ErrorAction Stop

        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -Match 'Import-HDTRuleDocument \['
    }
}
