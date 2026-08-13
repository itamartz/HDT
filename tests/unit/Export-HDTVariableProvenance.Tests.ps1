# Export-HDTVariableProvenance writes DESIGN 4.4's Gather\provenance.json -
# "every variable + which source set it".
#
# THE TIMESTAMP IS FORMATTED BEFORE SERIALISATION, and that is the sharp edge in
# this file. ConvertTo-Json renders a raw [datetime] as an ISO 8601 string under
# pwsh 7 and as "\/Date(1786579862481)\/" under Windows PowerShell 5.1 - and 5.1
# is the engine that actually runs in WinPE, so a raw [datetime] would make the
# file unreadable exactly where it matters. The assertions below pin the literal
# string, so either engine fails if the [datetime] ever reaches ConvertTo-Json.
#
# It writes through the injected IFileSystem, never Set-Content, so the whole
# path is provable with nothing on disk.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:rulesPath = 'C:\HDTLab\does-not-exist\ws\rules.yaml'
    $script:exportPath = 'C:\HDTLab\does-not-exist\ws\Logs\Gather\provenance.json'

    $script:rules = Import-HDTRuleDocument -Path $script:rulesPath -FileSystem (New-HDTFakeFileSystem -File @{
            $script:rulesPath = @'
schemaVersion: 1
rules:
  - name: Fallback
    set:
      HDTComputerName: "PC-%HDTSerialNumber%"
      HDTJoinWorkgroup: WORKGROUP
'@
        })

    $script:result = Resolve-HDTVariable `
        -CommandLine @{ HDTTaskSequenceID = 'CMD-CLIENT' } `
        -RuleDocument $script:rules `
        -Fact @{ HDTSerialNumber = 'FIXTURE-SERIAL-0001' } `
        -SequenceDefault @{ HDTDiskLayout = 'uefi-standard' }

    # The instant probed on both engines while planning this work.
    $script:timestamp = [datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc)
}

Describe 'Export-HDTVariableProvenance' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem
    }

    It 'writes the file through the injected filesystem' {
        Export-HDTVariableProvenance -Resolution $script:result -Path $script:exportPath -FileSystem $script:fileSystem

        $script:fileSystem.GetOperationName() | Should -Contain 'WriteAllText'
    }

    It 'writes valid JSON' {
        Export-HDTVariableProvenance -Resolution $script:result -Path $script:exportPath -FileSystem $script:fileSystem

        { $script:fileSystem.ReadAllText($script:exportPath) | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'writes one entry per resolved variable' {
        Export-HDTVariableProvenance -Resolution $script:result -Path $script:exportPath -FileSystem $script:fileSystem

        $document = $script:fileSystem.ReadAllText($script:exportPath) | ConvertFrom-Json

        @($document.variable).Count | Should -Be @($script:result.Variable.Keys).Count
    }

    It 'writes the entries in resolution order' {
        Export-HDTVariableProvenance -Resolution $script:result -Path $script:exportPath -FileSystem $script:fileSystem

        $document = $script:fileSystem.ReadAllText($script:exportPath) | ConvertFrom-Json

        @($document.variable | ForEach-Object { $_.order }) | Should -Be @(1..@($document.variable).Count)
        $document.variable[0].name | Should -BeExactly 'HDTTaskSequenceID'
        $document.variable[0].source | Should -BeExactly 'CommandLine'
    }

    It 'writes the timestamp it was given' {
        Export-HDTVariableProvenance -Resolution $script:result -Path $script:exportPath `
            -FileSystem $script:fileSystem -Timestamp $script:timestamp

        $document = $script:fileSystem.ReadAllText($script:exportPath) | ConvertFrom-Json

        $document.generated | Should -BeExactly '2026-08-13T00:11:02.4810000Z'
    }

    It 'writes the same JSON under both engines' {
        Export-HDTVariableProvenance -Resolution $script:result -Path $script:exportPath `
            -FileSystem $script:fileSystem -Timestamp $script:timestamp

        $text = $script:fileSystem.ReadAllText($script:exportPath)

        $text | Should -Not -BeLike '*/Date(*'
        ($text | ConvertFrom-Json).generated | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }

    It 'writes schemaVersion 1' {
        Export-HDTVariableProvenance -Resolution $script:result -Path $script:exportPath -FileSystem $script:fileSystem

        ($script:fileSystem.ReadAllText($script:exportPath) | ConvertFrom-Json).schemaVersion | Should -Be 1
    }

    It 'creates the parent directory' {
        Export-HDTVariableProvenance -Resolution $script:result -Path $script:exportPath -FileSystem $script:fileSystem

        $script:fileSystem.TestPath('C:\HDTLab\does-not-exist\ws\Logs\Gather') | Should -BeTrue
    }

    It 'never touches the real filesystem' {
        Export-HDTVariableProvenance -Resolution $script:result -Path $script:exportPath -FileSystem $script:fileSystem

        Test-Path -LiteralPath $script:exportPath | Should -BeFalse
        Test-Path -LiteralPath 'C:\HDTLab\does-not-exist' | Should -BeFalse
    }

    It 'has comment-based help with a synopsis' {
        $command = Get-Command -Name Export-HDTVariableProvenance -Module Hephaestus -ErrorAction Stop
        $help = Get-Help -Name $command.Name -ErrorAction Stop

        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -Match 'Export-HDTVariableProvenance \['
    }
}
