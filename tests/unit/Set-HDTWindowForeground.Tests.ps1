# THE COMMAND THAT PUTS A DEPLOYMENT SCREEN IN FRONT OF THE SHELL.
#
# WHAT IT IS FOR. In the full-OS leg the machine is logged in as the local
# Administrator with a real desktop behind it, and a deployed machine showed the
# Windows taskbar and the Start menu drawing straight OVER the progress board
# and over the Deployment Summary.
#
# WHY NOT Topmost. The taskbar is itself a topmost window, so a topmost window of
# ours is its PEER and the one activated last is in front - clicking Start puts
# the shell over anything. And the Deployment Summary must never be topmost: its
# Open CMD button hands the machine to a command prompt, and a topmost window
# outranks the prompt it just launched. That rule is held for every window in
# src\Hephaestus\UI by tests/contract/WinPeWindowReach.Contract.Tests.ps1, and
# this command exists so that raising a window does not mean breaking it.
#
# HOW IT IS TESTED, AND WHAT IS DELIBERATELY NOT.
#
# THE WIN32 PATH IS NEVER EXECUTED HERE. Force injects real keystrokes with
# keybd_event - an Escape to dismiss an open Start menu and an Alt tap to
# satisfy the foreground rules - and those keystrokes go to whatever has focus
# on the machine running the suite. A unit test that called it would type into
# the developer's own desktop. So the tests below drive the two things that can
# be driven safely: the guard that returns before any Win32 call at all, and the
# SOURCE, asserted as text.
#
# ASSERTING THE SOURCE IS NOT A CONSOLATION PRIZE. Every line in it is load
# bearing and none of them looks it - the whole function reads like four
# redundant ways of saying "come to the front", and a later reader deleting any
# one of them gets a call that silently returns false and a window that stays
# behind the Start menu. These tests are what a deletion has to argue with.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # THE PRIVATE HELPER IS REACHED THROUGH THE MODULE, not exported. It exists
    # because the progress window runs in a runspace with NO MODULE IN IT (see
    # New-HDTProgressHost, and Get-HDTCommandPromptPath which was extracted for
    # the same reason), so the source has to be handed across as text. One
    # source of truth, two places that need it.
    $script:source = & (Get-Module -Name 'Hephaestus') { Get-HDTWindowForegroundSource }
}

