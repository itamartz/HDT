# DESIGN 4.4's Gather\facts.json - "resolved facts (3.2)" - written beside
# provenance.json in every deployment's log directory.
#
# The sibling of Export-HDTVariableProvenance, and it carries the same rule: the
# timestamp is formatted to a string BEFORE serialisation, because ConvertTo-Json
# renders a raw [datetime] as "\/Date(1786579862481)\/" under Windows PowerShell
# 5.1 - the engine that runs in WinPE, where this file is written.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:factsPath = 'X:\HDT\Logs\Gather\facts.json'
    $script:stamp = [datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc)
}

Describe 'Export-HDTMachineFact' {

    BeforeEach {
        $script:fs = New-HDTFakeFileSystem
        $script:fact = [ordered] @{
            HDTSerialNumber   = 'FIXTURE-SERIAL-0001'
            HDTModel          = 'Latitude 7450'
            HDTMake           = 'Dell Inc.'
            HDTIsVirtual      = $false
            HDTMemoryMB       = 32768
            HDTMacAddress     = @('00:15:5D:01:02:03', '00:15:5D:01:02:04')
            HDTArchitecture   = 'AMD64'
            HDTIsUefi         = $true
        }
    }

    It 'writes facts.json through the injected filesystem' {
        Export-HDTMachineFact -Fact $script:fact -Path $script:factsPath -FileSystem $script:fs -Timestamp $script:stamp

        $script:fs.GetOperationName() | Should -Be @('WriteAllText')
        $script:fs.Operations[0].Arguments[0] | Should -BeExactly $script:factsPath
    }

    It 'writes valid JSON' {
        Export-HDTMachineFact -Fact $script:fact -Path $script:factsPath -FileSystem $script:fs -Timestamp $script:stamp

        { ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:factsPath)) } | Should -Not -Throw
    }

    It 'writes schemaVersion 1' {
        Export-HDTMachineFact -Fact $script:fact -Path $script:factsPath -FileSystem $script:fs -Timestamp $script:stamp

        (ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:factsPath))).schemaVersion | Should -Be 1
    }

    It 'writes every gathered fact' {
        Export-HDTMachineFact -Fact $script:fact -Path $script:factsPath -FileSystem $script:fs -Timestamp $script:stamp

        $document = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:factsPath))

        @($document.fact.PSObject.Properties.Name) | Should -Be @($script:fact.Keys)
        $document.fact.HDTSerialNumber | Should -BeExactly 'FIXTURE-SERIAL-0001'
        $document.fact.HDTModel | Should -BeExactly 'Latitude 7450'
        $document.fact.HDTMemoryMB | Should -Be 32768
        $document.fact.HDTIsVirtual | Should -BeFalse
        $document.fact.HDTIsUefi | Should -BeTrue
    }

    It 'writes an array-valued fact as an array' {
        # A multi-NIC machine has more than one MAC. Collapsing that to a scalar
        # would make a driver rule that matches on it silently wrong.
        Export-HDTMachineFact -Fact $script:fact -Path $script:factsPath -FileSystem $script:fs -Timestamp $script:stamp

        $document = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:factsPath))

        $script:fs.ReadAllText($script:factsPath) | Should -Match '"HDTMacAddress":\s*\['
        @($document.fact.HDTMacAddress).Count | Should -Be 2
        @($document.fact.HDTMacAddress) | Should -Be @('00:15:5D:01:02:03', '00:15:5D:01:02:04')
    }

    It 'writes the timestamp it was given as a string' {
        Export-HDTMachineFact -Fact $script:fact -Path $script:factsPath -FileSystem $script:fs -Timestamp $script:stamp

        $script:fs.ReadAllText($script:factsPath) | Should -Match '"generated":\s*"2026-08-13T00:11:02\.4810000Z"'
    }

    It 'writes no \/Date( timestamp' {
        Export-HDTMachineFact -Fact $script:fact -Path $script:factsPath -FileSystem $script:fs -Timestamp $script:stamp

        $script:fs.ReadAllText($script:factsPath) | Should -Not -BeLike '*/Date(*'
    }

    It 'converts a local timestamp to UTC' {
        $local = [datetime]'2026-08-13T00:11:02.4810000Z'

        Export-HDTMachineFact -Fact $script:fact -Path $script:factsPath -FileSystem $script:fs -Timestamp $local

        $script:fs.ReadAllText($script:factsPath) | Should -Match '"generated":\s*"2026-08-13T00:11:02\.4810000Z"'
    }

    It 'writes an empty fact set as an empty object' {
        Export-HDTMachineFact -Fact ([ordered] @{}) -Path $script:factsPath -FileSystem $script:fs -Timestamp $script:stamp

        $document = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:factsPath))
        @($document.fact.PSObject.Properties).Count | Should -Be 0
    }

    It 'supports ShouldProcess' {
        Export-HDTMachineFact -Fact $script:fact -Path $script:factsPath -FileSystem $script:fs `
            -Timestamp $script:stamp -WhatIf

        @($script:fs.Operations).Count | Should -Be 0
    }

    It 'never touches the real filesystem' {
        Export-HDTMachineFact -Fact $script:fact -Path 'C:\HDTLab\does-not-exist\Gather\facts.json' `
            -FileSystem $script:fs -Timestamp $script:stamp

        Test-Path -LiteralPath 'C:\HDTLab\does-not-exist' | Should -BeFalse
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Export-HDTMachineFact -ErrorAction Stop

        $help.Name | Should -BeExactly 'Export-HDTMachineFact'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
