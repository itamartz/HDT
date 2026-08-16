# DESIGN 4.4.6: a small status.json heartbeat written each step, which the console
# tails. No web service, no SQL, no MDT Monitoring dependency.
#
# It OVERWRITES rather than appends - a heartbeat is the current state, not a
# history - so it is the one log-adjacent writer that uses WriteAllText.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:statusPath = 'X:\HDT\Logs\status.json'
}

Describe 'Write-HDTStatus' {

    BeforeEach {
        $script:journal = [System.Collections.ArrayList]::new()
        $script:fs = New-HDTFakeFileSystem -Journal $script:journal
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc)) -Journal $script:journal
        $script:context = New-HDTLogContext -RunId '8f3c1a90' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fs -Clock $script:clock
        $script:context.SetStep(3, 'Apply OS', 'ApplyImage', $null)
    }

    It 'writes status.json through the injected filesystem' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath

        $script:fs.GetOperationName() | Should -Be @('WriteAllText')
        $script:fs.Operations[0].Arguments[0] | Should -BeExactly $script:statusPath
    }

    It 'overwrites rather than appends' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath
        Write-HDTStatus -Context $script:context -Path $script:statusPath

        $script:fs.GetOperationName() | Should -Be @('WriteAllText', 'WriteAllText')
        @($script:fs.ReadAllText($script:statusPath) | ConvertFrom-Json).Count | Should -Be 1
    }

    It 'writes how many steps there are, not only which one this is' {
        # "step 7" is a number nobody can act on. "step 7 of 12" is a progress
        # bar, and it is what the console's monitoring row shows - so the count
        # has to travel in the heartbeat, because the console cannot work it out
        # from a share it is only reading.
        $script:context.StepCount = 12

        Write-HDTStatus -Context $script:context -Path $script:statusPath

        (ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:statusPath))).stepCount | Should -Be 12
    }

    It 'writes a count of zero rather than omitting it when the run has not started stepping' {
        # A key that is sometimes absent is a key every reader has to test for.
        Write-HDTStatus -Context $script:context -Path $script:statusPath

        $status = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:statusPath))
        $status.PSObject.Properties.Name | Should -Contain 'stepCount'
        $status.stepCount | Should -Be 0
    }

    It 'writes valid JSON' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath

        { ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:statusPath)) } | Should -Not -Throw
    }

    It 'writes schemaVersion 1' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath

        (ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:statusPath))).schemaVersion | Should -Be 1
    }

    It 'writes the run id, phase, step index and step name' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath

        $status = ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:statusPath))
        $status.runId | Should -BeExactly '8f3c1a90'
        $status.phase | Should -BeExactly 'WinPE'
        $status.stepIndex | Should -Be 3
        $status.stepName | Should -BeExactly 'Apply OS'
        $status.stepType | Should -BeExactly 'ApplyImage'
    }

    It 'writes the status it was given' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath -Status 'Failed'

        (ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:statusPath))).status |
            Should -BeExactly 'Failed'
    }

    It 'defaults the status to Running' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath

        (ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:statusPath))).status |
            Should -BeExactly 'Running'
    }

    It 'writes an ISO 8601 updated timestamp as a string' {
        # Asserted on the file text: ConvertFrom-Json turns the string back into a
        # [datetime] and would hide a \/Date(...)\/ written under 5.1.
        Write-HDTStatus -Context $script:context -Path $script:statusPath

        $script:fs.ReadAllText($script:statusPath) | Should -Match '"updated":\s*"2026-08-13T00:11:02\.4810000Z"'
        $script:fs.ReadAllText($script:statusPath) | Should -Not -BeLike '*/Date(*'
    }

    It 'stamps the time from the injected clock' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath

        $script:clock.GetOperationName() | Should -Be @('GetUtcNow')
    }

    It 'writes nothing but the heartbeat' {
        Write-HDTStatus -Context $script:context -Path $script:statusPath

        @($script:journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
            Should -Be @('Clock.GetUtcNow', 'FileSystem.WriteAllText')
    }

    It 'never touches the real filesystem' {
        Write-HDTStatus -Context $script:context -Path 'C:\HDTLab\does-not-exist\status.json'

        Test-Path -LiteralPath 'C:\HDTLab\does-not-exist' | Should -BeFalse
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Write-HDTStatus -ErrorAction Stop

        $help.Name | Should -BeExactly 'Write-HDTStatus'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
