# Enforces the DESIGN 1 constraint over the real repository: the engine ships
# into WinPE, which has no pwsh, so every source file must be valid Windows
# PowerShell 5.1. One It per file, so a failure names the file directly.
#
# The file list is resolved at discovery time, not in BeforeAll: Pester 5 expands
# -ForEach while discovering, so a BeforeAll would produce zero test cases. The
# same setup is repeated in BeforeAll because discovery-phase variables do not
# survive into the run phase.
#
# WHAT ONE RUN UNDER 5.1 GUARANTEES, EXACTLY.
#
# This used to say the constraint was proved only by running under both engines.
# That was wrong, and the wrong way round. Get-HDTScriptCompatibilityViolation
# was written to give the SAME verdict on either engine, and it reaches every
# forbidden construct under 5.1:
#
#   ?? ??= ?. ?[] and the ternary are PARSE ERRORS in 5.1. The scanner reports a
#   parse error as a violation and stops analysing that file, so a 7-ism of this
#   kind cannot be read here without failing - which is the strongest signal
#   available, not a missing one. Under 7 the same text parses cleanly and has
#   to be caught by token kind instead.
#
#   ForEach-Object -Parallel, Get-Error, $PSStyle, ConvertFrom-Json -AsHashtable
#   and a `clean` block parse on BOTH engines and are caught by AST inspection
#   either way. 5.1 sees `clean { }` as a command taking a script block, which
#   the scanner handles by name.
#
# So 5.1 alone proves the constraint, and it is the edition WinPE ships. A run
# under 7 would be the WEAKER evidence of the two: it is the engine on which a
# forbidden operator is an ordinary AST node.
#
# WHAT IT DOES NOT PROVE, and no static scan can: that a file which parses under
# 5.1 also RUNS there. A cmdlet parameter added in 7, or a .NET type absent from
# the Desktop framework, is legal syntax and reaches the scanner as nothing at
# all. That is what the rest of the suite executing under 5.1 covers.

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

    # The engine goes in the test name, which is expanded at discovery time, so
    # the NUnit result says which edition produced the run rather than leaving it
    # to be inferred from the runner's name. On a green result that is the line
    # proving the gate ran on 5.1 and not on something else.
    It "records the engine this contract ran under (PowerShell $($PSVersionTable.PSVersion), $($PSVersionTable.PSEdition))" {
        $PSVersionTable.PSVersion | Should -Not -BeNullOrEmpty
    }
}
