function Get-HDTMdtDependency {
    <#
        .SYNOPSIS
            Reports every reference to a Microsoft Deployment Toolkit component in a
            PowerShell file.

        .DESCRIPTION
            HDT exists because MDT is deprecated, so a replacement that still needs
            MDT installed is not a replacement (CLAUDE.md hard rule 4, PROJECT.md
            "MDT dependency: NONE"). This is the scanner behind
            tests/contract/NoMdtDependency.Contract.Tests.ps1.

            It scans code, not comments. Documentation and code comments
            legitimately say things like "replaces ZTIGather.wsf", so the token
            stream is filtered to non-comment tokens before matching. ADK (DISM,
            oscdimg, WinPE) and WDS are permitted and are not in the term list.

            The term list lives in ../data/HDTMdtTerm.psd1. Get-HDTSourceFile
            excludes .psd1 files, so the patterns are not themselves scanned by the
            contract that consumes them - written inline here, every one of them
            would flag this file.

            A file that cannot be parsed - PowerShell 7-only syntax read under 5.1,
            for instance - falls back to a line-by-line text scan that skips lines
            beginning with '#', and says so in the message. Returning nothing for
            such a file would let an MDT dependency hide behind a parse error.

        .PARAMETER Path
            One or more PowerShell files to scan.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, Line, Column,
            Term and Message.

        .EXAMPLE
            Get-HDTMdtDependency -Path ./src/Hephaestus/Hephaestus.psm1

            Returns nothing: the engine has no MDT dependency.

        .EXAMPLE
            Get-HDTSourceFile -RepositoryRoot . | Get-HDTMdtDependency

            Scans the whole repository.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path
    )

    begin {
        $dataPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'data/HDTMdtTerm.psd1'
        if (-not (Test-Path -LiteralPath $dataPath -PathType Leaf)) {
            throw "The MDT term list is missing at '$dataPath'."
        }

        $term = @((Import-PowerShellDataFile -Path $dataPath).Term)
        $rule = 'CLAUDE.md rule 4: zero MDT components; ADK and WDS are permitted'
        $violation = New-Object -TypeName System.Collections.ArrayList
    }

    process {
        foreach ($item in $Path) {
            if (-not (Test-Path -LiteralPath $item -PathType Leaf)) {
                throw "Source file '$item' does not exist."
            }

            $fullPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $item).ProviderPath)

            $token = $null
            $parseError = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref] $token, [ref] $parseError)

            if (@($parseError).Count -eq 0) {
                $code = @($token | Where-Object { $_.Kind.ToString() -ne 'Comment' })

                foreach ($item2 in $code) {
                    foreach ($item3 in $term) {
                        if ($item2.Text -match $item3.Pattern) {
                            [void] $violation.Add([pscustomobject] @{
                                    Path    = $fullPath
                                    Line    = $item2.Extent.StartLineNumber
                                    Column  = $item2.Extent.StartColumnNumber
                                    Term    = $item3.Name
                                    Message = ("MDT dependency '{0}' ({1}) is forbidden ({2})" -f $item3.Name, $item3.Description, $rule)
                                })

                            # One violation per token: the first matching term is
                            # enough to fail the build and to name the problem.
                            break
                        }
                    }
                }

                continue
            }

            $line = @(Get-Content -Path $fullPath -ErrorAction Stop)
            for ($index = 0; $index -lt $line.Count; $index++) {
                $text = $line[$index]
                if ($text.TrimStart().StartsWith('#')) {
                    continue
                }

                foreach ($item3 in $term) {
                    $match = [regex]::Match($text, $item3.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    if ($match.Success) {
                        [void] $violation.Add([pscustomobject] @{
                                Path    = $fullPath
                                Line    = $index + 1
                                Column  = $match.Index + 1
                                Term    = $item3.Name
                                Message = ("MDT dependency '{0}' ({1}) is forbidden ({2}). This file does not parse on the current engine ({3}), so it was checked by a raw text scan that skips comment lines." -f $item3.Name, $item3.Description, $rule, $PSVersionTable.PSVersion)
                            })

                        break
                    }
                }
            }
        }
    }

    end {
        return @($violation | Sort-Object -Property Path, Line, Column)
    }
}