Describe 'Get-HDTWindowForegroundSource' {

    It 'returns something to compile' {
        # Anti-vacuity: every -Match below is trivially true of nothing.
        $script:source | Should -Not -BeNullOrEmpty
        $script:source.Length | Should -BeGreaterThan 400
    }

    It 'names the type in HDT own namespace' {
        # The engine dot-sources user scripts and third-party step types, so an
        # unprefixed public type is a live collision in WinPE (CLAUDE.md rule 3).
        $script:source | Should -Match 'namespace\s+HDT'
        $script:source | Should -Match 'class\s+NativeForeground'
    }

    Context 'the four things that must not be simplified away' {

        It 'drops the foreground lock timeout' {
            # SPI_SETFOREGROUNDLOCKTIMEOUT set to 0 removes Windows own lock.
            # Without it the whole call below is refused before it starts.
            $script:source | Should -Match 'SPI_SETFOREGROUNDLOCKTIMEOUT'
            $script:source | Should -Match 'SystemParametersInfoW'
        }

        It 'taps Alt before it asks for the foreground' {
            # THE ONE THAT LOOKS LIKE NOISE AND IS NOT. SetForegroundWindow is
            # ignored - silently, returning false - unless the calling thread
            # has received input. An Alt down/up is the cheapest way to have
            # received some.
            $script:source | Should -Match 'VK_MENU'
            $script:source | Should -Match 'keybd_event'
        }

        It 'attaches to the foreground thread and detaches again' {
            # AttachThreadInput to whatever currently owns the foreground is
            # what makes the request permissible at all. The detach is the other
            # half: a thread left attached to another process input queue is a
            # machine whose keyboard behaves strangely for the rest of the
            # session, which is a far worse defect than the one being fixed.
            $script:source | Should -Match 'AttachThreadInput'

            $attach = [regex]::Matches($script:source, 'AttachThreadInput\s*\(')
            @($attach).Count | Should -BeGreaterOrEqual 3 -Because (
                'the declaration, the attach and the detach')

            $script:source | Should -Match 'AttachThreadInput\(\s*\w+\s*,\s*\w+\s*,\s*true\s*\)'
            $script:source | Should -Match 'AttachThreadInput\(\s*\w+\s*,\s*\w+\s*,\s*false\s*\)'
        }

        It 'can tap Escape to close an open Start menu' {
            # THE REPORTED SYMPTOM, EXACTLY. A Start menu that is already open
            # when the window appears stays open over it; Escape is what closes
            # one. Optional, because a window raised over a plain taskbar has
            # nothing to dismiss and a stray Escape is a keystroke nobody asked
            # for.
            $script:source | Should -Match 'VK_ESCAPE'
            $script:source | Should -Match 'dismissStart'
        }
    }

    Context 'the half that makes it stay' {

        # THE SECOND SCRIPT, AND THE SECOND HALF. Force gets a window to the
        # front; Raise keeps it there. Topmost="True" only puts a window IN the
        # topmost band, so anything created topmost afterwards lands above it -
        # SetWindowPos with HWND_TOPMOST moves it back to the front of that
        # band. From the user's own Show-UpgradeNotice.ps1.

        It 'reasserts HWND_TOPMOST rather than trusting the markup' {
            $script:source | Should -Match 'SetWindowPos'
            $script:source | Should -Match 'static void Raise'

            # HWND_TOPMOST is -1, and it is the whole argument: any other value
            # re-orders the window inside the ordinary band, where the taskbar
            # is not.
            $script:source | Should -Match 'new IntPtr\(-1\)'
        }

        It 'takes no focus while it does it' {
            # SWP_NOACTIVATE (0x0010) with SWP_NOSIZE and SWP_NOMOVE. Without
            # NOACTIVATE this would steal focus on every tick, from a technician
            # who may be typing in a command prompt they opened with F8.
            $script:source | Should -Match '0x0001\s*\|\s*0x0002\s*\|\s*0x0010'
        }

        It 'does not type on the way' {
            # Raise MUST NOT send a keystroke. It runs on a timer; Force does
            # not. A board tapping Escape four times a second is a machine
            # nobody can use.
            $raise = [regex]::Match($script:source, '(?s)static void Raise.*?\n        \}')

            $raise.Success | Should -BeTrue
            $raise.Value | Should -Not -Match 'keybd_event'
            $raise.Value | Should -Not -Match 'SetForegroundWindow'
        }

        It 'does nothing for a window that has no handle yet' {
            $raise = [regex]::Match($script:source, '(?s)static void Raise.*?\n        \}')

            $raise.Value | Should -Match 'IntPtr\.Zero\)\s*return'
        }
    }

    It 'never assigns the WPF Topmost property' {
        # THE CONTRACT RULE, FROM INSIDE. HDT forbids .Topmost = $true anywhere
        # in src (tests/contract/WinPeWindowReach.Contract.Tests.ps1), and this
        # mechanism does not need it: the one window that re-asserts topmost
        # already declares it in markup and is on that contract's allow-list, so
        # SetWindowPos re-orders something that is already there rather than
        # promoting anything new.
        $script:source | Should -Not -Match '(?i)\.Topmost'
    }
}

