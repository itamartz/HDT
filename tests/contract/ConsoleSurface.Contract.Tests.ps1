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

        # WHERE ARE MY CONSOLE LOGS is a question an administrator asks out
        # loud, so the answer is a command they can type. Start- and
        # Stop-HDTConsoleLog are NOT here and are not exported: they are the
        # session's lifecycle, called by Show-HDTConsole, and nobody has a
        # reason to run them by hand - which is exactly the line this contract
        # draws.
        'Get-HDTConsoleLogPath'
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

    # ---------------------------------------------------------------------
    # AND THE SAME RULE FOR EVERY OTHER LOCAL, NOT JUST $call.
    #
    # A NON-CLOSURE SCRIPTBLOCK CANNOT SEE ITS MAKER'S LOCALS. Proved rather
    # than assumed: a $plain = { $borrowed } invoked after its function returned
    # throws "the variable '$borrowed' cannot be retrieved", and it throws the
    # same way whether it is invoked directly or through a closure that calls it.
    #
    # IT ONLY BITES WHEN THE MAKER HAS RETURNED, which is exactly what the view
    # commands do. New-HDTConsole*View BUILD a window and hand it back; the
    # ScriptMethod that called them then calls ShowDialog. So by the time a
    # handler fires, the view function's scope is gone. A method that shows the
    # window ITSELF - ShowBuildProgress does - is still on the stack while its
    # timer ticks, and its locals are still there. That is why this contract is
    # scoped to the view commands and not to the whole host.
    #
    # THIS WAS A REGRESSION, AND SPLITTING THE HOST CAUSED IT. $move in the
    # Windows PE window borrowed $startList and worked for as long as
    # ShowBootImage called ShowDialog itself. Moving the body into
    # New-HDTConsoleBootImageView made the maker return, and pressing Up on the
    # Start Command list started throwing on the dispatcher.
    # tests/unit/ConsoleButtonPress.Tests.ps1 caught that one by pressing it;
    # this catches the four it never pressed.
    It 'gives every scriptblock a handler calls its maker''s locals' {
        $auto = @('_', 'this', 'null', 'true', 'false', 'args', 'PSItem', 'error', 'PSCmdlet',
            'PSBoundParameters', 'MyInvocation', 'PSScriptRoot', 'PSCommandPath',
            'ErrorActionPreference', 'matches', 'LASTEXITCODE', 'input')

        $view = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\Private') `
                -Filter 'New-HDTConsole*View.ps1')

        $view.Count | Should -BeGreaterThan 0 -Because 'a scan of nothing must not read as success'

        $offence = @()

        foreach ($file in $view) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $null)

            foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {

                $local = @{}
                foreach ($a in $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                    $v = $a.Left -as [System.Management.Automation.Language.VariableExpressionAst]
                    if ($v) { $local[$v.VariablePath.UserPath] = $true }
                }

                foreach ($sb in $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) {

                    # $x = { ... } wraps the block in a pipeline and a command
                    # expression, so the assignment is a grandparent.
                    $up = $sb.Parent
                    while ($null -ne $up -and
                        $up -isnot [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $up -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $up -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) {

                        $up = $up.Parent
                    }

                    if ($up -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { continue }
                    $target = $up.Left -as [System.Management.Automation.Language.VariableExpressionAst]
                    if (-not $target) { continue }
                    if ($up.Right.Extent.Text -match '\.GetNewClosure\(\)\s*$') { continue }

                    $own = @{}
                    if ($sb.ScriptBlock.ParamBlock) {
                        foreach ($one in $sb.ScriptBlock.ParamBlock.Parameters) { $own[$one.Name.VariablePath.UserPath] = $true }
                    }
                    foreach ($a in $sb.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                        $v = $a.Left -as [System.Management.Automation.Language.VariableExpressionAst]
                        if ($v) { $own[$v.VariablePath.UserPath] = $true }
                    }

                    $borrowed = @{}
                    foreach ($v in $sb.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                        $name = $v.VariablePath.UserPath
                        if ($auto -contains $name) { continue }
                        if ($own.ContainsKey($name)) { continue }
                        if ($name -eq $target.VariablePath.UserPath) { continue }
                        if ($local.ContainsKey($name)) { $borrowed[$name] = $true }
                    }

                    if ($borrowed.Count -eq 0) { continue }

                    # A block only the maker calls runs in the maker's scope and
                    # is fine. The failure needs a HANDLER to call it, later.
                    $called = $false
                    foreach ($other in $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) {
                        if ($other.Extent.StartOffset -eq $sb.Extent.StartOffset) { continue }

                        $handler = $false
                        $u = $other.Parent
                        while ($null -ne $u -and $u -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                            if ($u -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                                [string] $u.Member.Value -eq 'GetNewClosure') { $handler = $true; break }

                            $u = $u.Parent
                        }
                        if (-not $handler) { continue }

                        if ($other.Extent.Text -match ('&\s*\$' + [regex]::Escape($target.VariablePath.UserPath) + '\b')) {
                            $called = $true
                            break
                        }
                    }

                    if ($called) {
                        $offence += '{0}:{1} ${2} borrows {3}' -f $file.Name, $sb.Extent.StartLineNumber,
                            $target.VariablePath.UserPath, ((@($borrowed.Keys) | Sort-Object) -join ', ')
                    }
                }
            }
        }

        $because = 'add .GetNewClosure() to it - a block a handler calls cannot see its maker''s locals once the maker has returned, and these windows are BUILT and handed back'
        if ($offence.Count -gt 0) {
            $because = "{0}. Orphaned: {1}" -f $because, (@($offence) -join '; ')
        }

        $offence.Count | Should -Be 0 -Because $because
    }

    # GetNewClosure() CAPTURES THE LOCAL SCOPE, AND A HANDLER'S SCOPE IS NOT IT.
    #
    # Inside a handler - itself a closure - the window's own variables are
    # INHERITED, not local. So a second GetNewClosure() written in there captures
    # none of them: the block it makes sees $null where $book was, and the moment
    # something invokes it, StrictMode makes that terminating inside WPF, where
    # it does nothing and says nothing.
    #
    # IT COST A DAY, TWICE OVER. The selection profile tick box put up "The
    # property 'Filling' cannot be found on this object" and - far worse - left
    # its re-entrancy guard UP, so the box worked exactly once per window. The
    # cure is always the same: build the block where the variables ARE local,
    # beside them, and let the handler capture the finished block.
    It 'never calls GetNewClosure inside a handler, where there are no locals to capture' {
        $auto = @('_', 'this', 'null', 'true', 'false', 'args', 'PSItem', 'error', 'PSCmdlet',
            'PSBoundParameters', 'MyInvocation', 'PSScriptRoot', 'PSCommandPath',
            'ErrorActionPreference', 'matches', 'LASTEXITCODE', 'input')

        $view = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\Private') `
                -Filter 'New-HDTConsole*View.ps1')

        $view += @(Get-ChildItem -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'src\Hephaestus\Public') `
                -Filter 'New-HDTConsoleHost.ps1')

        $view.Count | Should -BeGreaterThan 0 -Because 'a scan of nothing must not read as success'

        $offence = @()

        foreach ($file in $view) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $null)

            # DEPTH ALONE IS NOT THE TEST, and saying so cost a red run over 58
            # innocent lines. A GetNewClosure inside a ScriptMethod body is
            # ordinary and correct: the window's controls are assigned IN that
            # body, so they are local to it and the closure captures them.
            #
            # WHAT IS WRONG IS CAPTURING WHAT IS NOT THERE. The block being
            # closured has to name only variables the ENCLOSING block owns -
            # assigned in it, or one of its parameters. A name that merely
            # arrives from further out is inherited, and GetNewClosure does not
            # take inherited variables: it takes locals. That block then holds
            # $null and dies at the first property.
            foreach ($call in $ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                        [string] $n.Member.Value -eq 'GetNewClosure'
                    }, $true)) {

                $inner = $call.Expression -as [System.Management.Automation.Language.ScriptBlockExpressionAst]
                if ($null -eq $inner) { continue }

                # THE BLOCK THIS ONE IS WRITTEN INSIDE. None means the function
                # body, where every local is genuinely local.
                $outer = $call.Parent
                while ($null -ne $outer -and $outer -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    $outer = $outer.Parent
                }

                if ($null -eq $outer) { continue }

                $owned = @{}

                foreach ($a in $outer.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                    $v = $a.Left -as [System.Management.Automation.Language.VariableExpressionAst]
                    if ($v) { $owned[$v.VariablePath.UserPath] = $true }
                }

                if ($null -ne $outer.ScriptBlock.ParamBlock) {
                    foreach ($p in @($outer.ScriptBlock.ParamBlock.Parameters)) {
                        $owned[$p.Name.VariablePath.UserPath] = $true
                    }
                }

                # A foreach ITERATOR IS A LOCAL TOO, and it is not an assignment
                # - so without this every closure built inside a loop reads as
                # borrowing the thing it is looping over, which is seven honest
                # handlers in this console alone.
                foreach ($loop in $outer.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
                    $owned[$loop.Variable.VariablePath.UserPath] = $true
                }

                # AND THE BLOCK'S OWN PARAMETERS ARE ITS OWN. A closure written as
                # { param($text) ... } is handed $text when it runs; it is not
                # borrowing anything from the scope that made it.
                if ($null -ne $inner.ScriptBlock.ParamBlock) {
                    foreach ($p in @($inner.ScriptBlock.ParamBlock.Parameters)) {
                        $owned[$p.Name.VariablePath.UserPath] = $true
                    }
                }

                $borrowed = @{}

                foreach ($v in $inner.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                    $name = $v.VariablePath.UserPath

                    if ($auto -contains $name) { continue }
                    if ($owned.ContainsKey($name)) { continue }

                    $borrowed[$name] = $true
                }

                if ($borrowed.Count -eq 0) { continue }

                $offence += '{0}:{1} borrows {2}' -f $file.Name, $call.Extent.StartLineNumber,
                ((@($borrowed.Keys) | Sort-Object) -join ', ')
            }
        }

        $because = 'build the block where its variables are local and let the handler capture the finished block - a GetNewClosure inside a handler captures nothing and fails silently under WPF'
        if ($offence.Count -gt 0) {
            $because = "{0}. Nested: {1}" -f $because, (@($offence) -join ', ')
        }

        $offence.Count | Should -Be 0 -Because $because
    }

    # DESIGN 12: "every action it performs maps to a cmdlet invocation, and the
    # console shows that invocation - so an admin can learn the automation
    # surface by clicking around, and script anything they can do in the UI."
    #
    # THAT IS A PROPERTY OF THE SET, NOT OF THE WINDOW SOMEBODY REMEMBERED. It
    # was already missed twice: Partition Properties ships eight boxes and an OK
    # that runs Add-HDTStepPartition and had nowhere to print it, and the New
    # Task Sequence footer named three of the seven answers its own Create
    # button writes. Neither could be seen from inside the file it was in. A
    # window added tomorrow with no line on it fails here instead.
    It 'gives every console window somewhere to print the command it runs' {
        $consoleUi = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/UI/Console'

        # THE ONE THAT RUNS NOTHING. HDTBuildProgress watches a build the
        # Windows PE window started and already named; it has an elapsed time, a
        # log and a Close, and no action of its own to describe.
        $watchesOnly = @('HDTBuildProgress.xaml')

        $markup = @(Get-ChildItem -Path $consoleUi -Filter '*.xaml' -File |
                Where-Object { $_.Name -notin $watchesOnly })

        $markup.Count | Should -BeGreaterThan 0 -Because 'a sweep that walked no files would pass without looking at anything'

        $silent = @()

        foreach ($file in $markup) {
            $text = [System.IO.File]::ReadAllText($file.FullName)

            if ($text -notmatch 'x:Name="[A-Za-z]*CommandText"') { $silent += $file.Name }
        }

        $because = 'a window whose buttons run cmdlets has to show which - DESIGN 12'
        if ($silent.Count -gt 0) {
            $because = "{0}. Silent: {1}" -f $because, (@($silent) -join ', ')
        }

        $silent.Count | Should -Be 0 -Because $because
    }
}
