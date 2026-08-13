# Assert-HDTRuleDocument holds the authoring rules for rules.yaml (DESIGN 3.3),
# and every one of them produces a message an administrator can act on
# (DESIGN 12.1: a Configuration failure fails fast and points at the file).
#
# The locator is the RULE, not a line number. ConvertFrom-Yaml does not carry
# line information onto the object graph it returns, so once a document has
# parsed there is no honest line to report - "rule 2 ('Latitude naming')" is the
# most precise thing available, and it is more useful than a line anyway when a
# rule spans six of them.
#
# It is private, so every assertion runs inside InModuleScope. The document is
# always produced by ConvertFrom-HDTYaml rather than hand-built, so these tests
# fail if the two halves of the pipeline ever stop agreeing about shape.

$script:HDTRejection = @(
    @{
        Case     = 'a null document'
        Yaml     = ''
        Expected = '*rules.yaml*is empty*'
    }
    @{
        Case     = 'a document that is not a mapping'
        Yaml     = "- Lab subnet`n- Fallback`n"
        Expected = '*rules.yaml*mapping*'
    }
    @{
        Case     = 'a missing schemaVersion'
        Yaml     = "rules:`n  - name: Fallback`n    set:`n      HDTJoinWorkgroup: WORKGROUP`n"
        Expected = '*rules.yaml*schemaVersion*'
    }
    @{
        Case     = 'a schemaVersion that is not an integer'
        Yaml     = "schemaVersion: one`nrules:`n  - name: Fallback`n    set:`n      HDTJoinWorkgroup: WORKGROUP`n"
        Expected = '*rules.yaml*schemaVersion*integer*'
    }
    @{
        Case     = 'a schemaVersion newer than the engine supports'
        Yaml     = "schemaVersion: 99`nrules:`n  - name: Fallback`n    set:`n      HDTJoinWorkgroup: WORKGROUP`n"
        Expected = '*rules.yaml*schemaVersion 99*'
    }
    @{
        Case     = 'a missing rules key'
        Yaml     = "schemaVersion: 1`n"
        Expected = '*rules.yaml*rules*'
    }
    @{
        Case     = 'a rules key that is not a list'
        Yaml     = "schemaVersion: 1`nrules: everything`n"
        Expected = '*rules.yaml*rules*list*'
    }
    @{
        Case     = 'an empty rules list'
        Yaml     = "schemaVersion: 1`nrules: []`n"
        Expected = '*rules.yaml*at least one rule*'
    }
    @{
        Case     = 'a rule that is not a mapping'
        Yaml     = "schemaVersion: 1`nrules:`n  - Fallback`n"
        Expected = '*rules.yaml*rule 1*mapping*'
    }
    @{
        Case     = 'a rule with no name'
        Yaml     = "schemaVersion: 1`nrules:`n  - set:`n      HDTJoinWorkgroup: WORKGROUP`n"
        Expected = '*rules.yaml*rule 1*name*'
    }
    @{
        Case     = 'a rule with an empty name'
        Yaml     = "schemaVersion: 1`nrules:`n  - name: ''`n    set:`n      HDTJoinWorkgroup: WORKGROUP`n"
        Expected = '*rules.yaml*rule 1*name*'
    }
    @{
        Case     = 'two rules with the same name'
        Yaml     = "schemaVersion: 1`nrules:`n  - name: Fallback`n    set:`n      HDTJoinWorkgroup: WORKGROUP`n  - name: Fallback`n    set:`n      HDTComputerName: PC-1`n"
        Expected = "*rules.yaml*rule 2 ('Fallback')*"
    }
    @{
        Case     = 'a rule with neither set nor setFrom'
        Yaml     = "schemaVersion: 1`nrules:`n  - name: Lab subnet`n    when: { HDTDefaultGateway: `"10.20.30.1`" }`n"
        Expected = "*rules.yaml*rule 1 ('Lab subnet')*set*setFrom*"
    }
    @{
        Case     = 'a rule with both set and setFrom'
        Yaml     = "schemaVersion: 1`nrules:`n  - name: Scripted name`n    setFrom: Scripts\Get-ComputerName.ps1`n    set:`n      HDTComputerName: PC-1`n"
        Expected = "*rules.yaml*rule 1 ('Scripted name')*set*setFrom*"
    }
    @{
        Case     = 'an unknown key on a rule'
        Yaml     = "schemaVersion: 1`nrules:`n  - name: Lab subnet`n    priority: 10`n    set:`n      HDTComputerName: PC-1`n"
        Expected = "*rules.yaml*rule 1 ('Lab subnet')*priority*"
    }
    @{
        Case     = 'an empty when mapping'
        Yaml     = "schemaVersion: 1`nrules:`n  - name: Lab subnet`n    when: {}`n    set:`n      HDTComputerName: PC-1`n"
        Expected = "*rules.yaml*rule 1 ('Lab subnet')*when*"
    }
    @{
        Case     = 'a nested mapping inside when'
        Yaml     = "schemaVersion: 1`nrules:`n  - name: Lab subnet`n    when:`n      HDTModel:`n        equals: Latitude`n    set:`n      HDTComputerName: PC-1`n"
        Expected = "*rules.yaml*rule 1 ('Lab subnet')*HDTModel*"
    }
    @{
        Case     = 'an empty set mapping'
        Yaml     = "schemaVersion: 1`nrules:`n  - name: Fallback`n    set: {}`n"
        Expected = "*rules.yaml*rule 1 ('Fallback')*set*"
    }
    @{
        Case     = 'a set key that does not start with HDT'
        Yaml     = "schemaVersion: 1`nrules:`n  - name: Fallback`n    set:`n      ComputerName: PC-1`n"
        Expected = "*rules.yaml*rule 1 ('Fallback')*ComputerName*"
    }
    @{
        Case     = 'a set key that starts with an underscore'
        Yaml     = "schemaVersion: 1`nrules:`n  - name: Redirect the log`n    set:`n      _HDTLogPath: X:\Logs`n"
        Expected = "*rules.yaml*rule 1 ('Redirect the log')*_HDTLogPath*engine*"
    }
    @{
        Case     = 'an empty setFrom'
        Yaml     = "schemaVersion: 1`nrules:`n  - name: Scripted name`n    setFrom: ''`n"
        Expected = "*rules.yaml*rule 1 ('Scripted name')*setFrom*"
    }
)

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:fixtureRoot = Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/rules'
}

