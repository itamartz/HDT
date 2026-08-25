# AN EXAMPLE THAT SHOWS NOTHING IS WORSE THAN NO EXAMPLE, because it makes the
# help look finished.
#
# THE ONE THAT STARTED THIS. Get-HDTUsableAddress carried exactly this:
#
#     .EXAMPLE
#         Get-HDTUsableAddress -Fact $fact
#
# $fact arrives from nowhere. Nothing shows what comes back. It is the SYNTAX
# line restated - and PowerShell already prints that above it. For a command
# whose entire reason to exist is that HDTIPAddress arrives in four different
# shapes, the example demonstrated none of them.
#
# WHY IT DRIFTED TO 23% OF THE MODULE: nothing checked. Naming is enforced here,
# so are the PowerShell 5.1 rules, no-MDT, ShouldProcess and the console surface.
# Examples were the one thing left to good intentions, and they went the way
# things left to good intentions go - 54 commands with no example that shows a
# result, and two whole families of them copied down a list.
#
# WHAT THIS FILE ASKS FOR, and deliberately no more:
#
#   two of them          one call is a syntax line; the second is where the
#                        interesting case goes - the switch, the failure, the
#                        pipeline, the shape somebody gets wrong
#   it parses            an example that is not PowerShell cannot be pasted
#   the command is real  a renamed cmdlet leaves its examples naming a ghost
#   the parameters exist a renamed parameter does the same, more quietly
#   nothing from nowhere every $variable is assigned inside the example, or the
#                        reader cannot run it
#
# WHAT IT DOES NOT ASK FOR: a remark under every example. New-HDTWorkspace
# -Path 'C:\HDTShare' -Id 'HDT-LAB' explains itself, and a rule that demanded a
# sentence there would be answered with a sentence that says nothing.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:manifestPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'
    Import-Module -Name $script:manifestPath -Force -ErrorAction Stop

    $script:command = @(Get-Command -Module Hephaestus -CommandType Function | Sort-Object Name)

    # WHAT A READER DOES NOT HAVE TO DECLARE. Automatic variables, the pipeline
    # variable, and anything out of the environment drive.
    $script:automatic = @(
        '_', 'psitem', 'true', 'false', 'null', 'args', 'input', 'this', 'matches',
        'error', 'host', 'home', 'pwd', 'profile', 'switch', 'foreach', 'lastexitcode',
        'pscmdlet', 'psboundparameters', 'psscriptroot', 'pscommandpath', 'psversiontable',
        'myinvocation', 'executioncontext', 'stacktrace', 'ofs', 'shellid', 'pid'
    )

    # READ FROM THE SOURCE, NOT FROM Get-Help. Get-Help puts only the FIRST LINE
    # of an example into .code and drops the rest into remarks, so every
    # multi-line example arrives here truncated mid-expression - which this file
    # reported as "not PowerShell" for a dozen examples that are perfectly good.
    # The help comment in the file is what the author wrote and what this should
    # judge; GetHelpContent hands it over verbatim.
    $script:sourceOf = @{}

    foreach ($file in @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus') `
                -Filter '*.ps1' -Recurse |
                Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' })) {

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $errors)
        if (@($errors).Count -gt 0) { continue }

        foreach ($definition in @($ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
                    }, $true))) {

            if (-not $script:sourceOf.ContainsKey($definition.Name)) {
                $script:sourceOf[$definition.Name] = $definition
            }
        }
    }

    # AN EXAMPLE IS CODE FIRST, THEN COMMENTARY.
    $script:codeIn = {
        param([string] $Example)


        # AN EXAMPLE IS CODE FIRST, THEN COMMENTARY. Take the leading run of blocks
        # that both parse as PowerShell and look like code - a call, an assignment,
        # a pipeline. Stop at the first that does not: that is the remark, or the
        # output the author pasted underneath, and neither is something to run.
        $block = @((($Example -replace "`r`n", "`n") -split "`n`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $code = @()
        foreach ($piece in $block) {
            $isCode = $false
            foreach ($line in ($piece -split "`n")) {
                # ANCHORED AT THE START OF THE LINE. A remark that mentions a command
                # by name - "a test passes New-HDTFakeFileSystem instead" - is prose,
                # and reading it as code makes the sentence a finding.
                if ($line -match '^\s*[A-Za-z]+-[A-Za-z][A-Za-z0-9]*(\s|$)' -or
                    $line -match '^\s*\$[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*\s*=' -or
                    $line -match '^\s*\$[A-Za-z_][A-Za-z0-9_]*' -or
                    $line -match '^\s*(&|if|foreach|while|switch|try|\[void\]|@?\()') {
                    $isCode = $true
                    break
                }
            }
            if (-not $isCode) { break }

            $t = $null
            $e = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($piece, [ref] $t, [ref] $e)
            if (@($e).Count -gt 0) { break }

            $code += $piece
        }

        return ((@($code) -join "`n").Trim())
    }

    $script:exampleOf = {
        param([string] $Name)

        if (-not $script:sourceOf.ContainsKey($Name)) { return @() }

        $help = $script:sourceOf[$Name].GetHelpContent()
        if ($null -eq $help) { return @() }

        return @(@($help.Examples) |
                ForEach-Object { & $script:codeIn ([string] $_) } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    # Every variable the example itself sets: an assignment, a foreach variable,
    # or a parameter of a scriptblock written inside it.
    $script:declaredIn = {
        param($Ast)

        $name = New-Object System.Collections.Generic.HashSet[string]

        foreach ($node in @($Ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.AssignmentStatementAst]
                    }, $true))) {
            foreach ($target in @($node.Left.FindAll({
                            param($n)
                            $n -is [System.Management.Automation.Language.VariableExpressionAst]
                        }, $true))) {
                [void] $name.Add($target.VariablePath.UserPath.ToLowerInvariant())
            }
        }

        foreach ($node in @($Ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.ForEachStatementAst]
                    }, $true))) {
            [void] $name.Add($node.Variable.VariablePath.UserPath.ToLowerInvariant())
        }

        foreach ($node in @($Ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.ParameterAst]
                    }, $true))) {
            [void] $name.Add($node.Name.VariablePath.UserPath.ToLowerInvariant())
        }

        # THE COMMA MATTERS. PowerShell unrolls a collection on the way out, so
        # returning the set bare hands back its members - or nothing at all when
        # it is empty, and then .Add() is called on $null.
        return , $name
    }
}

