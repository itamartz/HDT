function Get-HDTScriptCompatibilityViolation {
    <#
        .SYNOPSIS
            Reports every construct in a PowerShell file that Windows PowerShell 5.1
            cannot run.

        .DESCRIPTION
            The HDT engine ships into WinPE, which has no pwsh (DESIGN 1), so every
            file in src/ and tests/ must be valid Windows PowerShell 5.1. This is the
            scanner behind tests/contract/PowerShell51Compatibility.Contract.Tests.ps1.

            It has to give the same verdict on both engines while the two parsers
            disagree about what is even parseable, so detection runs in two tiers:

              * Under Windows PowerShell 5.1, ?? ??= ?. ?[] and the ternary operator
                are parse errors. They surface as Feature 'ParseError' and no further
                analysis of that file is possible or needed.
              * Under PowerShell 7 the same text parses, so it is caught by token
                kind (QuestionQuestion, QuestionQuestionEquals, QuestionDot,
                QuestionLBracket) and by AST node name (TernaryExpressionAst,
                ScriptBlockAst.CleanBlock).

            Constructs that parse on both engines but only run on 7 - ForEach-Object
            -Parallel, Get-Error, $PSStyle, ConvertFrom-Json -AsHashtable, and a clean
            block seen by 5.1 as a command - are caught by AST inspection either way.

            Feature values emitted:
            ParseError, NullCoalescing, NullConditional, Ternary, ForEachParallel,
            CleanBlock, ForbiddenCommand, ForbiddenParameter, ForbiddenVariable.

            Token kinds and AST node types are compared as strings. Writing
            [TokenKind]::QuestionQuestion or [TernaryExpressionAst] as a literal would
            make this very file unparseable under 5.1.

        .PARAMETER Path
            One or more PowerShell files to scan.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, Line, Column,
            Feature and Message.

        .EXAMPLE
            Get-HDTScriptCompatibilityViolation -Path ./src/Hephaestus/Hephaestus.psm1

            Returns nothing: the engine loader is 5.1-compatible.

        .EXAMPLE
            Get-HDTSourceFile -RepositoryRoot . | Get-HDTScriptCompatibilityViolation

            Scans every source file the contract suites cover.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path
    )

    begin {
        $reason = 'DESIGN 1: the engine must run on Windows PowerShell 5.1 inside WinPE'
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
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref] $token, [ref] $parseError)

            if (@($parseError).Count -gt 0) {
                foreach ($item2 in @($parseError)) {
                    [void] $violation.Add([pscustomobject] @{
                            Path    = $fullPath
                            Line    = $item2.Extent.StartLineNumber
                            Column  = $item2.Extent.StartColumnNumber
                            Feature = 'ParseError'
                            Message = ("This file does not parse on the current engine ({0}): {1} ({2})" -f $PSVersionTable.PSVersion, $item2.Message, $reason)
                        })
                }

                # A file that did not parse has no usable AST; anything else this
                # function reported about it would be invented.
                continue
            }

            foreach ($item2 in @($token)) {
                $kind = $item2.Kind.ToString()
                $feature = $null

                if ($kind -eq 'QuestionQuestion' -or $kind -eq 'QuestionQuestionEquals') {
                    $feature = 'NullCoalescing'
                } elseif ($kind -eq 'QuestionDot' -or $kind -eq 'QuestionLBracket') {
                    $feature = 'NullConditional'
                }

                if ($feature) {
                    [void] $violation.Add([pscustomobject] @{
                            Path    = $fullPath
                            Line    = $item2.Extent.StartLineNumber
                            Column  = $item2.Extent.StartColumnNumber
                            Feature = $feature
                            Message = ("PowerShell 7-only operator '{0}' is not permitted ({1})" -f $item2.Text, $reason)
                        })
                }
            }

            foreach ($item2 in @($ast.FindAll({ $args[0].GetType().Name -eq 'TernaryExpressionAst' }, $true))) {
                [void] $violation.Add([pscustomobject] @{
                        Path    = $fullPath
                        Line    = $item2.Extent.StartLineNumber
                        Column  = $item2.Extent.StartColumnNumber
                        Feature = 'Ternary'
                        Message = ("The ternary operator 'a ? b : c' is PowerShell 7-only ({0})" -f $reason)
                    })
            }

            $scriptBlock = @($ast.FindAll({ $args[0].GetType().Name -eq 'ScriptBlockAst' }, $true))
            foreach ($item2 in $scriptBlock) {
                if (($item2.PSObject.Properties.Name -contains 'CleanBlock') -and ($null -ne $item2.CleanBlock)) {
                    [void] $violation.Add([pscustomobject] @{
                            Path    = $fullPath
                            Line    = $item2.CleanBlock.Extent.StartLineNumber
                            Column  = $item2.CleanBlock.Extent.StartColumnNumber
                            Feature = 'CleanBlock'
                            Message = ("A 'clean' block is PowerShell 7.3+ only ({0})" -f $reason)
                        })
                }
            }

            $command = @($ast.FindAll({ $args[0].GetType().Name -eq 'CommandAst' }, $true))
            foreach ($item2 in $command) {
                $commandName = $item2.GetCommandName()
                if (-not $commandName) {
                    continue
                }

                $parameter = @($item2.CommandElements | Where-Object { $_.GetType().Name -eq 'CommandParameterAst' })

                if ($commandName -eq 'ForEach-Object' -or $commandName -eq '%') {
                    # Parameter prefixes are legal, so -Para and -Par must be caught
                    # as surely as -Parallel.
                    foreach ($item3 in @($parameter | Where-Object { $_.ParameterName -match '^par' })) {
                        [void] $violation.Add([pscustomobject] @{
                                Path    = $fullPath
                                Line    = $item3.Extent.StartLineNumber
                                Column  = $item3.Extent.StartColumnNumber
                                Feature = 'ForEachParallel'
                                Message = ("ForEach-Object -Parallel is PowerShell 7-only ({0})" -f $reason)
                            })
                    }
                }

                if ($commandName -eq 'Get-Error') {
                    [void] $violation.Add([pscustomobject] @{
                            Path    = $fullPath
                            Line    = $item2.Extent.StartLineNumber
                            Column  = $item2.Extent.StartColumnNumber
                            Feature = 'ForbiddenCommand'
                            Message = ("Get-Error does not exist in Windows PowerShell 5.1 ({0})" -f $reason)
                        })
                }

                if ($commandName -eq 'ConvertFrom-Json') {
                    foreach ($item3 in @($parameter | Where-Object { $_.ParameterName -match '^ash' })) {
                        [void] $violation.Add([pscustomobject] @{
                                Path    = $fullPath
                                Line    = $item3.Extent.StartLineNumber
                                Column  = $item3.Extent.StartColumnNumber
                                Feature = 'ForbiddenParameter'
                                Message = ("ConvertFrom-Json -AsHashtable is PowerShell 6+ only ({0})" -f $reason)
                            })
                    }
                }

                # Windows PowerShell 5.1 parses 'clean { }' as a command taking a
                # script block, so the 7-only named block reaches this scanner by a
                # completely different route on the two engines.
                if ($commandName -eq 'clean' -and
                    $item2.CommandElements.Count -eq 2 -and
                    $item2.CommandElements[1].GetType().Name -eq 'ScriptBlockExpressionAst') {

                    [void] $violation.Add([pscustomobject] @{
                            Path    = $fullPath
                            Line    = $item2.Extent.StartLineNumber
                            Column  = $item2.Extent.StartColumnNumber
                            Feature = 'CleanBlock'
                            Message = ("A 'clean' block is PowerShell 7.3+ only; Windows PowerShell 5.1 parses it as a command named 'clean' ({0})" -f $reason)
                        })
                }
            }

            $variable = @($ast.FindAll({ $args[0].GetType().Name -eq 'VariableExpressionAst' }, $true))
            foreach ($item2 in $variable) {
                if ($item2.VariablePath.UserPath -eq 'PSStyle') {
                    [void] $violation.Add([pscustomobject] @{
                            Path    = $fullPath
                            Line    = $item2.Extent.StartLineNumber
                            Column  = $item2.Extent.StartColumnNumber
                            Feature = 'ForbiddenVariable'
                            Message = ("The PSStyle automatic variable does not exist in Windows PowerShell 5.1 ({0})" -f $reason)
                        })
                }
            }
        }
    }

    end {
        return @($violation | Sort-Object -Property Path, Line, Column)
    }
}