Describe 'Assert-HDTRuleDocument' {

    It 'accepts the DESIGN 3.3 example' {
        $yaml = Get-Content -LiteralPath (Join-Path -Path $script:fixtureRoot -ChildPath 'valid-design-example.yaml') -Raw

        {
            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                param($Yaml)
                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml'
                Assert-HDTRuleDocument -Document $document -Path 'C:\ws\rules.yaml'
            }
        } | Should -Not -Throw
    }

    It 'accepts a setFrom rule' {
        $yaml = Get-Content -LiteralPath (Join-Path -Path $script:fixtureRoot -ChildPath 'valid-setfrom.yaml') -Raw

        {
            InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
                param($Yaml)
                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml'
                Assert-HDTRuleDocument -Document $document -Path 'C:\ws\rules.yaml'
            }
        } | Should -Not -Throw
    }

    It 'returns nothing when the document is valid' {
        $yaml = Get-Content -LiteralPath (Join-Path -Path $script:fixtureRoot -ChildPath 'valid-fallback-only.yaml') -Raw

        $output = InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
            param($Yaml)
            $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml'
            Assert-HDTRuleDocument -Document $document -Path 'C:\ws\rules.yaml'
        }

        $output | Should -BeNullOrEmpty
    }

    It 'rejects <Case>' -ForEach $script:HDTRejection {
        $text = $Yaml
        $pattern = $Expected

        {
            InModuleScope Hephaestus -Parameters @{ Yaml = $text } {
                param($Yaml)
                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml'
                Assert-HDTRuleDocument -Document $document -Path 'C:\ws\rules.yaml'
            }
        } | Should -Throw -ExpectedMessage $pattern
    }

    It 'lists the allowed keys when it rejects an unknown one' {
        $yaml = "schemaVersion: 1`nrules:`n  - name: Lab subnet`n    priority: 10`n    set:`n      HDTComputerName: PC-1`n"

        $record = InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
            param($Yaml)
            $captured = $null
            try {
                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml'
                Assert-HDTRuleDocument -Document $document -Path 'C:\ws\rules.yaml'
            } catch { $captured = $_ }
            $captured
        }

        foreach ($allowed in @('name', 'when', 'set', 'setFrom')) {
            $record.Exception.Message | Should -BeLike ('*{0}*' -f $allowed)
        }
    }

    It 'delegates the schemaVersion comparison to Test-HDTSchemaVersion' {
        # DESIGN 12.3's refusal already exists as a tested function. Reimplementing
        # the comparison here would give the engine two answers to one question.
        $yaml = "schemaVersion: 99`nrules:`n  - name: Fallback`n    set:`n      HDTJoinWorkgroup: WORKGROUP`n"

        InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
            param($Yaml)
            Mock Test-HDTSchemaVersion { return $false }

            $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml'
            { Assert-HDTRuleDocument -Document $document -Path 'C:\ws\rules.yaml' } | Should -Throw

            Should -Invoke Test-HDTSchemaVersion -Times 1 -Exactly
        }
    }

    It 'names the file in every message' {
        $failure = @()

        foreach ($file in @(Get-ChildItem -LiteralPath $script:fixtureRoot -Filter 'invalid-*.yaml' -File)) {
            $yaml = Get-Content -LiteralPath $file.FullName -Raw
            $path = Join-Path -Path 'C:\ws' -ChildPath $file.Name

            $record = InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $path } {
                param($Yaml, $Path)
                $captured = $null
                try {
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
                    Assert-HDTRuleDocument -Document $document -Path $Path
                } catch { $captured = $_ }
                $captured
            }

            if ($null -eq $record) {
                $failure += ('{0} was not rejected at all' -f $file.Name)
            } elseif ($record.Exception.Message -notlike ('*{0}*' -f $file.Name)) {
                $failure += ('{0} produced "{1}"' -f $file.Name, $record.Exception.Message)
            }
        }

        $failure -join '; ' | Should -BeExactly ''
    }

    It 'uses the HDTConfigurationError error id for every rejection' {
        $failure = @()

        foreach ($file in @(Get-ChildItem -LiteralPath $script:fixtureRoot -Filter 'invalid-*.yaml' -File)) {
            $yaml = Get-Content -LiteralPath $file.FullName -Raw
            $path = Join-Path -Path 'C:\ws' -ChildPath $file.Name

            $record = InModuleScope Hephaestus -Parameters @{ Yaml = $yaml; Path = $path } {
                param($Yaml, $Path)
                $captured = $null
                try {
                    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
                    Assert-HDTRuleDocument -Document $document -Path $Path
                } catch { $captured = $_ }
                $captured
            }

            if ($null -eq $record -or $record.FullyQualifiedErrorId -notlike 'HDTConfigurationError*') {
                $failure += $file.Name
            }
        }

        $failure -join ', ' | Should -BeExactly ''
    }

    It 'reports the path as the target object' {
        $yaml = "schemaVersion: 1`n"

        $record = InModuleScope Hephaestus -Parameters @{ Yaml = $yaml } {
            param($Yaml)
            $captured = $null
            try {
                $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path 'C:\ws\rules.yaml'
                Assert-HDTRuleDocument -Document $document -Path 'C:\ws\rules.yaml'
            } catch { $captured = $_ }
            $captured
        }

        $record.TargetObject | Should -BeExactly 'C:\ws\rules.yaml'
    }

    It 'has comment-based help with a synopsis' {
        InModuleScope Hephaestus {
            $help = Get-Help -Name Assert-HDTRuleDocument -ErrorAction Stop

            # Get-Help falls back to a fuzzy search when nothing matches exactly
            # and will return another command's help, which passes a bare
            # synopsis assertion. Assert the name first.
            $help.Name | Should -BeExactly 'Assert-HDTRuleDocument'
            $help.Synopsis | Should -Not -BeNullOrEmpty
            $help.Synopsis | Should -Not -Match 'Assert-HDTRuleDocument \['
        }
    }
}
