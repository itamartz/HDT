# DESIGN 4.4.1: on phase end AND ON FAILURE the log directory is copied to
# <share>\Logs\<ComputerName>-<RunId>\.
#
# "Copy-back happens on failure too - a deployment that dies is exactly when the
# logs matter, and MDT's habit of stranding them on a wiped machine is a real
# operational problem." Which means the copy itself must never throw: a failed
# copy-back that masked the failure that triggered it would be worse than no
# copy-back at all.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # Held in a variable rather than written inline at every call site:
    # PSAvoidUsingComputerNameHardcoded is an Error, and it fires on a string
    # literal bound to -ComputerName even inside a test.
    $script:machine = 'PC-0001'
    $script:copyRoot = '\\share\Logs\PC-0001-8f3c1a90'

    # An IFileSystem whose CopyItem always fails - what a share that has gone away
    # looks like from a machine that failed early. Everything else delegates to
    # the fake it wraps, so the warning the failure provokes is still written.
    $script:newBroken = {
        param($Inner)

        $broken = [pscustomobject] @{ Inner = $Inner }
        $broken | Add-Member -MemberType ScriptMethod -Name TestPath -Value { param([string] $Path) return $this.Inner.TestPath($Path) }
        $broken | Add-Member -MemberType ScriptMethod -Name GetChildItem -Value { param([string] $Path) return , ([string[]] @($this.Inner.GetChildItem($Path))) }
        $broken | Add-Member -MemberType ScriptMethod -Name GetLength -Value { param([string] $Path) return $this.Inner.GetLength($Path) }
        $broken | Add-Member -MemberType ScriptMethod -Name CreateDirectory -Value { param([string] $Path) $this.Inner.CreateDirectory($Path) }
        $broken | Add-Member -MemberType ScriptMethod -Name AppendAllText -Value { param([string] $Path, [string] $Content) $this.Inner.AppendAllText($Path, $Content) }
        $broken | Add-Member -MemberType ScriptMethod -Name CopyItem -Value {
            param([string] $Source, [string] $Destination)
            throw (New-Object -TypeName System.IO.IOException -ArgumentList ("The network path was not found: '$Source' to '$Destination'."))
        }

        return $broken
    }
}

