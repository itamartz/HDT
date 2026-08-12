# Enforces CLAUDE.md hard rule 4 and PROJECT.md "MDT dependency: NONE" over the
# real repository. Phase 02 starts mining C:\HDTLab\reference\PSD - which is an
# MDT extension - for mechanism, so this guard exists before the temptation does.
#
# The file list is resolved at discovery time, not in BeforeAll: Pester 5 expands
# -ForEach while discovering, so a BeforeAll would produce zero test cases. The
# same setup is repeated in BeforeAll because discovery-phase variables do not
# survive into the run phase - the -ForEach data does, the script variables do not.
#
# Every forbidden term in this file is assembled from fragments, because this file
# is itself one of the files being scanned.

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

Describe 'No MDT dependency contract (CLAUDE.md rule 4)' {

    BeforeAll {
        $script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop
        $script:HDTSourceFile = @(Get-HDTSourceFile -RepositoryRoot $script:HDTRepositoryRoot)
    }

    It 'discovers at least one source file' {
        # Anti-vacuity guard: a contract that silently scans nothing is worse than
        # no contract at all.
        $script:HDTSourceFile.Count | Should -BeGreaterThan 0
    }

    It 'has no MDT dependency in <Relative>' -ForEach $script:HDTFileCase {
        $violation = @(Get-HDTMdtDependency -Path $Full)

        $because = 'ADK and WDS are permitted; MDT components are not'
        if ($violation.Count -gt 0) {
            $because = ($violation | ForEach-Object {
                    '{0}:{1}:{2} {3}' -f $Relative, $_.Line, $_.Column, $_.Message
                }) -join "`n"
        }

        $violation.Count | Should -Be 0 -Because $because
    }

    It 'declares no MDT module in the engine manifest' {
        $manifestPath = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath

        $declared = New-Object -TypeName System.Collections.ArrayList
        foreach ($key in @('RequiredModules', 'RequiredAssemblies', 'NestedModules')) {
            if ($manifest.ContainsKey($key)) {
                foreach ($entry in @($manifest[$key])) {
                    [void] $declared.Add(($entry | Out-String).Trim())
                }
            }
        }

        # Round-tripped through the scanner rather than re-implementing the term
        # list here, so the manifest is held to exactly the same rule as the code.
        $probe = Join-Path -Path $TestDrive -ChildPath 'ManifestDependency.ps1'
        Set-Content -Path $probe -Value (@($declared) -join [System.Environment]::NewLine) -Encoding ASCII

        @(Get-HDTMdtDependency -Path $probe).Count | Should -Be 0
    }

    It 'records derived PSD code in NOTICE.md' {
        # Expected to be a no-op in phase 01: no PSD-derived code exists yet. This
        # is not dead code - it is the guard that stops phase 02's first mined
        # function from landing unattributed. PSD is MIT licensed, so reuse is
        # permitted *with* attribution (PROJECT.md).
        $marker = 'friendsOf' + 'MDT'

        $derived = @($script:HDTSourceFile | Where-Object {
                (Get-Content -Path $_ -Raw -ErrorAction Stop) -match $marker
            })

        if ($derived.Count -eq 0) {
            $derived.Count | Should -Be 0
            return
        }

        $noticePath = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'NOTICE.md'
        Test-Path -Path $noticePath -PathType Leaf |
            Should -BeTrue -Because "$($derived.Count) source file(s) cite PSD attribution"

        $notice = Get-Content -Path $noticePath -Raw
        foreach ($item in $derived) {
            $relative = $item.Substring($script:HDTRepositoryRoot.Length).TrimStart('\', '/').Replace('\', '/')
            $notice | Should -BeLike ("*{0}*" -f $relative) -Because 'derived code must be attributed in NOTICE.md'
        }
    }
}