Describe 'Example quality contract' {

    It 'has commands to check in the first place' {
        # Anti-vacuity guard, the same one the naming contract carries.
        $script:command.Count | Should -BeGreaterThan 100
    }

    It 'gives every exported command at least two examples' {
        $short = foreach ($one in $script:command) {
            $count = @(& $script:exampleOf $one.Name).Count
            if ($count -lt 2) { '{0} ({1})' -f $one.Name, $count }
        }

        $short = @($short)
        $because = 'one call is the syntax line PowerShell already prints; the second example is where the case worth knowing goes'
        if ($short.Count -gt 0) {
            $because = "{0}. Short: {1}" -f $because, (@($short) -join ', ')
        }

        $short.Count | Should -Be 0 -Because $because
    }

    # A LINE THAT STARTS WITH A DOT IS A HELP KEYWORD, whatever the author
    # meant by it. ".inf files ship UTF-16LE as often as ANSI" opening a line
    # inside .DESCRIPTION ends the description there and sends everything after
    # it - every .PARAMETER, every .EXAMPLE - into a section PowerShell does not
    # recognise and silently drops. Get-HDTDriver lost all three of its examples
    # that way and read as though it had none.
    #
    # IT SWEEPS EVERY FUNCTION, NOT THE EXPORTED ONES. Seven of the eight files
    # this found were private helpers, whose help nothing else here checks - and
    # whose help is what the next person to change them reads.
    It 'never opens a help line with a word that is not a help keyword' {
        $keyword = @('SYNOPSIS', 'DESCRIPTION', 'PARAMETER', 'INPUTS', 'OUTPUTS', 'EXAMPLE',
            'NOTES', 'LINK', 'COMPONENT', 'ROLE', 'FUNCTIONALITY', 'FORWARDHELPTARGETNAME',
            'FORWARDHELPCATEGORY', 'REMOTEHELPRUNSPACE', 'EXTERNALHELP')

        $swallowed = foreach ($file in @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus') `
                    -Filter '*.ps1' -Recurse | Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' })) {

            $inHelp = $false

            foreach ($line in @([System.IO.File]::ReadAllLines($file.FullName))) {
                $trimmed = $line.Trim()

                if ($trimmed.StartsWith('<#')) { $inHelp = $true; continue }
                if ($trimmed.StartsWith('#>')) { $inHelp = $false; continue }
                if (-not $inHelp) { continue }
                if (-not ($trimmed -match '^\.[A-Za-z]')) { continue }

                $word = ($trimmed.Substring(1) -split '[\s.,;:]')[0].ToUpperInvariant()
                if ($keyword -contains $word) { continue }

                '{0}: {1}' -f $file.Name, $trimmed
            }
        }

        $swallowed = @($swallowed)
        $because = 'a help line opening with a dot is read as a section keyword, and everything after it is dropped'
        if ($swallowed.Count -gt 0) {
            $because = "{0}. Found: {1}" -f $because, (@($swallowed) -join '; ')
        }

        $swallowed.Count | Should -Be 0 -Because $because
    }

    It 'writes every example in PowerShell that parses' {
        $broken = foreach ($one in $script:command) {
            foreach ($code in @(& $script:exampleOf $one.Name)) {
                $tokens = $null
                $errors = $null
                $null = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref] $tokens, [ref] $errors)
                if (@($errors).Count -gt 0) {
                    '{0}: {1}' -f $one.Name, @($errors)[0].Message
                }
            }
        }

        $broken = @($broken)
        $because = 'an example that is not PowerShell cannot be pasted into a prompt'
        if ($broken.Count -gt 0) {
            $because = "{0}. Broken: {1}" -f $because, (@($broken) -join '; ')
        }

        $broken.Count | Should -Be 0 -Because $because
    }

    It 'names no variable the example did not give the reader' {
        $ghost = foreach ($one in $script:command) {
            # ACROSS THE EXAMPLES, IN ORDER. Help is read top to bottom: an
            # example that builds $context and a following one that uses it is
            # how every reference on the system is written, and demanding each
            # example repeat six lines of scaffolding would make them unreadable
            # to enforce a rule nobody wanted.
            $sofar = New-Object System.Collections.Generic.HashSet[string]

            foreach ($code in @(& $script:exampleOf $one.Name)) {
                $tokens = $null
                $errors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref] $tokens, [ref] $errors)
                if (@($errors).Count -gt 0) { continue }

                $declared = @(& $script:declaredIn $ast)[0]
                foreach ($carried in @($sofar)) { [void] $declared.Add($carried) }
                foreach ($fresh in @($declared)) { [void] $sofar.Add($fresh) }

                foreach ($use in @($ast.FindAll({
                                param($n)
                                $n -is [System.Management.Automation.Language.VariableExpressionAst]
                            }, $true))) {
                    $path = $use.VariablePath
                    if ($path.IsDriveQualified) { continue }

                    $name = $path.UserPath.ToLowerInvariant()
                    if ($script:automatic -contains $name) { continue }
                    if ($declared.Contains($name)) { continue }

                    '{0}: ${1}' -f $one.Name, $path.UserPath
                }
            }
        }

        $ghost = @($ghost | Sort-Object -Unique)
        $because = 'a reader cannot run an example whose input arrives from nowhere - assign it in the example, or show the command that produces it'
        if ($ghost.Count -gt 0) {
            $because = "{0}. From nowhere: {1}" -f $because, (@($ghost) -join ', ')
        }

        $ghost.Count | Should -Be 0 -Because $because
    }

    It 'names only parameters the command actually has' {
        $wrong = foreach ($one in $script:command) {
            foreach ($code in @(& $script:exampleOf $one.Name)) {
                $tokens = $null
                $errors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref] $tokens, [ref] $errors)
                if (@($errors).Count -gt 0) { continue }

                foreach ($call in @($ast.FindAll({
                                param($n)
                                $n -is [System.Management.Automation.Language.CommandAst]
                            }, $true))) {
                    $called = $call.GetCommandName()
                    if ([string]::IsNullOrWhiteSpace($called)) { continue }
                    if ($called -notlike '*-HDT*') { continue }

                    $target = Get-Command -Name $called -Module Hephaestus -ErrorAction SilentlyContinue
                    if ($null -eq $target) {
                        '{0}: names {1}, which this module does not export' -f $one.Name, $called
                        continue
                    }

                    foreach ($element in @($call.CommandElements)) {
                        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }

                        $parameter = $element.ParameterName
                        $known = @($target.Parameters.Keys) | Where-Object { $_ -like ($parameter + '*') }
                        if (@($known).Count -eq 0) {
                            '{0}: {1} has no -{2}' -f $one.Name, $called, $parameter
                        }
                    }
                }
            }
        }

        $wrong = @($wrong | Sort-Object -Unique)
        $because = 'a renamed parameter leaves its examples naming one that is gone, and nothing else notices'
        if ($wrong.Count -gt 0) {
            $because = "{0}. Wrong: {1}" -f $because, (@($wrong) -join '; ')
        }

        $wrong.Count | Should -Be 0 -Because $because
    }
}
