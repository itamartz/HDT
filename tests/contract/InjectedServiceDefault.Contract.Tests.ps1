# An injected service is a test seam, not something an administrator types.
#
# -FileSystem exists so the engine can run under Pester against
# New-HDTFakeFileSystem (DESIGN 13.2.1, CLAUDE.md rule 5). In production there is
# exactly one answer - New-HDTFileSystem - and every command can reach it itself.
# Sixteen commands nevertheless declared it Mandatory, which put a parameter no
# administrator has into the console's own copy-paste command strip: the strip
# had to print "-FileSystem (New-HDTFileSystem)" or the line it showed would have
# stopped on a prompt. Get-HDTApplication had already been fixed for this once.
#
# The contract covers src/Hephaestus/Public only. A private helper is never
# typed by anybody, so Mandatory there is an internal invariant rather than a
# parameter in somebody's way, and Copy-HDTContentTree keeps its.
#
# New-HDTServiceCatalog is exempt by name. It is the object every step reads its
# services out of, so a default there would let a test that forgot its fake build
# a catalog over the real disk and pass - the one failure PROJECT constraint 4
# exists to prevent. Nothing prints it in the console either, so demanding it
# costs an administrator nothing. Its own suite asserts the opposite of this
# contract, deliberately; see New-HDTServiceCatalog.Tests.ps1.
#
# It matches on [object] $FileSystem alone. Add-HDTStepPartition and
# Set-HDTStepPartition take a [string] $FileSystem - the partition's NTFS or
# FAT32, nothing to do with the service - and a scan by name alone reports them.
#
# This parses source rather than importing the manifest - the rule is about the
# shape of the parameter, which is readable without loading the module, and a
# source scan does not care which functions the manifest currently exports.

Describe 'Injected service default contract (DESIGN 13.2.1)' {

    BeforeAll {
        # Declared inside the container, not beside it: Pester 5 runs tests in a
        # scope that does not see functions defined at file scope.
        function Get-HDTFileSystemParameterShape {
            <#
                .SYNOPSIS
                    Reports how every public command declares -FileSystem.

                .DESCRIPTION
                    Returns one object per function that exposes an injected
                    -FileSystem - typed [object], which is what separates the
                    service from the partition step's [string] of the same name -
                    carrying whether it is mandatory.

                .PARAMETER Path
                    The directory to scan, normally src/Hephaestus/Public.

                .EXAMPLE
                    Get-HDTFileSystemParameterShape -Path 'src/Hephaestus/Public' |
                        Where-Object { $_.Mandatory }
            #>
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [ValidateNotNullOrEmpty()]
                [string] $Path
            )

            # The bundle is a generated concatenation of everything else under
            # src/Hephaestus, so including it would report every violation twice.
            $file = @(Get-ChildItem -LiteralPath $Path -Recurse -Filter '*.ps1' -File |
                Where-Object {
                    $_.Name -ne 'Hephaestus.bundle.ps1' -and
                    $_.BaseName -ne 'New-HDTServiceCatalog'
                })

            foreach ($item in $file) {
                $token = $null
                $parseError = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                    $item.FullName, [ref] $token, [ref] $parseError)

                $function = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true))

                foreach ($item2 in $function) {
                    if ($null -eq $item2.Body.ParamBlock) { continue }

                    $parameter = @($item2.Body.ParamBlock.Parameters |
                        Where-Object {
                            $_.Name.VariablePath.UserPath -eq 'FileSystem' -and
                            $null -ne $_.StaticType -and $_.StaticType.FullName -eq 'System.Object'
                        })
                    if ($parameter.Count -eq 0) { continue }

                    $mandatory = $false
                    foreach ($attribute in $parameter[0].Attributes) {
                        if ($attribute -isnot [System.Management.Automation.Language.AttributeAst]) { continue }
                        if ($attribute.TypeName.Name -ne 'Parameter') { continue }
                        foreach ($named in $attribute.NamedArguments) {
                            if ($named.ArgumentName -ne 'Mandatory') { continue }
                            if ($named.Argument.Extent.Text -match '\$true') { $mandatory = $true }
                        }
                    }

                    [pscustomobject] @{
                        Name      = $item2.Name
                        Path      = $item.FullName
                        Line      = $item2.Extent.StartLineNumber
                        Mandatory = $mandatory
                    }
                }
            }
        }

        $script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:HDTFileSystemParameter = @(Get-HDTFileSystemParameterShape `
            -Path (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/Public'))
    }

    It 'discovers at least thirty commands taking -FileSystem' {
        # Anti-vacuity guard. A contract that silently finds nothing to check
        # reports green forever - the same guard the naming contract carries.
        $script:HDTFileSystemParameter.Count | Should -BeGreaterThan 29
    }

    It 'never declares -FileSystem mandatory' {
        $violation = @($script:HDTFileSystemParameter | Where-Object { $_.Mandatory })

        $because = 'an injected service is a test seam, not something an administrator types'
        if ($violation.Count -gt 0) {
            $detail = foreach ($item in $violation) {
                $relative = $item.Path.Substring($script:HDTRepositoryRoot.Length).TrimStart('\', '/').Replace('\', '/')
                '{0}:{1} {2}' -f $relative, $item.Line, $item.Name
            }
            $because = @($detail) -join "`n"
        }

        $violation.Count | Should -Be 0 -Because $because
    }
}
