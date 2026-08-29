function Get-HDTScratchRootReference {
    <#
        .SYNOPSIS
            Reports every C:\HDTLab\scratch root a test file names, and whether
            that file removes it.

        .DESCRIPTION
            The reader behind ScratchTeardown.Contract.Tests.ps1. tests/e2e has
            four files, each builds a boot image into its own root under
            C:\HDTLab\scratch, and before this existed not one of them removed
            it - the scratch area reached 7.1 GB, 5 GB of it dead build roots
            from runs weeks apart.

            A ROOT IS THE FIRST LEVEL under C:\HDTLab\scratch and nothing deeper,
            because that is the only thing a teardown may delete and because it
            folds the many mentions of one area - 'C:\HDTLab\scratch\e2e',
            '...\e2e\deploy-04-windows.png' inside a failure message, the
            Join-Path that builds '...\e2e\RESULT.json' - into the single
            question worth asking: does anything give that directory back?

            REMOVED means the file passes that exact root to
            Remove-HDTLabScratchTree. Any other removal shape is not counted, on
            purpose: the guard that refuses the media, the lab root and the live
            build scratch lives in that one command, and a teardown that reached
            for Remove-Item directly would be exactly the four-copies-of-the-
            assertion problem CLAUDE.md forbids.

            TOKENS, NOT LINES, so a path inside a comment - a note about the rule,
            a pointer to a screenshot for a human - is not mistaken for code that
            builds one. A FILE THAT DOES NOT PARSE falls back to a line scan and
            says so on every row, the same discipline Get-HDTMdtDependency
            carries: returning nothing for a file with a syntax error would let
            the leak hide behind it.

        .PARAMETER Path
            One or more PowerShell files to read.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, Root, Line,
            Removed and Parsed.

        .EXAMPLE
            Get-HDTScratchRootReference -Path ./tests/e2e/Wizard.E2E.Tests.ps1

            Two rows: wizard-e2e, removed by the AfterAll, and
            wizard-e2e-artifacts, which is kept.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path
    )

    begin {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        # Anchored on the scratch area and stopping at the first separator: the
        # capture is the first-level directory name and nothing below it.
        $pattern = '(?i)C:\\HDTLab\\scratch\\([A-Za-z0-9][A-Za-z0-9._-]*)'
        $area = 'C:\HDTLab\scratch\'
        $remover = 'Remove-HDTLabScratchTree'
    }

    process {
        foreach ($file in $Path) {
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }

            $token = $null; $parseError = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $file, [ref] $token, [ref] $parseError)

            $found = @{}
            $removed = @{}
            $parsed = $true

            if ($null -eq $token -or @($parseError).Count -gt 0) {
                # A file that does not parse still gets read, line by line, so a
                # syntax error cannot hide a leak. Nothing is credited as removed
                # in this mode: a line scan cannot tell an argument from a
                # mention, and crediting wrongly is the failure that matters.
                $parsed = $false
                $line = @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)

                for ($n = 0; $n -lt $line.Count; $n++) {
                    foreach ($hit in ([regex]::Matches($line[$n], $pattern))) {
                        $root = $area + $hit.Groups[1].Value
                        if (-not $found.ContainsKey($root)) { $found[$root] = $n + 1 }
                    }
                }
            } else {
                $code = @($token | Where-Object { $_.Kind.ToString() -ne 'Comment' })

                for ($i = 0; $i -lt $code.Count; $i++) {
                    $text = [string] $code[$i].Text

                    foreach ($hit in ([regex]::Matches($text, $pattern))) {
                        $root = $area + $hit.Groups[1].Value
                        if (-not $found.ContainsKey($root)) {
                            $found[$root] = $code[$i].Extent.StartLineNumber
                        }
                    }

                    if ($text -ne $remover) { continue }

                    # The arguments of this call, and only this call: the window
                    # stops well short of the next statement.
                    $last = [math]::Min($i + 8, $code.Count - 1)
                    foreach ($argument in @($code[$i..$last] | ForEach-Object { [string] $_.Text })) {
                        foreach ($hit in ([regex]::Matches($argument, $pattern))) {
                            $removed[($area + $hit.Groups[1].Value)] = $true
                        }
                    }
                }
            }

            foreach ($root in ($found.Keys | Sort-Object)) {
                [pscustomobject] @{
                    Path    = $file
                    Root    = $root
                    Line    = $found[$root]
                    Removed = [bool] $removed.ContainsKey($root)
                    Parsed  = $parsed
                }
            }
        }
    }
}
