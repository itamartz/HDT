# DESIGN 4.4.1: _HDTLogPath is the single canonical log directory, and it follows
# the deployment rather than staying put.
#
# Pure string logic - it reads no disk and asks no service - so -SystemDrive
# exists to keep the assertion off whichever drive the suite happens to run from.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTLogPath' {

    It 'returns X:\HDT\Logs in WinPE before a disk exists' {
        Get-HDTLogPath -Phase WinPE | Should -BeExactly 'X:\HDT\Logs'
    }

    It 'returns the target volume path in WinPE once a volume is given' {
        Get-HDTLogPath -Phase WinPE -TargetVolume 'W:' | Should -BeExactly 'W:\HDT\Logs'
    }

    It 'accepts a target volume with a trailing separator' {
        Get-HDTLogPath -Phase WinPE -TargetVolume 'W:\' | Should -BeExactly 'W:\HDT\Logs'
    }

    It 'accepts a target volume that is a directory' {
        Get-HDTLogPath -Phase WinPE -TargetVolume 'W:\Windows' | Should -BeExactly 'W:\Windows\HDT\Logs'
    }

    It 'returns C:\HDT\Logs in the full OS' {
        Get-HDTLogPath -Phase FullOS | Should -BeExactly 'C:\HDT\Logs'
    }

    It 'honours -SystemDrive' {
        Get-HDTLogPath -Phase FullOS -SystemDrive 'D:' | Should -BeExactly 'D:\HDT\Logs'
    }

    It 'ignores a target volume in the full OS' {
        # In the full OS the target volume IS the system volume; carrying the WinPE
        # answer forward would put the logs on a drive letter that no longer means
        # what it meant.
        Get-HDTLogPath -Phase FullOS -TargetVolume 'W:' | Should -BeExactly 'C:\HDT\Logs'
    }

    It 'ignores an empty target volume in WinPE' {
        Get-HDTLogPath -Phase WinPE -TargetVolume '' | Should -BeExactly 'X:\HDT\Logs'
    }

    It 'rejects a phase outside the set' {
        $record = $null
        try { Get-HDTLogPath -Phase 'OS' } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'ParameterArgumentValidationError*'
    }

    It 'reads nothing from the real filesystem' {
        # No IFileSystem parameter at all: the answer is a string, computed.
        (Get-Command -Name Get-HDTLogPath).Parameters.ContainsKey('FileSystem') | Should -BeFalse
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name Get-HDTLogPath -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTLogPath'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
