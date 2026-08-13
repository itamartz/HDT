# Get-HDTVariableProvenance is what makes DESIGN 3.1's promise usable: provenance
# survives the resolution call and can be QUERIED afterwards, by name and by
# wildcard, rather than only having scrolled past in a log.
#
# "Why is HDTComputerName that?" is the question an administrator actually asks,
# and it is asked about one variable at a time.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:rulesPath = 'C:\HDTLab\does-not-exist\ws\rules.yaml'
    $script:fileSystem = New-HDTFakeFileSystem -File @{
        $script:rulesPath = @'
schemaVersion: 1
rules:
  - name: Fallback
    set:
      HDTComputerName: "PC-%HDTSerialNumber%"
      HDTJoinWorkgroup: WORKGROUP
'@
    }

    $script:rules = Import-HDTRuleDocument -Path $script:rulesPath -FileSystem $script:fileSystem

    $script:result = Resolve-HDTVariable `
        -CommandLine @{ HDTTaskSequenceID = 'CMD-CLIENT' } `
        -RuleDocument $script:rules `
        -Fact @{ HDTSerialNumber = 'FIXTURE-SERIAL-0001' } `
        -SequenceDefault @{ HDTDiskLayout = 'uefi-standard' }
}

Describe 'Get-HDTVariableProvenance' {

    It 'returns every record when no name is given' {
        $record = @(Get-HDTVariableProvenance -Resolution $script:result)

        $record.Count | Should -Be @($script:result.Variable.Keys).Count
        @($record | ForEach-Object { $_.Name }) | Should -Contain 'HDTComputerName'
    }

    It 'returns records ordered by Order' {
        $record = @(Get-HDTVariableProvenance -Resolution $script:result)

        @($record | ForEach-Object { $_.Order }) | Should -Be @(1..$record.Count)
    }

    It 'filters by name' {
        $record = @(Get-HDTVariableProvenance -Resolution $script:result -Name 'HDTComputerName')

        $record.Count | Should -Be 1
        $record[0].Name | Should -BeExactly 'HDTComputerName'
        $record[0].Source | Should -BeExactly 'Rule'
    }

    It 'filters by wildcard' {
        $record = @(Get-HDTVariableProvenance -Resolution $script:result -Name 'HDTJoin*')

        $record.Count | Should -Be 1
        $record[0].Name | Should -BeExactly 'HDTJoinWorkgroup'
    }

    It 'returns nothing for a variable that was never resolved' {
        @(Get-HDTVariableProvenance -Resolution $script:result -Name 'HDTDriverGroup').Count | Should -Be 0
    }

    It 'returns nothing rather than throwing for an unknown name' {
        # Asking about a variable nothing set is a normal question with a normal
        # answer - "nothing set it" - not an error.
        { Get-HDTVariableProvenance -Resolution $script:result -Name 'HDTNoSuchVariable' } | Should -Not -Throw
    }

    It 'has comment-based help with a synopsis' {
        $command = Get-Command -Name Get-HDTVariableProvenance -Module Hephaestus -ErrorAction Stop
        $help = Get-Help -Name $command.Name -ErrorAction Stop

        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -Match 'Get-HDTVariableProvenance \['
    }
}
