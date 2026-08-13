#requires -Version 5.1

# Nothing in this repository may delete the repository, the lab root, or the
# staged media. The rule exists because the cost is asymmetric: a wrong
# Remove-Item costs hours of restaging at best and the project at worst, while
# the guard costs one grep.
#
# Scope note: this scans for the *dangerous shapes* - a recursive delete whose
# target is a bare drive-root-ish literal, or one of the named protected paths.
# It deliberately does NOT ban Remove-Item, because clearing out/ and cleaning up
# a scratch VHDX a test itself created are both legitimate and necessary.

BeforeAll {
    $script:contractRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # THE FILE LIST IS BUILT HERE, IN THE RUN PHASE, AND NOT IN BeforeDiscovery.
    # SPIKES S9.15: discovery and run do not share a scope. Read from an It body,
    # a $script: variable set in BeforeDiscovery throws under ./build.ps1's
    # StrictMode - and WITHOUT StrictMode it is $null, @($null).Count is 1, so
    # "scans at least one PowerShell file" passed while the scan itself covered
    # nothing at all. Nothing here is expanded at discovery time (there is no
    # -ForEach), so the run phase is the only place this belongs.
    $script:scanFile = @(
        Get-ChildItem -LiteralPath $script:contractRepoRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notmatch '\\out\\' -and
                $_.FullName -notmatch '\\\.git\\' -and
                $_.FullName -notmatch '\\tests\\fixtures\\' -and
                $_.Name -ne 'ProtectedPath.Contract.Tests.ps1'
            }
    )

    # Literal paths that must never appear as the target of a delete.
    $script:protectedPattern = @(
        'GithubRepos\\HDT'
        'C:\\HDTLab'''
        'C:\\HDTLab"'
        'C:\\HDTLab\\media'
        'C:\\HDTLab\\Share'
        'C:\\HDTLab\\reference'
    )

    function Get-HDTProtectedDeleteViolation {
        param([System.IO.FileInfo[]] $File)

        foreach ($item in $File) {
            $token = $null; $parseError = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $item.FullName, [ref] $token, [ref] $parseError)

            # Comments may discuss the rule; code may not break it.
            $code = @($token | Where-Object { $_.Kind.ToString() -ne 'Comment' })

            for ($i = 0; $i -lt $code.Count; $i++) {
                $text = [string] $code[$i].Text
                if ($text -notmatch '^(Remove-Item|rd|rmdir|Remove-VMHardDiskDrive)$') { continue }

                # Look ahead over the rest of the statement for a protected literal.
                $window = @($code[$i..([math]::Min($i + 14, $code.Count - 1))] | ForEach-Object { [string] $_.Text }) -join ' '

                foreach ($p in $script:protectedPattern) {
                    if ($window -match $p) {
                        [pscustomobject]@{
                            Path    = $item.FullName.Substring($script:contractRepoRoot.Length + 1)
                            Line    = $code[$i].Extent.StartLineNumber
                            Pattern = $p
                            Window  = $window.Substring(0, [math]::Min(110, $window.Length))
                        }
                    }
                }
            }
        }
    }
}

Describe 'Protected paths (CLAUDE.md)' {

    It 'scans at least one PowerShell file' {
        @($script:scanFile).Count | Should -BeGreaterThan 0 -Because 'a contract that scans nothing proves nothing'
    }

    It 'deletes nothing under the repository root, the lab root, the media, the share or the reference clone' {
        $violation = @(Get-HDTProtectedDeleteViolation -File $script:scanFile)

        $message = ($violation | ForEach-Object { '{0}:{1} matched {2} -> {3}' -f $_.Path, $_.Line, $_.Pattern, $_.Window }) -join "`n"
        $violation.Count | Should -Be 0 -Because "these paths are never delete targets:`n$message"
    }

    It 'catches a deliberate violation' {
        # The guard has to be shown to bite, or it is decoration.
        $bait = Join-Path -Path $TestDrive -ChildPath 'bait.ps1'
        Set-Content -LiteralPath $bait -Value 'Remove-Item -Path "C:\HDTLab\media" -Recurse -Force' -Encoding UTF8

        $hit = @(Get-HDTProtectedDeleteViolation -File @(Get-Item -LiteralPath $bait))
        $hit.Count | Should -BeGreaterThan 0 -Because 'a delete of the staged media must be caught'
    }

    It 'permits clearing the build output directory' {
        $ok = Join-Path -Path $TestDrive -ChildPath 'ok.ps1'
        Set-Content -LiteralPath $ok -Value 'Remove-Item -Path $script:HDTOutputPath -Recurse -Force' -Encoding UTF8

        @(Get-HDTProtectedDeleteViolation -File @(Get-Item -LiteralPath $ok)).Count |
            Should -Be 0 -Because 'build.ps1 -Task clean must stay legal'
    }
}
