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

        # Asserted against the TEXT, not against ConvertFrom-Json's object:
        # ConvertFrom-Json turns an ISO 8601 string back into a [datetime], which
        # would hide the very difference this test exists to catch. The \s* also
        # absorbs the one cosmetic difference between the engines - 5.1 puts two
        # spaces after the colon, pwsh 7 puts one.
        $script:fileSystem.ReadAllText($script:exportPath) |
            Should -Match '"generated"\s*:\s*"2026-08-13T00:11:02\.4810000Z"'
    }

    It 'writes the same JSON under both engines' {
        Export-HDTVariableProvenance -Resolution $script:result -Path $script:exportPath `
            -FileSystem $script:fileSystem -Timestamp $script:timestamp

        $text = $script:fileSystem.ReadAllText($script:exportPath)

        # \/Date(1786579862481)\/ is what Windows PowerShell 5.1 writes for a raw
        # [datetime], and WinPE is 5.1.
        $text | Should -Not -BeLike '*/Date(*'
        $text | Should -Match '"generated"\s*:\s*"\d{4}-\d{2}-\d{2}T'
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

# THE LOCAL ADMINISTRATOR PASSWORD WAS IN THIS FILE, IN CLEAR.
#
# Found on a deployed machine at C:\HDT\Logs\<run>\Gather\provenance.json:
# HDTAdminPassword with its actual value beside it. Everything else in HDT
# already knew that variable was secret - the wizard summary renders it as
# "(set, not shown)", the console log redacts it, the unattend step scrubs it -
# and this one writer did not ask.
#
# THE FIX IS AT THE WRITER, NOT AT THE MOVER. Keeping the file out of the logs
# would have hidden the same defect somewhere else: the value should never have
# been written down at all, and the file is copied to a share by SLShare and
# read by whoever is diagnosing a deployment.
#
# AND IT IS DRIVEN OFF THE SET, NOT OFF ONE NAME (CLAUDE.md rule 8). A test that
# grepped for HDTAdminPassword would pass for that variable and fail for nobody
# after it. Get-HDTVariableMap is where HDT records which variables are secret;
# every one of them is asserted here, so a secret added to the map tomorrow is
# covered by this file today.
Describe 'Export-HDTVariableProvenance and the values it must not write down' {

    BeforeAll {
        $script:secretName = @(Get-HDTVariableMap | Where-Object { $_.IsSecret } | ForEach-Object { [string] $_.HDTName })

        # A DISTINCT, FINDABLE VALUE PER VARIABLE. A shared literal could be
        # matched by the wrong entry and would make one leak look like none.
        $script:secretValue = @{}
        $index = 0
        foreach ($name in $script:secretName) {
            $index++
            $script:secretValue[$name] = ('SECRET-VALUE-{0:d2}-{1}' -f $index, [guid]::NewGuid().ToString('N').Substring(0, 8))
        }

        $script:secretResolution = Resolve-HDTVariable -CommandLine $script:secretValue -Fact @{}
    }

    It 'knows of at least one secret to redact' {
        # Non-vacuity: an IsSecret column nothing sets would make every
        # assertion below pass over an empty set.
        @($script:secretName).Count | Should -BeGreaterThan 0
    }

    It 'writes no secret value into the document' {
        $fileSystem = New-HDTFakeFileSystem

        Export-HDTVariableProvenance -Resolution $script:secretResolution -Path $script:exportPath -FileSystem $fileSystem

        $text = [string] $fileSystem.ReadAllText($script:exportPath)

        foreach ($name in $script:secretName) {
            $text | Should -Not -BeLike ('*{0}*' -f $script:secretValue[$name]) -Because ("{0} is marked secret" -f $name)
        }
    }

    It 'writes no secret value into rawValue either, which is where the unexpanded one lives' {
        $fileSystem = New-HDTFakeFileSystem

        Export-HDTVariableProvenance -Resolution $script:secretResolution -Path $script:exportPath -FileSystem $fileSystem

        $document = [string] $fileSystem.ReadAllText($script:exportPath) | ConvertFrom-Json

        foreach ($entry in @($document.variable | Where-Object { $script:secretName -contains [string] $_.name })) {
            [string] $entry.rawValue | Should -Not -Be $script:secretValue[[string] $entry.name]
        }
    }

    # THE POINT OF THE FILE IS WHICH SOURCE SET WHAT. Dropping the entry would
    # answer "where did the administrator password come from?" with silence,
    # which is the question somebody has when a machine will not accept it.
    It 'keeps the variable, its source and its order - it redacts only the value' {
        $fileSystem = New-HDTFakeFileSystem

        Export-HDTVariableProvenance -Resolution $script:secretResolution -Path $script:exportPath -FileSystem $fileSystem

        $document = [string] $fileSystem.ReadAllText($script:exportPath) | ConvertFrom-Json

        foreach ($name in $script:secretName) {
            $entry = @($document.variable | Where-Object { [string] $_.name -eq $name })[0]

            $entry | Should -Not -BeNullOrEmpty -Because ("{0} must still appear" -f $name)
            [string] $entry.source | Should -BeExactly 'CommandLine'
            [int] $entry.order | Should -BeGreaterThan 0
        }
    }

    It 'says the value was set rather than leaving it blank' {
        # A blank and a redaction read identically, and they mean opposite
        # things: one is a password nobody supplied, which is a deployment that
        # was going to fail.
        $fileSystem = New-HDTFakeFileSystem

        Export-HDTVariableProvenance -Resolution $script:secretResolution -Path $script:exportPath -FileSystem $fileSystem

        $document = [string] $fileSystem.ReadAllText($script:exportPath) | ConvertFrom-Json

        foreach ($name in $script:secretName) {
            $entry = @($document.variable | Where-Object { [string] $_.name -eq $name })[0]
            [string] $entry.value | Should -Not -BeNullOrEmpty -Because ("{0} was set and the file should say so" -f $name)
        }
    }

    It 'leaves every other variable exactly as it resolved' {
        $fileSystem = New-HDTFakeFileSystem

        $resolution = Resolve-HDTVariable -CommandLine @{ HDTComputerName = 'PC-0001'; HDTOrgName = 'Contoso' } -Fact @{}
        Export-HDTVariableProvenance -Resolution $resolution -Path $script:exportPath -FileSystem $fileSystem

        $document = [string] $fileSystem.ReadAllText($script:exportPath) | ConvertFrom-Json

        [string] @($document.variable | Where-Object { [string] $_.name -eq 'HDTComputerName' })[0].value |
            Should -BeExactly 'PC-0001'
        [string] @($document.variable | Where-Object { [string] $_.name -eq 'HDTOrgName' })[0].value |
            Should -BeExactly 'Contoso'
    }
}
