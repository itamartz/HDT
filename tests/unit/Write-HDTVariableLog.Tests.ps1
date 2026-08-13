# DESIGN 3.1: "the single biggest debugging pain in MDT is not knowing why
# HDTComputerName ended up as it did". Export-HDTVariableProvenance answers that
# from a file; this puts the same answer into the log STREAM, as one var.resolve
# record per variable, which is what the console's monitoring view reads.
#
# DESIGN 4.4.5 puts variable resolution at Debug ("Debug adds every variable
# resolution with its provenance"), so these records are emitted at Debug and a
# default Info context deliberately drops them.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:jsonlPath = 'X:\HDT\Logs\HDT.jsonl'
    $script:rulesYaml = @'
schemaVersion: 1
rules:
  - name: Default naming
    set:
      HDTComputerName: PC-DEFAULT
      HDTDriverGroup: Generic
'@
}

Describe 'Write-HDTVariableLog' {

    BeforeEach {
        $script:fs = New-HDTFakeFileSystem -File @{ 'C:\ws\rules.yaml' = $script:rulesYaml }
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc))
        $script:context = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fs -Clock $script:clock -Level Debug -ThreadId 4820

        $script:rules = Import-HDTRuleDocument -Path 'C:\ws\rules.yaml' -FileSystem $script:fs
        $script:resolution = Resolve-HDTVariable -RuleDocument $script:rules
    }

    It 'writes one var.resolve record per resolved variable' {
        Write-HDTVariableLog -Context $script:context -Resolution $script:resolution

        $line = @($script:fs.ReadAllText($script:jsonlPath) -split "`n" | Where-Object { $_ })
        $line.Count | Should -Be 2
        @($line | ForEach-Object { (ConvertFrom-Json -InputObject $_).event }) |
            Should -Be @('var.resolve', 'var.resolve')
    }

    It 'writes the variable name and value into the data payload' {
        Write-HDTVariableLog -Context $script:context -Resolution $script:resolution

        $line = @($script:fs.ReadAllText($script:jsonlPath) -split "`n" | Where-Object { $_ })
        $record = ConvertFrom-Json -InputObject $line[0]

        $record.data.name | Should -BeExactly 'HDTComputerName'
        $record.data.value | Should -BeExactly 'PC-DEFAULT'
    }

    It 'writes the source, rule and file from the provenance record' {
        Write-HDTVariableLog -Context $script:context -Resolution $script:resolution

        $line = @($script:fs.ReadAllText($script:jsonlPath) -split "`n" | Where-Object { $_ })
        $record = ConvertFrom-Json -InputObject $line[0]

        $record.data.source | Should -BeExactly 'Rule'
        $record.data.rule | Should -BeExactly 'Default naming'
        $record.data.file | Should -BeExactly 'C:\ws\rules.yaml'
    }

    It 'writes the records in resolution order' {
        Write-HDTVariableLog -Context $script:context -Resolution $script:resolution

        $line = @($script:fs.ReadAllText($script:jsonlPath) -split "`n" | Where-Object { $_ })
        @($line | ForEach-Object { (ConvertFrom-Json -InputObject $_).data.name }) |
            Should -Be @('HDTComputerName', 'HDTDriverGroup')
    }

    It 'names the variable in the message' {
        Write-HDTVariableLog -Context $script:context -Resolution $script:resolution

        $line = @($script:fs.ReadAllText($script:jsonlPath) -split "`n" | Where-Object { $_ })
        (ConvertFrom-Json -InputObject $line[0]).message | Should -BeLike '*HDTComputerName*'
    }

    It 'writes nothing for an empty resolution' {
        $empty = Resolve-HDTVariable

        Write-HDTVariableLog -Context $script:context -Resolution $empty

        @($script:fs.Operations | Where-Object { $_.Operation -eq 'AppendAllText' }).Count | Should -Be 0
    }

    It 'writes at Debug, so a default Info context drops it' {
        $quiet = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fs -Clock $script:clock

        Write-HDTVariableLog -Context $quiet -Resolution $script:resolution

        @($script:fs.Operations | Where-Object { $_.Operation -eq 'AppendAllText' }).Count | Should -Be 0
    }

    It 'logs unresolved tokens as a warning' {
        # 02-03 is explicit that an unresolved %Var% is surfaced in the log and is
        # not fatal: the deployment continues with the token left in place, and the
        # administrator gets told which name nothing supplied.
        $unresolved = Resolve-HDTVariable -CommandLine ([ordered] @{
                HDTComputerName = 'PC-%HDTSerialNumber%'
                HDTDriverGroup  = '%HDTModel%-drivers'
            })

        Write-HDTVariableLog -Context $script:context -Resolution $unresolved

        $line = @($script:fs.ReadAllText($script:jsonlPath) -split "`n" | Where-Object { $_ })
        $warning = @($line | ForEach-Object { ConvertFrom-Json -InputObject $_ } |
                Where-Object { $_.level -eq 'Warning' })

        $warning.Count | Should -Be 1
        $warning[0].message | Should -BeLike '*HDTModel*'
        $warning[0].message | Should -BeLike '*HDTSerialNumber*'
    }

    It 'writes no warning when nothing is unresolved' {
        Write-HDTVariableLog -Context $script:context -Resolution $script:resolution

        $line = @($script:fs.ReadAllText($script:jsonlPath) -split "`n" | Where-Object { $_ })
        @($line | ForEach-Object { ConvertFrom-Json -InputObject $_ } |
                Where-Object { $_.level -eq 'Warning' }).Count | Should -Be 0
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Write-HDTVariableLog -ErrorAction Stop

        $help.Name | Should -BeExactly 'Write-HDTVariableLog'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
