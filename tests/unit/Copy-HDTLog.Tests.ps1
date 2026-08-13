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

    It 'copies into <Destination>\<ComputerName>-<RunId>' {
        $result = Copy-HDTLog -Context $script:context -Destination '\\share\Logs' -ComputerName 'PC-0001'

        $result | Should -BeExactly '\\share\Logs\PC-0001-8f3c1a90'
    }

    It 'returns the directory it copied into' {
        $result = Copy-HDTLog -Context $script:context -Destination '\\share\Logs' -ComputerName 'PC-0001'

        $script:fs.TestPath($result) | Should -BeTrue
    }

    It 'copies every file under the log path' {
        Copy-HDTLog -Context $script:context -Destination '\\share\Logs' -ComputerName 'PC-0001' | Out-Null

        $root = '\\share\Logs\PC-0001-8f3c1a90'
        $script:fs.ReadAllText((Join-Path -Path $root -ChildPath 'HDT.log')) | Should -BeExactly 'master'
        $script:fs.ReadAllText((Join-Path -Path $root -ChildPath 'HDT.jsonl')) | Should -BeExactly "{`"seq`":1}`n"
        $script:fs.ReadAllText((Join-Path -Path $root -ChildPath 'status.json')) | Should -BeExactly '{"status":"Failed"}'
    }

    It 'preserves the directory structure under the log path' {
        Copy-HDTLog -Context $script:context -Destination '\\share\Logs' -ComputerName 'PC-0001' | Out-Null

        $root = '\\share\Logs\PC-0001-8f3c1a90'
        $script:fs.ReadAllText((Join-Path -Path $root -ChildPath 'Steps\001-Validate.log')) | Should -BeExactly 'validate'
        $script:fs.ReadAllText((Join-Path -Path $root -ChildPath 'Gather\facts.json')) | Should -BeExactly '{"schemaVersion":1}'
    }

    It 'copies through the injected filesystem' {
        Copy-HDTLog -Context $script:context -Destination '\\share\Logs' -ComputerName 'PC-0001' | Out-Null

        @($script:fs.Operations | Where-Object { $_.Operation -eq 'CopyItem' }).Count | Should -Be 5
    }

    It 'copies nothing when the log path is empty' {
        $empty = New-HDTFakeFileSystem -Directory @('X:\HDT\Logs')
        $context = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $empty -Clock $script:clock

        Copy-HDTLog -Context $context -Destination '\\share\Logs' -ComputerName 'PC-0001' | Out-Null

        @($empty.Operations | Where-Object { $_.Operation -eq 'CopyItem' }).Count | Should -Be 0
    }

    It 'does not throw when the destination is unreachable' {
        # A share that is gone is the normal case for a machine that failed early.
        # The copy warns and returns nothing; it never masks the original failure.
        $broken = [pscustomobject] @{ Inner = $script:fs }
        $broken | Add-Member -MemberType ScriptMethod -Name TestPath -Value { param([string] $Path) return $this.Inner.TestPath($Path) }
        $broken | Add-Member -MemberType ScriptMethod -Name GetChildItem -Value { param([string] $Path) return , ([string[]] @($this.Inner.GetChildItem($Path))) }
        $broken | Add-Member -MemberType ScriptMethod -Name GetLength -Value { param([string] $Path) return $this.Inner.GetLength($Path) }
        $broken | Add-Member -MemberType ScriptMethod -Name CreateDirectory -Value { param([string] $Path) $this.Inner.CreateDirectory($Path) }
        $broken | Add-Member -MemberType ScriptMethod -Name AppendAllText -Value { param([string] $Path, [string] $Content) $this.Inner.AppendAllText($Path, $Content) }
        $broken | Add-Member -MemberType ScriptMethod -Name CopyItem -Value {
            param([string] $Source, [string] $Destination)
            throw (New-Object -TypeName System.IO.IOException -ArgumentList 'The network path was not found.')
        }

        $context = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $broken -Clock $script:clock

        $result = $null
        { $result = Copy-HDTLog -Context $context -Destination '\\gone\Logs' -ComputerName 'PC-0001' } |
            Should -Not -Throw

        $result | Should -BeNullOrEmpty
    }

    It 'warns into the log when the destination is unreachable' {
        $broken = [pscustomobject] @{ Inner = $script:fs }
        $broken | Add-Member -MemberType ScriptMethod -Name TestPath -Value { param([string] $Path) return $this.Inner.TestPath($Path) }
        $broken | Add-Member -MemberType ScriptMethod -Name GetChildItem -Value { param([string] $Path) return , ([string[]] @($this.Inner.GetChildItem($Path))) }
        $broken | Add-Member -MemberType ScriptMethod -Name GetLength -Value { param([string] $Path) return $this.Inner.GetLength($Path) }
        $broken | Add-Member -MemberType ScriptMethod -Name CreateDirectory -Value { param([string] $Path) $this.Inner.CreateDirectory($Path) }
        $broken | Add-Member -MemberType ScriptMethod -Name AppendAllText -Value { param([string] $Path, [string] $Content) $this.Inner.AppendAllText($Path, $Content) }
        $broken | Add-Member -MemberType ScriptMethod -Name CopyItem -Value {
            param([string] $Source, [string] $Destination)
            throw (New-Object -TypeName System.IO.IOException -ArgumentList 'The network path was not found.')
        }

        $context = New-HDTLogContext -RunId 'r1' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $broken -Clock $script:clock

        Copy-HDTLog -Context $context -Destination '\\gone\Logs' -ComputerName 'PC-0001' | Out-Null

        $line = @($script:fs.ReadAllText('X:\HDT\Logs\HDT.jsonl') -split "`n" | Where-Object { $_ })
        $warning = @($line | ForEach-Object { ConvertFrom-Json -InputObject $_ } |
                Where-Object { $_.level -eq 'Warning' })

        $warning.Count | Should -BeGreaterThan 0
        $warning[0].message | Should -BeLike '*\\gone\Logs*'
    }

    It 'never touches the real filesystem' {
        Copy-HDTLog -Context $script:context -Destination 'C:\HDTLab\does-not-exist\Logs' -ComputerName 'PC-0001' | Out-Null

        Test-Path -LiteralPath 'C:\HDTLab\does-not-exist' | Should -BeFalse
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Copy-HDTLog -ErrorAction Stop

        $help.Name | Should -BeExactly 'Copy-HDTLog'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
