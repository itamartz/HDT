function Get-HDTSourceFunction {
    <#
        .SYNOPSIS
            Enumerates every function defined in one or more PowerShell source files.

        .DESCRIPTION
            Parses each file with the PowerShell language parser and returns one
            object per function definition, including functions nested inside other
            functions. This is what the naming contract (DESIGN 15.1) enumerates, so
            two properties matter beyond the name: the file and the line, because a
            contract failure has to point at something a developer can open.

            A file that fails to parse is a terminating error, never an empty result.
            Windows PowerShell 5.1 cannot parse PowerShell 7-only syntax, and a
            scanner that quietly returned "no functions" for such a file would make
            the naming contract pass vacuously - the exact failure mode these
            contracts exist to prevent.

            Type comparisons are made on GetType().Name rather than on type literals
            because AST type literals differ in availability between engines.

        .PARAMETER Path
            One or more PowerShell files (.ps1, .psm1) to parse.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Name, Path and Line.

        .EXAMPLE
            Get-HDTSourceFunction -Path ./build.ps1

            Lists every function build.ps1 defines, with its line number.

        .EXAMPLE
            Get-HDTSourceFile -RepositoryRoot . | Get-HDTSourceFunction

            Enumerates every function in the repository.
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path
    )

    begin {
        $found = New-Object -TypeName System.Collections.ArrayList
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
                $first = @($parseError)[0]
                throw ("Parse error in '{0}' at line {1}: {2}" -f $fullPath, $first.Extent.StartLineNumber, $first.Message)
            }

            $definition = @($ast.FindAll({ $args[0].GetType().Name -eq 'FunctionDefinitionAst' }, $true))
            foreach ($item2 in $definition) {
                [void] $found.Add([pscustomobject] @{
                        Name = $item2.Name
                        Path = $fullPath
                        Line = $item2.Extent.StartLineNumber
                    })
            }
        }
    }

    end {
        return $found.ToArray()
    }
}
