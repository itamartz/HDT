#requires -Version 5.1

# Test-HDTFileSystemFile - is this path a file or a directory, asked of an
# IFileSystem that has no method for it.
#
# IFileSystem HAS NINE METHODS AND NONE OF THEM IS TestDirectory; TestPath
# answers for both. Both the real adapter and the fake throw
# System.IO.FileNotFoundException from GetLength for a path that is not a file,
# and that error parity is a contract assertion (tests/helpers/README.md section
# 5) - so the classification behaves identically against either implementation.
#
# IT WAS INLINE IN Copy-HDTContentTree AND IS NOW SHARED, because
# Update-HDTMediaContent needs the same answer for the children of Control\ and
# two copies of a try/catch that reads as a bug would not survive the first
# person to "tidy" one of them.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:fileSystem = New-HDTFakeFileSystem -File @{
        'X:\Share\rules.yaml'                    = 'schemaVersion: 1'
        'X:\Share\Control\selection-profiles.yaml' = 'schemaVersion: 1'
        'X:\Share\Control\machines\PC-1234.yaml'  = 'schemaVersion: 1'
        'X:\Share\Applications\TightVNC\app.yaml' = 'schemaVersion: 1'
    }

    function Test-HDTMediaTestFile {
        [CmdletBinding()]
        [OutputType([bool])]
        param(
            [Parameter(Mandatory = $true)]
            [string] $Path
        )

        return [bool] (InModuleScope Hephaestus -Parameters @{ Target = $Path; Fs = $script:fileSystem } {
                param($Target, $Fs)

                Test-HDTFileSystemFile -Path $Target -FileSystem $Fs
            })
    }
}

Describe 'Test-HDTFileSystemFile' {

    It 'says true for a file' {
        Test-HDTMediaTestFile -Path 'X:\Share\rules.yaml' | Should -BeTrue
    }

    It 'says false for a directory' {
        Test-HDTMediaTestFile -Path 'X:\Share\Control' | Should -BeFalse
    }

    It 'says false for a directory that holds only other directories' {
        Test-HDTMediaTestFile -Path 'X:\Share\Applications' | Should -BeFalse
    }

    It 'says true for a file nested several folders down' {
        Test-HDTMediaTestFile -Path 'X:\Share\Control\machines\PC-1234.yaml' | Should -BeTrue
    }

    It 'answers for a path on a drive this session has not mounted' {
        # The whole point of asking an IFileSystem rather than [System.IO.File].
        (Test-Path -LiteralPath 'X:\') | Should -BeFalse

        { Test-HDTMediaTestFile -Path 'X:\Share\rules.yaml' } | Should -Not -Throw
    }
}
