# WHAT AN ADMINISTRATOR TYPES, AND WHAT A WINDOW USES, ARE NOT THE SAME LIST.
#
# The module exports the commands somebody runs against a deployment share.
# Building the Add menu, filling the Options tab, laying out the partition grid
# and deciding whether the Import button is enabled are not those commands: they
# are what one window needs to draw itself, and an administrator reading
# Get-Command should not have to tell them apart from New-HDTWorkspace.
#
# THEY WERE EXPORTED FOR A MECHANICAL REASON, NOT A CHOSEN ONE. Every handler in
# New-HDTConsoleHost is a closure, .GetNewClosure() rebinds a scriptblock to the
# session state of whoever called the method, and only an exported function
# resolves out there. Get-HDTHandlerCall is the door that removed the need, and
# this file is what stops the surface drifting back through it.
#
# THE FOUR ADAPTERS STAY. New-HDTConsoleHost, New-HDTConsoleScreen,
# New-HDTConsoleProgressHost and New-HDTConsoleBootStatusHost are the injected
# services DESIGN 5 requires a public constructor for - the same contract
# New-HDTFileSystem has - and a test passes a fake in their place.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:manifestPath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'
    $script:exported = @((Import-PowerShellDataFile -Path $script:manifestPath).FunctionsToExport)

    # The console commands an administrator has a reason to type, and the
    # adapters that exist to be injected. Everything else with Console in its
    # name belongs to a window.
    $script:allowed = @(
        'Start-HDTConsole'
        'Show-HDTConsole'
        'New-HDTConsoleHost'
        'New-HDTConsoleScreen'
        'New-HDTConsoleProgressHost'
        'New-HDTConsoleBootStatusHost'
    )
}

