# DESIGN 4.3: the state document is written to X:\HDT\state.json in WinPE and
# "mirrored to the target disk's \HDT\ as soon as a formatted volume exists. The
# mirror is what makes the WinPE to OS transition survivable."
#
# Everything goes through the injected IFileSystem, so the whole checkpoint path
# is provable with nothing on disk.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
}

Describe 'Save-HDTRunState' {

    BeforeEach {
        $script:journal = [System.Collections.ArrayList]::new()
        $script:fs = New-HDTFakeFileSystem -Journal $script:journal
        $script:startClock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 0, 0, [System.DateTimeKind]::Utc))
        $script:saveClock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc)) -Journal $script:journal

        $script:state = New-HDTRunState -SequenceId 'STD-CLIENT' -RunId '8f3c1a90' -Phase WinPE `
            -Clock $script:startClock `
            -Variable ([ordered] @{ HDTComputerName = 'PC-0001'; HDTApplications = @('7zip', 'Chrome') }) `
            -Step @(
            @{ Index = 1; Name = 'Validate'; Type = 'Validate'; Group = @('Preinstall'); Resumable = $false }
            @{ Index = 2; Name = 'Restart'; Type = 'Restart'; Group = @('Preinstall'); Resumable = $true }
            @{ Index = 3; Name = 'Apply OS'; Type = 'ApplyImage'; Group = @('Install'); Resumable = $false }
        )
    }

    It 'writes through the injected filesystem' {
        Save-HDTRunState -State $script:state -Path 'X:\HDT\state.json' -FileSystem $script:fs -Clock $script:saveClock

        $script:fs.GetOperationName() | Should -Be @('WriteAllText')
        $script:fs.Operations[0].Arguments[0] | Should -BeExactly 'X:\HDT\state.json'
    }

    It 'writes valid JSON' {
        Save-HDTRunState -State $script:state -Path 'X:\HDT\state.json' -FileSystem $script:fs -Clock $script:saveClock

        { ConvertFrom-Json -InputObject ($script:fs.ReadAllText('X:\HDT\state.json')) } | Should -Not -Throw
    }

    It 'writes to the mirror path as well when one is given' {
        Save-HDTRunState -State $script:state -Path 'X:\HDT\state.json' -FileSystem $script:fs `
            -Clock $script:saveClock -MirrorPath 'W:\HDT\state.json'

        $script:fs.GetOperationName() | Should -Be @('WriteAllText', 'WriteAllText')
        $script:fs.ReadAllText('W:\HDT\state.json') | Should -BeExactly ($script:fs.ReadAllText('X:\HDT\state.json'))
    }

    It 'writes only once when no mirror is given' {
        Save-HDTRunState -State $script:state -Path 'X:\HDT\state.json' -FileSystem $script:fs -Clock $script:saveClock

        @($script:fs.Operations | Where-Object { $_.Operation -eq 'WriteAllText' }).Count | Should -Be 1
    }

    It 'stamps updatedUtc from the clock on every save' {
        Save-HDTRunState -State $script:state -Path 'X:\HDT\state.json' -FileSystem $script:fs -Clock $script:saveClock

        (ConvertFrom-Json -InputObject ($script:fs.ReadAllText('X:\HDT\state.json'))).updatedUtc |
            Should -BeExactly '2026-08-13T00:11:02.4810000Z'
        $script:state.updatedUtc | Should -BeExactly '2026-08-13T00:11:02.4810000Z'
    }

    It 'leaves startedUtc alone' {
        Save-HDTRunState -State $script:state -Path 'X:\HDT\state.json' -FileSystem $script:fs -Clock $script:saveClock

        (ConvertFrom-Json -InputObject ($script:fs.ReadAllText('X:\HDT\state.json'))).startedUtc |
            Should -BeExactly '2026-08-13T00:00:00.0000000Z'
    }

    It 'serialises nested step records' {
        $null = Update-HDTRunStateStep -State $script:state -Index 3 -Status Failed -Message 'DISM returned 0x80070002'

        Save-HDTRunState -State $script:state -Path 'X:\HDT\state.json' -FileSystem $script:fs -Clock $script:saveClock

        $document = ConvertFrom-Json -InputObject ($script:fs.ReadAllText('X:\HDT\state.json'))
        $document.step[2].message | Should -BeExactly 'DISM returned 0x80070002'
        @($document.step[2].group) | Should -Be @('Install')
    }

    It 'serialises the variable dictionary as an object' {
        Save-HDTRunState -State $script:state -Path 'X:\HDT\state.json' -FileSystem $script:fs -Clock $script:saveClock

        $document = ConvertFrom-Json -InputObject ($script:fs.ReadAllText('X:\HDT\state.json'))
        $document.variable.HDTComputerName | Should -BeExactly 'PC-0001'
        @($document.variable.HDTApplications) | Should -Be @('7zip', 'Chrome')
    }

    It 'writes no \/Date( timestamp' {
        Save-HDTRunState -State $script:state -Path 'X:\HDT\state.json' -FileSystem $script:fs -Clock $script:saveClock

        $script:fs.ReadAllText('X:\HDT\state.json') | Should -Not -BeLike '*/Date(*'
    }

    It 'writes only through the injected services' {
        Save-HDTRunState -State $script:state -Path 'X:\HDT\state.json' -FileSystem $script:fs -Clock $script:saveClock

        @($script:journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
            Should -Be @('Clock.GetUtcNow', 'FileSystem.WriteAllText')
    }

    It 'supports ShouldProcess' {
        Save-HDTRunState -State $script:state -Path 'X:\HDT\state.json' -FileSystem $script:fs `
            -Clock $script:saveClock -WhatIf

        @($script:fs.Operations).Count | Should -Be 0
    }

    It 'never touches the real filesystem' {
        Save-HDTRunState -State $script:state -Path 'C:\HDTLab\does-not-exist\state.json' `
            -FileSystem $script:fs -Clock $script:saveClock

        Test-Path -LiteralPath 'C:\HDTLab\does-not-exist' | Should -BeFalse
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Save-HDTRunState -ErrorAction Stop

        $help.Name | Should -BeExactly 'Save-HDTRunState'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