Describe 'Copy-HDTLog' {

    BeforeEach {
        # HDT.jsonl is seeded WITH its trailing newline, the way the log writer
        # leaves it, so a later append lands on its own line.
        $script:fs = New-HDTFakeFileSystem -File @{
            'X:\HDT\Logs\HDT.log'                = 'master'
            'X:\HDT\Logs\HDT.jsonl'              = "{`"seq`":1}`n"
            'X:\HDT\Logs\status.json'            = '{"status":"Failed"}'
            'X:\HDT\Logs\Steps\001-Validate.log' = 'validate'
            'X:\HDT\Logs\Gather\facts.json'      = '{"schemaVersion":1}'
        }
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc))
        $script:context = New-HDTLogContext -RunId '8f3c1a90' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $script:fs -Clock $script:clock
    }

    It 'copies into a directory named for the computer and the run id' {
        $result = Copy-HDTLog -Context $script:context -Destination '\\share\Logs' -ComputerName $script:machine

        $result.Path | Should -BeExactly $script:copyRoot
    }

    It 'returns the directory it copied into' {
        $result = Copy-HDTLog -Context $script:context -Destination '\\share\Logs' -ComputerName $script:machine

        $script:fs.TestPath($result.Path) | Should -BeTrue
    }

    It 'says it succeeded' {
        $result = Copy-HDTLog -Context $script:context -Destination '\\share\Logs' -ComputerName $script:machine

        $result.Succeeded | Should -BeTrue
        $result.Message | Should -BeNullOrEmpty
    }

    It 'copies every file under the log path' {
        Copy-HDTLog -Context $script:context -Destination '\\share\Logs' -ComputerName $script:machine | Out-Null

        $script:fs.ReadAllText((Join-Path -Path $script:copyRoot -ChildPath 'HDT.log')) | Should -BeExactly 'master'
        $script:fs.ReadAllText((Join-Path -Path $script:copyRoot -ChildPath 'HDT.jsonl')) | Should -BeExactly "{`"seq`":1}`n"
        $script:fs.ReadAllText((Join-Path -Path $script:copyRoot -ChildPath 'status.json')) | Should -BeExactly '{"status":"Failed"}'
    }

    It 'preserves the directory structure under the log path' {
        Copy-HDTLog -Context $script:context -Destination '\\share\Logs' -ComputerName $script:machine | Out-Null

        $script:fs.ReadAllText((Join-Path -Path $script:copyRoot -ChildPath 'Steps\001-Validate.log')) | Should -BeExactly 'validate'
        $script:fs.ReadAllText((Join-Path -Path $script:copyRoot -ChildPath 'Gather\facts.json')) | Should -BeExactly '{"schemaVersion":1}'
    }

    It 'copies through the injected filesystem' {
        Copy-HDTLog -Context $script:context -Destination '\\share\Logs' -ComputerName $script:machine | Out-Null

        @($script:fs.Operations | Where-Object { $_.Operation -eq 'CopyItem' }).Count | Should -Be 5
    }

    It 'copies nothing when the log path is empty' {
        $empty = New-HDTFakeFileSystem -Directory @('X:\HDT\Logs')
        $context = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $empty -Clock $script:clock

        Copy-HDTLog -Context $context -Destination '\\share\Logs' -ComputerName $script:machine | Out-Null

        @($empty.Operations | Where-Object { $_.Operation -eq 'CopyItem' }).Count | Should -Be 0
    }

    It 'does not throw when the destination is unreachable' {
        $context = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem (& $script:newBroken $script:fs) -Clock $script:clock

        $script:copyResult = $null
        { $script:copyResult = Copy-HDTLog -Context $context -Destination '\\gone\Logs' -ComputerName $script:machine } |
            Should -Not -Throw

        $script:copyResult | Should -Not -BeNullOrEmpty
    }

    # A FAILURE THAT ONLY THE LOG KNOWS ABOUT IS NOT REPORTED. This function is
    # documented never to throw, and for five milestones that meant it returned
    # NOTHING and wrote a Warning through Write-HDTLog - into the log it had
    # just failed to send. The caller could not tell success from failure, so
    # the tail said nothing and a technician standing at the bench had no way to
    # know the logs were not reaching the share.

    It 'answers a result the caller can test when the copy failed' {
        $context = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem (& $script:newBroken $script:fs) -Clock $script:clock

        $result = Copy-HDTLog -Context $context -Destination '\\gone\Logs' -ComputerName $script:machine

        $result.Succeeded | Should -BeFalse
    }

    It 'names the reason on the result rather than only in the log' {
        $context = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem (& $script:newBroken $script:fs) -Clock $script:clock

        $result = Copy-HDTLog -Context $context -Destination '\\gone\Logs' -ComputerName $script:machine

        $result.Message | Should -Not -BeNullOrEmpty
        $result.Message | Should -Match 'The network path was not found'
    }

    It 'still says where it was trying to put them' {
        # The destination is what a technician checks next, and a failed result
        # that dropped it would send them back to the log to find out.
        $context = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem (& $script:newBroken $script:fs) -Clock $script:clock

        $result = Copy-HDTLog -Context $context -Destination '\\gone\Logs' -ComputerName $script:machine

        $result.Path | Should -BeExactly '\\gone\Logs\PC-0001-r1'
    }

    It 'answers the same shape whether it worked or not' {
        # ONE SHAPE, BOTH OUTCOMES. A caller that has to test the type before it
        # can read the answer is a caller that will read the wrong one.
        $good = Copy-HDTLog -Context $script:context -Destination '\\share\Logs' -ComputerName $script:machine

        $context = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem (& $script:newBroken $script:fs) -Clock $script:clock
        $bad = Copy-HDTLog -Context $context -Destination '\\gone\Logs' -ComputerName $script:machine

        @($good.PSObject.Properties.Name) | Should -Be @($bad.PSObject.Properties.Name)
    }

    It 'warns into the log when the destination is unreachable' {
        $context = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem (& $script:newBroken $script:fs) -Clock $script:clock

        Copy-HDTLog -Context $context -Destination '\\gone\Logs' -ComputerName $script:machine | Out-Null

        $line = @($script:fs.ReadAllText('X:\HDT\Logs\HDT.jsonl') -split "`n" | Where-Object { $_ })
        # The seeded first line has no level property, and the suite runs under
        # Set-StrictMode -Version Latest, where reading an absent property throws.
        $warning = @($line | ForEach-Object { ConvertFrom-Json -InputObject $_ } |
                Where-Object { @($_.PSObject.Properties.Name) -contains 'level' -and $_.level -eq 'Warning' })

        $warning.Count | Should -BeGreaterThan 0
        $warning[0].message.Contains('\\gone\Logs') | Should -BeTrue
    }

    It 'never touches the real filesystem' {
        Copy-HDTLog -Context $script:context -Destination 'C:\HDTLab\does-not-exist\Logs' -ComputerName $script:machine | Out-Null

        Test-Path -LiteralPath 'C:\HDTLab\does-not-exist' | Should -BeFalse
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Copy-HDTLog -ErrorAction Stop

        $help.Name | Should -BeExactly 'Copy-HDTLog'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }

    # THE NESTING, MEASURED ON THE SHARE AND ON THE MACHINE. Three levels of it:
    #
    #   PC-5784-6600-26-run-20260829-052141\
    #     PC-5784-6600-26-run-20260829-052141\
    #       PC-5784-6600-26-run-20260829-052141\
    #
    # each carrying its own Steps\ and Gather\. Invoke-HDTTaskSequence's restart
    # path copies the log onto the volume that survives the reboot - and by then
    # Set-HDTLogPath has already moved the CONTEXT onto that volume, so the
    # destination this command composes, <volume>\HDT\Logs\<Computer>-<RunId>,
    # sits INSIDE its own source, <volume>\HDT\Logs. The walk then found the
    # folder it had just created, descended into it and copied it into itself -
    # once per copy, which is why the count of levels matched the count of legs.
    #
    # Copy-HDTContentTree has refused a destination inside its source since it
    # was written. This is the same rule, expressed as a SKIP rather than a
    # refusal, because this command is documented never to throw and the rest of
    # the tree still has to arrive.
    Context 'a destination that sits inside the log directory' {

        BeforeEach {
            $script:volumeFs = New-HDTFakeFileSystem -File @{
                'W:\HDT\Logs\HDT.log'                = 'master'
                'W:\HDT\Logs\HDT.jsonl'              = "{`"seq`":1}`n"
                'W:\HDT\Logs\status.json'            = '{"status":"Running"}'
                'W:\HDT\Logs\Steps\001-Validate.log' = 'validate'
                'W:\HDT\Logs\Gather\facts.json'      = '{"schemaVersion":1}'
            }
            $script:volumeContext = New-HDTLogContext -RunId 'run-20260829-052141' -Phase WinPE `
                -LogPath 'W:\HDT\Logs' -FileSystem $script:volumeFs -Clock $script:clock
            $script:volumeRoot = 'W:\HDT\Logs\PC-0001-run-20260829-052141'
        }

        It 'does not copy the run folder into itself' {
            Copy-HDTLog -Context $script:volumeContext -Destination 'W:\HDT\Logs' -ComputerName $script:machine | Out-Null

            $script:volumeFs.TestPath(($script:volumeRoot + '\PC-0001-run-20260829-052141')) | Should -BeFalse
        }

        It 'still brings the rest of the tree across' -ForEach @(
            'HDT.log'
            'HDT.jsonl'
            'status.json'
            'Steps\001-Validate.log'
            'Gather\facts.json'
        ) {
            Copy-HDTLog -Context $script:volumeContext -Destination 'W:\HDT\Logs' -ComputerName $script:machine | Out-Null

            $script:volumeFs.TestPath(('W:\HDT\Logs\PC-0001-run-20260829-052141\{0}' -f $PSItem)) | Should -BeTrue
        }

        It 'says it succeeded, because skipping its own destination is not a failure' {
            $result = Copy-HDTLog -Context $script:volumeContext -Destination 'W:\HDT\Logs' -ComputerName $script:machine

            $result.Succeeded | Should -BeTrue
        }
    }
}