Describe 'Set-HDTWindowForeground' {

    It 'has comment based help' {
        (Get-Help -Name 'Set-HDTWindowForeground' -Full).Description | Should -Not -BeNullOrEmpty
    }

    It 'is exported by the manifest' {
        $manifest = Import-PowerShellDataFile -LiteralPath (
            Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1')

        $manifest['FunctionsToExport'] | Should -Contain 'Set-HDTWindowForeground'
    }

    Context 'a handle it cannot act on' {

        It 'reports false rather than throwing' {
            # A WINDOW THAT HAS NO HANDLE YET IS NOT AN ERROR, and it must never
            # be the reason a deployment screen fails to appear. This is the one
            # path that can be executed on a developer machine, because it
            # returns before the first Win32 call - and therefore before any
            # keystroke is injected into whatever the developer is looking at.
            Set-HDTWindowForeground -Handle ([System.IntPtr]::Zero) | Should -BeFalse
        }

        It 'does not throw' {
            { Set-HDTWindowForeground -Handle ([System.IntPtr]::Zero) } | Should -Not -Throw
        }

        It 'does not throw when asked to dismiss the Start menu either' {
            { Set-HDTWindowForeground -Handle ([System.IntPtr]::Zero) -DismissStartMenu } | Should -Not -Throw
        }

        It 'compiles nothing for a handle it will not act on' {
            # The guard is BEFORE Add-Type, which is what makes the test above
            # safe to run at all. If the type has been added by the time the
            # guard returns, the order is wrong.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Set-HDTWindowForeground.ps1'),
                [ref] $null, [ref] $null)

            $addType = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Add-Type'
                    }, $true))

            $return = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.ReturnStatementAst]
                    }, $true))

            @($addType).Count | Should -Be 1
            @($return).Count | Should -BeGreaterThan 0
            @($return | Where-Object { $_.Extent.StartOffset -lt $addType[0].Extent.StartOffset }).Count |
                Should -BeGreaterOrEqual 1 -Because 'the zero-handle guard returns before anything is compiled'
        }
    }
}

