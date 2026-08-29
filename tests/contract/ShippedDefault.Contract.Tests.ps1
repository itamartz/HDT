# What the module ships to somebody else's machine.
#
# 'C:\HDTLab\scratch\bootimage' WAS THE EXECUTABLE DEFAULT OF A PUBLIC COMMAND
# AND WENT TO THE POWERSHELL GALLERY. Every administrator who installed
# Hephaestus and ran Update-HDTBootImage got a gigabyte-scale staging tree
# created at a path named after one author's lab. Fixing that default then left
# the same path in two more surfaces of the same command - the .PARAMETER help
# still documenting it as the default, and the refusal for a scratch path with a
# space RECOMMENDING it to whoever hit the error. The second is the worse one: a
# user on another machine follows the advice and is told to create a directory
# named after somebody else's lab.
#
# Start-HDTConsole carried the same class of defect and was worse than cosmetic.
# Show-HDTConsole deliberately defaults -Path to @() so a bare console reopens
# THE SHARES YOU LAST CLOSED IT ON; Start-HDTConsole, which is the command
# people actually type, overrode that with @('C:\HDTLab\Share') and forced one
# lab's path in place of your own shares.
#
# HOW THIS IS SCOPED, AND WHY THAT IS THE RIGHT LINE.
#
# It reads the AST: parameter DEFAULTS and string LITERALS. Both are things the
# module executes or shows to a user, and both PRESCRIBE. Comment-based help is
# invisible to the AST, so every .EXAMPLE and .DESCRIPTION naming a lab path
# passes untouched - and should, because an example DESCRIBES one
# administrator's setup and is more useful for being concrete. The distinction
# is prescribe versus describe, not where the string happens to live.
#
# History comments pass for the same reason and the same rule the 192.168.2.x
# sweep settled: an incident narrative naming a real path is a true story.
#
# WHAT IT CANNOT SEE, said plainly rather than pretended away: a .PARAMETER
# block that states a wrong default in prose is a comment, so this will not
# catch the next one. That surface is checked by reading it.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:sourceRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus'

    # PATH-SHAPED, NOT THE BARE WORD. 'HDTLabelBrush' and 'HDTLabelSize' are XAML
    # resource keys in every console window and contain 'HDTLab' as a substring;
    # a naive match reports forty-seven brushes as lab paths and buries the four
    # that are real.
    # BUILT FROM [char] 92 RATHER THAN WRITTEN AS A LITERAL. A regex class
    # of backslash-or-slash is one escaped backslash away from meaning only
    # SLASH, and that version matches no Windows path at all - the check
    # passes, reports nothing, and is worse than not existing. Wildcards
    # need no escaping, so there is nothing to get wrong.
    $script:namesLabPath = {
        param([string] $Text)

        return ($Text -like ('*HDTLab{0}*' -f [char] 92) -or $Text -like '*HDTLab/*')
    }

    $script:sourceFile = @(Get-ChildItem -LiteralPath $script:sourceRoot -Filter '*.ps1' -Recurse -File |
            Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' })
}

Describe 'Shipped defaults and messages' {

    It 'has source files to check' {
        @($script:sourceFile).Count | Should -BeGreaterThan 100
    }

    It 'names no lab path in any parameter default' {
        $offender = @()

        foreach ($file in $script:sourceFile) {
            $token = $null
            $parseError = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $token, [ref] $parseError)

            if (@($parseError).Count -gt 0) { continue }

            foreach ($parameter in @($ast.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.ParameterAst]
                        }, $true))) {

                if ($null -eq $parameter.DefaultValue) { continue }

                $text = [string] $parameter.DefaultValue.Extent.Text
                if (& $script:namesLabPath $text) {
                    $offender += ('{0}:{1} -{2} = {3}' -f $file.Name,
                        $parameter.Extent.StartLineNumber,
                        $parameter.Name.VariablePath.UserPath, $text)
                }
            }
        }

        ($offender -join '; ') | Should -BeExactly ''
    }

    It 'names no lab path in any string the module executes or shows' {
        # STRING LITERALS, which is where an error message lives. The refusal
        # that told a user to "choose a scratch path such as
        # C:\HDTLab\scratch\bootimage" was one of these.
        $offender = @()

        foreach ($file in $script:sourceFile) {
            $token = $null
            $parseError = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $token, [ref] $parseError)

            if (@($parseError).Count -gt 0) { continue }

            foreach ($literal in @($ast.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                            $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
                        }, $true))) {

                $text = [string] $literal.Extent.Text
                if (& $script:namesLabPath $text) {
                    $offender += ('{0}:{1} {2}' -f $file.Name, $literal.Extent.StartLineNumber,
                        $text.Substring(0, [Math]::Min(80, $text.Length)))
                }
            }
        }

        ($offender -join '; ') | Should -BeExactly ''
    }
}
