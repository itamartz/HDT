# Enforces the DESIGN 1 constraint over the real repository: the engine ships
# into WinPE, which has no pwsh, so every source file must be valid Windows
# PowerShell 5.1. One It per file, so a failure names the file directly.
#
# The file list is resolved at discovery time, not in BeforeAll: Pester 5 expands
# -ForEach while discovering, so a BeforeAll would produce zero test cases. The
# same setup is repeated in BeforeAll because discovery-phase variables do not
# survive into the run phase.
#
# Run this suite under BOTH engines. Under 5.1 the forbidden operators are parse
# errors; under 7 they are ordinary AST nodes. Only the pair of runs proves the
# constraint.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:HDTHelperManifest = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1'
Import-Module -Name $script:HDTHelperManifest -Force -ErrorAction Stop

$script:HDTSourceFile = @(Get-HDTSourceFile -RepositoryRoot $script:HDTRepositoryRoot)
$script:HDTFileCase = @($script:HDTSourceFile | ForEach-Object {
        @{
            Full     = $_
            Relative = $_.Substring($script:HDTRepositoryRoot.Length).TrimStart('\', '/').Replace('\', '/')
        }
    })

Describe 'Windows PowerShell 5.1 compatibility contract (DESIGN 1)' {

    BeforeAll {
        $script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
        $script:HDTSourceFile = @(Get-HDTSourceFile -RepositoryRoot $script:HDTRepositoryRoot)
    }

    It 'discovers at least one source file' {
        # Anti-vacuity guard: scanning nothing must not read as success.
        $script:HDTSourceFile.Count | Should -BeGreaterThan 0
    }

    It 'parses and accepts <Relative>' -ForEach $script:HDTFileCase {
        $violation = @(Get-HDTScriptCompatibilityViolation -Path $Full)

        $because = 'the engine runs inside WinPE, which only ships Windows PowerShell 5.1'
        if ($violation.Count -gt 0) {
            $because = ($violation | ForEach-Object {
                    '{0}:{1}:{2} [{3}] {4}' -f $Relative, $_.Line, $_.Column, $_.Feature, $_.Message
                }) -join "`n"
        }

        $violation.Count | Should -Be 0 -Because $because
    }

    It 'declares PowerShellVersion 5.1 in the engine manifest' {
        $manifestPath = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $manifest.PowerShellVersion | Should -BeExactly '5.1'
    }

    # The engine goes in the test name, which is expanded at discovery time, so the
    # NUnit result makes it obvious which edition produced the run. The contract is
    # only meaningful once both editions have produced one.
    It "records the engine this contract ran under (PowerShell $($PSVersionTable.PSVersion), $($PSVersionTable.PSEdition))" {
        $PSVersionTable.PSVersion | Should -Not -BeNullOrEmpty
    }
}