Describe 'Console surface contract' {

    It 'exports no console helper beyond the entry points and the adapters' {
        $leaked = @($script:exported | Where-Object { $_ -like '*Console*' -and $_ -notin $script:allowed })

        $because = 'a view-model builder is what a window needs, not what an administrator runs'
        if ($leaked.Count -gt 0) {
            $because = "{0}. Leaked: {1}" -f $because, (@($leaked) -join ', ')
        }

        $leaked.Count | Should -Be 0 -Because $because
    }

    It 'still exports every entry point and adapter' {
        foreach ($name in $script:allowed) {
            $script:exported | Should -Contain $name -Because "$name is what somebody calls"
        }
    }

    It 'keeps the helpers where they can be reached from inside the module' {
        Import-Module -Name $script:manifestPath -Force -ErrorAction Stop

        InModuleScope Hephaestus {
            Get-Command -Name Get-HDTConsoleTreeNode -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    It 'does not leave one of them reachable from outside it' {
        Get-Command -Name Get-HDTConsoleTreeNode -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    # The one that would have shipped broken: a handler naming a private helper
    # directly resolves it in the console's scope, where it does not exist. Every
    # such call has to go through the door.
    It 'names no private console helper directly inside a closure' {
        $files = @(
            (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/New-HDTConsoleHost.ps1')
            (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Private/New-HDTConsoleShareReader.ps1')
        )

        $private = @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Private') -Filter '*.ps1' |
                ForEach-Object { $_.BaseName } |
                Where-Object { $_ -like '*Console*' -and $_ -notin $script:allowed })

        $offence = foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref] $tokens, [ref] $errors)

            $closures = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                        $node.Member.Extent.Text -eq 'GetNewClosure' -and
                        $node.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
                    }, $true))

            foreach ($closure in $closures) {
                $calls = @($closure.Expression.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.CommandAst]
                        }, $true))

                foreach ($call in $calls) {
                    $name = $call.GetCommandName()
                    if ($null -ne $name -and $private -contains $name) {
                        '{0}:{1} {2}' -f (Split-Path -Leaf $file), $call.Extent.StartLineNumber, $name
                    }
                }
            }
        }

        $offence = @($offence)
        $because = 'call it through Get-HDTHandlerCall - a closure resolves commands in the caller''s scope'
        if ($offence.Count -gt 0) {
            $because = "{0}. Found: {1}" -f $because, (@($offence) -join '; ')
        }

        $offence.Count | Should -Be 0 -Because $because
    }

    # -Switch:$value IS PARSED AGAINST THE DOOR, NOT AGAINST THE COMMAND, so the
    # name and the value arrive as two loose arguments and the value binds
    # positionally. It reached a window: the task sequence editor opened on "a
    # positional parameter cannot be found that accepts argument 'False'". A
    # switch travels as a hashtable or not at all.
    It 'passes no colon-bound switch through Get-HDTHandlerCall' {
        $files = @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus') `
                -Filter '*.ps1' -Recurse |
                Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' })

        $offence = foreach ($file in $files) {
            $number = 0
            foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
                $number++
                if ($line -notmatch '&\s+\$call\s') { continue }
                if ($line -match '-[A-Za-z][A-Za-z0-9]*:') {
                    '{0}:{1}' -f $file.Name, $number
                }
            }
        }

        $offence = @($offence)
        $because = "pass it as a hashtable - & `$call 'Name' @{ Switch = `$value }"
        if ($offence.Count -gt 0) {
            $because = "{0}. Found: {1}" -f $because, (@($offence) -join ', ')
        }

        $offence.Count | Should -Be 0 -Because $because
    }

    # .GetNewClosure() CAPTURES THE LOCAL SCOPE AND NOTHING ELSE. $call declared
    # in a method is a PARENT scope to a plain scriptblock invoked with & from
    # inside it - readable there, but not captured by any closure that block
    # makes. The boot image window shipped exactly that: $wireRuleTab read $call
    # happily and the keystroke handlers it built found nothing behind the &, so
    # the whole window refused to open.
    #
    # So every scope that BUILDS a closure naming $call has to hold $call itself,
    # or inherit it through closures all the way up.
    It 'declares the door in every scope that names it' {
        $files = @(Get-ChildItem -Path (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus') `
                -Filter '*.ps1' -Recurse |
                Where-Object { $_.Name -ne 'Hephaestus.bundle.ps1' })

        $offence = foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $errors)
            if (@($errors).Count -gt 0) { continue }

            # A closure carries its maker's locals; nothing else does. So for
            # every use of $call, walk out: the first scope that is not a closure
            # has to be the one that assigned it.
            $closureAt = @{}
            foreach ($made in @($ast.FindAll({
                            param($n)
                            $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                            $n.Member.Extent.Text -eq 'GetNewClosure' -and
                            $n.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
                        }, $true))) {
                $closureAt[$made.Expression.ScriptBlock.Extent.StartOffset] = $true
            }

            foreach ($use in @($ast.FindAll({
                            param($n)
                            $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                            $n.VariablePath.UserPath -eq 'call'
                        }, $true))) {

                if ($use.Parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $use.Parent.Left.Extent.Text -eq '$call') { continue }

                $held = $false
                $scope = $use.Parent

                while ($null -ne $scope) {
                    if ($scope -is [System.Management.Automation.Language.ScriptBlockAst]) {
                        # Its OWN statements, not a nested block's: a local of
                        # something nested inside is not a local of this.
                        $mine = $false
                        foreach ($set in @($scope.FindAll({
                                        param($n)
                                        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                                        $n.Left.Extent.Text -eq '$call'
                                    }, $true))) {

                            $owner = $set.Parent
                            while ($null -ne $owner -and
                                $owner -isnot [System.Management.Automation.Language.ScriptBlockAst]) {
                                $owner = $owner.Parent
                            }

                            if ($null -ne $owner -and $owner.Extent.StartOffset -eq $scope.Extent.StartOffset) {
                                $mine = $true
                                break
                            }
                        }

                        if ($mine) { $held = $true; break }
                        if (-not $closureAt.ContainsKey($scope.Extent.StartOffset)) { break }
                    }

                    $scope = $scope.Parent
                }

                if (-not $held) {
                    '{0}:{1}' -f $file.Name, $use.Extent.StartLineNumber
                }
            }
        }

        $offence = @($offence | Sort-Object -Unique)
        $because = 'add $call = Get-HDTHandlerCall to the scope that names it - only a closure carries its maker''s locals'
        if ($offence.Count -gt 0) {
            $because = "{0}. Orphaned: {1}" -f $because, (@($offence) -join ', ')
        }

        $offence.Count | Should -Be 0 -Because $because
    }
}