Describe 'the windows that ask to be raised' {

    # ASSERTED OVER THE SET, not over the one file that was changed. The rule is
    # "a full-OS deployment screen is raised when it appears", and the two hosts
    # that draw one are both judged.

    BeforeAll {
        $script:hostFile = @('New-HDTWizardHost.ps1', 'New-HDTProgressHost.ps1') | ForEach-Object {
            $path = Join-Path -Path $script:repoRoot -ChildPath ('src/Hephaestus/Public/{0}' -f $_)

            [pscustomobject] @{
                Name = $_
                Path = $path
                # MARKUP WITHOUT ITS PROSE. These files explain the rule by
                # naming the thing it forbids, and a raw scan convicts the file
                # that documented it.
                Code = [regex]::Replace(
                    [regex]::Replace([System.IO.File]::ReadAllText($path), '(?s)<#.*?#>', ''),
                    '(?m)^\s*#.*$', '')
            }
        }
    }

    It 'found both hosts' {
        @($script:hostFile).Count | Should -Be 2
        @($script:hostFile | Where-Object { Test-Path -LiteralPath $_.Path }).Count | Should -Be 2
    }

    It 'raises the window it just opened: <Name>' -ForEach @(
        @{ Name = 'New-HDTWizardHost.ps1' }, @{ Name = 'New-HDTProgressHost.ps1' }
    ) {
        $row = @($script:hostFile | Where-Object { $_.Name -eq $Name })[0]

        # Either through the command, or - in the progress runspace, which has no
        # module in it - through the type the same source compiles to.
        $row.Code | Should -Match 'Set-HDTWindowForeground|HDT.NativeForeground'
    }

    It 'takes the handle from WindowInteropHelper: <Name>' -ForEach @(
        @{ Name = 'New-HDTWizardHost.ps1' }, @{ Name = 'New-HDTProgressHost.ps1' }
    ) {
        # A WPF Window IS NOT AN HWND. There is no Handle property on it, and
        # the interop helper is the only way to the window the shell competes
        # with - passing anything else raises nothing and reports nothing wrong.
        $row = @($script:hostFile | Where-Object { $_.Name -eq $Name })[0]

        $row.Code | Should -Match 'WindowInteropHelper'
    }

    It 'forces the foreground on an event and never on a timer: <Name>' -ForEach @(
        @{ Name = 'New-HDTWizardHost.ps1'; Limit = 2 }, @{ Name = 'New-HDTProgressHost.ps1'; Limit = 1 }
    ) {
        # FORCE TYPES, SO FORCE IS WIRED TO EVENTS AND NEVER TO A CLOCK. It
        # injects an Escape and an Alt, and those go to whatever has focus - a
        # board doing that four times a second is a machine nobody can use, and
        # it would fight the command prompt F8 opens.
        #
        # TWO IS THE SUMMARY SCREEN'S NUMBER, NOT A RELAXATION. ContentRendered
        # puts it in front when it appears; Deactivated puts it back when the
        # Start menu takes the foreground away, which is the one competitor
        # nothing in the topmost band can outrank. Both are activation changes
        # the technician caused. The progress board keeps one, because staying
        # in front is Raise's job there and Raise sends nothing.
        $row = @($script:hostFile | Where-Object { $_.Name -eq $Name })[0]

        $call = [regex]::Matches($row.Code, 'Set-HDTWindowForeground|HDT\.NativeForeground\]::Force')
        @($call).Count | Should -BeLessOrEqual $Limit -Because (
            'every force is wired to a window event, not to a tick')

        $row.Code | Should -Match 'Add_ContentRendered'
    }

    Context 'the board that has to stay in front' {

        # THE SECOND HALF GOES TO THE PROGRESS BOARD AND ONLY THERE, and the
        # asymmetry is the whole point rather than an oversight.
        #
        # HDTProgress.xaml already declares Topmost="True" and is the ONE name
        # on the allow-list in
        # tests/contract/WinPeWindowReach.Contract.Tests.ps1. Re-asserting
        # HWND_TOPMOST on it re-orders a window that is already in that band; it
        # promotes nothing.
        #
        # THE DEPLOYMENT SUMMARY DOES NOT GET IT, DELIBERATELY. That window's
        # Open CMD button and its F8 hand the machine to a command prompt, and
        # F8 leaves the window OPEN - so a summary screen re-asserting topmost
        # every tick would sit on top of the prompt it had just launched, which
        # is the exact defect HDTFailure.xaml lost its Topmost attribute over.
        # It gets the one-shot foreground force instead: in front when it
        # appears, and it lets go the moment the technician opens anything.

        It 'keeps the progress board at the front of the band' {
            $row = @($script:hostFile | Where-Object { $_.Name -eq 'New-HDTProgressHost.ps1' })[0]

            $row.Code | Should -Match 'HDT\.NativeForeground\]::Raise'
            $row.Code | Should -Match 'Add_Deactivated' -Because 'losing the foreground is when it matters most'
            $row.Code | Should -Match 'Add_Tick'
        }

        It 'never re-asserts topmost on the window a technician answers' {
            $row = @($script:hostFile | Where-Object { $_.Name -eq 'New-HDTWizardHost.ps1' })[0]

            $row.Code | Should -Not -Match 'Raise' -Because (
                'the Deployment Summary opens a command prompt and must not outrank it')
        }

        It 'assigns the WPF Topmost property nowhere' {
            # The contract rule, restated where the change was made. Re-ordering
            # inside the band is SetWindowPos; promoting a window into it would
            # be .Topmost = $true, and that stays forbidden.
            foreach ($row in $script:hostFile) {
                $row.Code | Should -Not -Match '\.Topmost\s*=\s*\$true'
            }
        }

        It 'survives a compiler it does not have' {
            # GRACEFUL, NEVER FATAL. A boot image whose Add-Type cannot compile
            # still gets the window - Topmost in the markup alone - because a
            # board slightly in the wrong place beats no board at all, and this
            # runs on the one machine nobody can debug.
            $row = @($script:hostFile | Where-Object { $_.Name -eq 'New-HDTProgressHost.ps1' })[0]

            $row.Code | Should -Match '(?s)Add-Type -TypeDefinition \$HDTForegroundSource.*?\}\s*catch'
        }
    }

    Context 'the window that gets the foreground taken away' {

        # THE START MENU IS NOT IN THE TOPMOST BAND - IT IS ABOVE IT. A deployed
        # machine photographed after a successful run had the Start menu drawn
        # straight over the Deployment Summary: the heading, the log path and
        # the Open CMD button all occluded. Re-asserting HWND_TOPMOST cannot
        # reach it, because the flyout is an ApplicationFrameWindow / XAML host
        # surface that sits over the whole band.
        #
        # MDT'S ANSWER IS TO REMOVE THE COMPETITOR - LiteTouch runs from HKLM
        # RunOnce with AsyncRunOnce=0 so Explorer draws no shell at all until
        # the leg finishes. HDT DELIBERATELY DID NOT TAKE THAT ROUTE: it also
        # removes the taskbar, which nobody complained about, and a restore that
        # fails leaves a machine with no shell - far worse than a summary behind
        # a flyout.
        #
        # WHAT IS LEFT IS TIMING. Force already dismisses an open Start menu
        # with an Escape; it just ran once, at show time, so a Start menu opened
        # a second later won. Deactivated is exactly the moment it is needed.

        BeforeAll {
            $script:summaryAst = [System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/New-HDTWizardHost.ps1'),
                [ref] $null, [ref] $null)

            $script:summaryHandler = {
                param([string] $HandlerName)

                @($script:summaryAst.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                            $node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                            $node.Member.Value -eq $HandlerName
                        }, $true))
            }
        }

        It 'wires every raised window to losing the foreground' {
            # OVER THE SET. The rule is not "the summary screen got a handler";
            # it is that a full-OS deployment screen which fights for the front
            # answers the moment it loses it. Both hosts draw one, so both are
            # judged - and the next window somebody raises is judged too.
            foreach ($row in $script:hostFile) {
                $row.Code | Should -Match 'Add_Deactivated' -Because (
                    '{0} raises a window, so it must answer when something takes the front' -f $row.Name)
            }
        }

        It 'dismisses the Start menu when it takes the front' {
            $handler = & $script:summaryHandler 'Add_Deactivated'

            @($handler).Count | Should -BeGreaterOrEqual 1
            @($handler | Where-Object { $_.Extent.Text -match 'DismissStartMenu' }).Count |
                Should -BeGreaterOrEqual 1 -Because 'nothing but an Escape closes an open Start menu'
        }

        It 'ignores a deactivation while a force is already in flight' {
            # RE-ENTRANCY, AND IT IS NOT THEORETICAL. Force taps Alt, and an Alt
            # is an activation change in its own right - so the handler that
            # sends it can be the reason it is called again. A flag checked
            # before the force and cleared in a finally is what stops the window
            # ping-ponging with the shell.
            $handler = & $script:summaryHandler 'Add_Deactivated'
            $text = ($handler | ForEach-Object { $_.Extent.Text }) -join "`n"

            $text | Should -Match 'Busy'
            $text | Should -Match '(?s)Busy.*?finally'
        }

        It 'stops re-forcing once the technician has opened a prompt' {
            # THE EXEMPTION, AND IT IS A BLOCKER WITHOUT IT. F8 on this window
            # opens a command prompt and LEAVES THE WINDOW UP - so a summary
            # that forced itself back on every deactivation would yank the
            # foreground off the prompt it had just launched, one keystroke into
            # whatever the technician was typing. The prompt wins from then on.
            $handler = & $script:summaryHandler 'Add_Deactivated'
            $text = ($handler | ForEach-Object { $_.Extent.Text }) -join "`n"

            $text | Should -Match 'Suppressed'

            $key = & $script:summaryHandler 'Add_PreviewKeyDown'
            @($key | Where-Object { $_.Extent.Text -match 'Suppressed' }).Count |
                Should -BeGreaterOrEqual 1 -Because 'F8 is what opens the prompt that must keep the front'
        }

        It 'lets go for good once a button has been answered' {
            # Open CMD closes the window, and a closing window still raises
            # Deactivated. Answering anything sets the same flag, so the summary
            # never fights for a front it is about to give up.
            $click = & $script:summaryHandler 'Add_Click'

            @($click | Where-Object { $_.Extent.Text -match 'Suppressed' }).Count |
                Should -BeGreaterOrEqual 1
        }

        It 'still never re-asserts topmost' {
            # UNCHANGED, AND CHECKED HERE BECAUSE THIS IS THE CHANGE THAT WOULD
            # HAVE BEEN TEMPTED. Deactivated + Force is not Deactivated + Raise:
            # Force lets go the instant anything else is activated, which is
            # what keeps the Open CMD prompt usable.
            $row = @($script:hostFile | Where-Object { $_.Name -eq 'New-HDTWizardHost.ps1' })[0]

            $row.Code | Should -Not -Match 'Raise'
            $row.Code | Should -Not -Match 'Add_Tick'
        }
    }
}
