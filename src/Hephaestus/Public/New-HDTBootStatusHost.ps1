function New-HDTBootStatusHost {
    <#
        .SYNOPSIS
            The real IBootStatusHost: runs the boot status overlay in its own
            runspace.

        .DESCRIPTION
            THIS IS AN ADAPTER OVER AN EXTERNAL TOOL AND IS DELIBERATELY THIN.
            CLAUDE.md rule 1's only exception to TDD is a thin adapter over
            something that cannot be faked - here WPF and the PowerShell runspace
            API - and THE PRICE OF THAT EXEMPTION IS THAT THE ADAPTER MUST HAVE
            NOTHING IN IT WORTH TESTING. Whether there should be a window at all
            is Start-HDTBootStatus's decision; what the lines say is the
            payload's. What is left here is: start a runspace, load markup, set
            text by name, and tear it down.

            THE WINDOW RUNS IN ITS OWN RUNSPACE, for the reason
            New-HDTProgressHost's does: a WPF window owns the thread it was
            created on for as long as it is open - a message loop does not
            return - so a window on the payload's thread would be a deployment
            that stopped at step 4a and drew a status board about it forever.

            SO Write DOES NOT TOUCH THE WINDOW. It appends to a synchronised
            hashtable the two runspaces share, and the UI thread's own
            DispatcherTimer reads it. Reaching across a thread to a
            DependencyObject throws InvalidOperationException in WPF, and doing
            it through Dispatcher.Invoke would block the deployment on rendering.

            THE TAIL IS BOUNDED. The overlay shows the last few lines and no
            more: it is a panel in the middle of a wallpaper, not a scrollback,
            and one that grew until it covered the screen would undo the only
            reason this window exists. The whole account is in the log either
            way.

            IT IS NARROWED TO FIT, which is the one piece of arithmetic in this
            file and is here on purpose. The window used to be WindowState=
            "Maximized" so that nothing had to compute anything - and on a booted
            VM its lines drew across the Welcome screen's credential fields. The
            markup asks for 940 wide; a screen narrower than that gets a window
            that fits it rather than one that runs off both edges.
            CenterScreen does the placing, so there is no Left or Top to get
            wrong.

            F8 IS WIRED HERE, AND ON THIS WINDOW IT MATTERS MOST. The payload
            hides the WinPE console once this is up, so for the twenty seconds
            before the Welcome screen this is the ONLY window on the machine and
            the only way a technician can reach a prompt. It takes a PATH rather
            than a command: this runspace has no Hephaestus module in it, and
            importing one on a RAM disk to answer a keypress would cost the
            deployment seconds it does not owe.

            NOTHING HERE THROWS INTO THE PAYLOAD. Open is allowed to - that is
            how a machine with no WinPE-NetFx reports itself, and
            Start-HDTBootStatus catches it and leaves the console alone - but
            Write and Close are called from a running deployment, where an
            exception would take the deployment with it.

            THE TWO STRINGS ON THE WINDOW ARE HANDED IN, NOT WRITTEN IN THE
            MARKUP. Start-HDTBootStatus reads them from Strings\en-us.psd1 and
            passes the block; this walks it and sets each Control.Property by
            name. Set-HDTWindowText is what does that everywhere else, and it
            cannot be used here: this runspace has no Hephaestus module in it.

        .PARAMETER LineCount
            How many lines of history the panel keeps.

            IT MUST BE THE ONLY WINDOW ON SCREEN, AND THAT IS A PROPERTY OF
            WinPE RATHER THAN A CHOICE. WinPE runs no desktop compositor, so a
            TRANSPARENT window's repaint goes to the screen without being clipped
            by whatever is above it: on a booted VM this panel's lines were drawn
            across the Welcome screen's share box and credential fields. Two
            frames measured it - an OPAQUE cmd.exe window covered the panel
            completely, while the Welcome screen, opened before the panel's next
            repaint, was bled through the instant it repainted.

            THREE FIXES WERE TRIED IN THE PAYLOAD BEFORE THAT WAS UNDERSTOOD, and
            each bought a worse defect: closing it before each window destroyed
            the only thing that reports anything, so pressing Next gave five share
            connection attempts on a blank wallpaper; hiding it instead was worse,
            because the window was modal and hiding a ShowDialog window MAKES
            ShowDialog RETURN, so the panel was destroyed and never came back;
            and SetWindowPos(HWND_BOTTOM) did nothing, because z-order was never
            what was being violated.

            SO THE PAYLOAD CLOSES THIS AND OPENS IT AGAIN around every window it
            shows, replaying the history into the new one. There is no Hide, no
            Show and no z-order call here, because none of them is a thing this
            window can do about it.

        .OUTPUTS
            A PSCustomObject with Open(xaml, commandPromptPath, text),
            Write(line) and Close().

        .EXAMPLE
            $statusHost = New-HDTBootStatusHost
            $statusHost.Open('Starting the deployment')

            The boot status panel WinPE shows before anything else is on screen.

        .EXAMPLE
            $statusHost.Write('Waiting for an address')
            $statusHost.Close()

            One line at a time. This is the adapter; Start-HDTBootStatus is the
            command, and it decides whether there should be a panel at all.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state. Open is where a window appears, and it is a method.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # HOW MANY LINES OF HISTORY THE PANEL KEEPS. Bounded for the reason the
        # header gives: this is a corner of a wallpaper, not a scrollback.
        [Parameter()]
        [ValidateRange(1, 40)]
        [int] $LineCount = 12
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE ONE THING BOTH THREADS TOUCH. Synchronized, because the payload writes
    # it on its thread and the UI's DispatcherTimer reads it on the other.
    $shared = [hashtable]::Synchronized(@{
            Current = ''
            Tail    = ''
            Closing = $false
        })

    $service = [pscustomobject] @{
        Shared    = $shared
        LineCount = $LineCount
        Line      = (New-Object -TypeName System.Collections.ArrayList)
        Runspace  = $null
        Handle    = $null
        Shell     = $null
    }

    $service | Add-Member -MemberType ScriptMethod -Name Open -Value {
        param([string] $Xaml, [string] $CommandPromptPath, [hashtable] $Text)

        # THE PLACEHOLDER THE WINDOW OPENS ON. The timer below writes Current on
        # every tick, so a value the markup carried would be gone in 250ms; this
        # is where the table's version of it survives until the first real line.
        $seed = ''
        if ($null -ne $Text -and $Text.ContainsKey('HDTBootStatusCurrent.Text')) {
            $seed = [string] $Text['HDTBootStatusCurrent.Text']
        }

        $this.Shared['Current'] = $seed

        $runspace = [runspacefactory]::CreateRunspace()

        # STA IS NOT OPTIONAL. WPF refuses to create a window on an MTA thread,
        # and the payload's own runspace is whatever the host gave it.
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()

        $runspace.SessionStateProxy.SetVariable('HDTShared', $this.Shared)
        $runspace.SessionStateProxy.SetVariable('HDTXaml', $Xaml)
        $runspace.SessionStateProxy.SetVariable('HDTCommandPromptPath', $CommandPromptPath)
        $runspace.SessionStateProxy.SetVariable('HDTText', $Text)

        $shell = [powershell]::Create()
        $shell.Runspace = $runspace

        [void] $shell.AddScript({
                Add-Type -AssemblyName PresentationFramework
                Add-Type -AssemblyName PresentationCore
                Add-Type -AssemblyName WindowsBase


                $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $HDTXaml)
                $window = [System.Windows.Markup.XamlReader]::Load($reader)

                # NARROWED TO WHATEVER SCREEN THIS MACHINE HAS. A WinPE VM comes
                # up 1024x768 and a bench machine 1920x1080; CenterScreen places
                # it either way, but a 940-wide window on an 800-wide screen
                # would hang off both sides of the middle.
                $limit = [double] [System.Windows.SystemParameters]::PrimaryScreenWidth - 64
                if ($window.Width -gt $limit) { $window.Width = $limit }

                # THE STRING TABLE, APPLIED BY NAME. Set-HDTWindowText's walk,
                # inlined because this runspace has no module to call it from.
                foreach ($key in @($HDTText.Keys)) {
                    $target = [string] $key
                    $split = $target.LastIndexOf('.')
                    if ($split -lt 1) { continue }

                    # THE NAME GOES IN A VARIABLE, which is Set-HDTWindowText's
                    # shape and not a preference: $element.($expression) is what
                    # PSScriptAnalyzer reads as an empty member invocation.
                    $property = $target.Substring($split + 1)

                    $element = $window.FindName($target.Substring(0, $split))
                    if ($null -eq $element) { continue }

                    $element.$property = [string] $HDTText[$key]
                }

                $current = $window.FindName('HDTBootStatusCurrent')
                $lines = $window.FindName('HDTBootStatusLines')

                # THE UI PULLS; THE PAYLOAD NEVER PUSHES. Four ticks a second is
                # below anything a technician perceives as lag and above anything
                # that costs a deployment measurable time.
                $timer = New-Object -TypeName System.Windows.Threading.DispatcherTimer
                $timer.Interval = [TimeSpan]::FromMilliseconds(250)
                $timer.Add_Tick({
                        if ($HDTShared['Closing']) {
                            $timer.Stop()
                            $window.Close()

                            # AND THE LOOP BELOW ENDS WITH IT. Close() on a
                            # non-modal window tears down the window and leaves
                            # Dispatcher::Run spinning on a thread with nothing
                            # to draw, which is a runspace the payload waits five
                            # seconds for and then abandons.
                            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
                            return
                        }

                        $current.Text = [string] $HDTShared['Current']
                        $lines.Text = [string] $HDTShared['Tail']
                    }.GetNewClosure())
                $timer.Start()

                # F8, AND THIS IS THE WINDOW IT MATTERS MOST ON: the console is
                # hidden behind it and there is no other way to a prompt.
                #
                # SWALLOWED, ALWAYS. This runs on the UI thread of a window the
                # payload cannot see; an exception here would take the overlay
                # down over a keystroke and leave a machine deploying behind a
                # blank wallpaper.
                $window.Add_PreviewKeyDown({
                        if ($_.Key -ne [System.Windows.Input.Key]::F8) { return }

                        $_.Handled = $true

                        try {
                            [void] (Start-Process -FilePath $HDTCommandPromptPath -ErrorAction Stop)
                        } catch {
                            # Kept where a debugger can reach it rather than
                            # thrown away: an empty catch is how a key that never
                            # worked stays a mystery.
                            $HDTShared['CommandPromptError'] = [string] $_.Exception.Message
                        }
                    })

                # Show() AND A DISPATCHER LOOP, NOT ShowDialog(). ShowDialog
                # owns the thread until the window goes away, and Close() here is
                # a flag the timer reads rather than a call from outside - which
                # a modal dialog makes awkward for no gain. Show() puts it up
                # without blocking; Dispatcher::Run keeps a message loop on this
                # thread so the timer ticks.
                $window.Show()
                [System.Windows.Threading.Dispatcher]::Run()
            })

        $this.Runspace = $runspace
        $this.Shell = $shell
        $this.Handle = $shell.BeginInvoke()
    }

    $service | Add-Member -MemberType ScriptMethod -Name Write -Value {
        param([string] $Line)

        # A HANDOFF, NOT A RENDER. See the header: touching the window from this
        # thread throws, and marshalling to it would block the deployment.
        try {
            if ([string]::IsNullOrWhiteSpace($Line)) { return }

            [void] $this.Line.Add($Line)

            while ($this.Line.Count -gt $this.LineCount) { $this.Line.RemoveAt(0) }

            $this.Shared['Current'] = $Line

            # THE LINE THAT IS CURRENT IS NOT REPEATED IN THE TAIL. It is already
            # on screen, larger, one control up.
            $history = @($this.Line)
            if ($history.Count -gt 1) {
                $this.Shared['Tail'] = (@($history[0..($history.Count - 2)]) -join "`r`n")
            } else {
                $this.Shared['Tail'] = ''
            }
        } catch {
            # A deployment does not stop because a status board did not update.
            Write-Verbose ("the boot status overlay could not be updated: {0}" -f [string] $_.Exception.Message)
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name Close -Value {

        # THE FLAG, NOT Window.Close(). The window belongs to the other thread,
        # and its own timer is what may close it.
        try {
            $this.Shared['Closing'] = $true

            if ($null -ne $this.Handle -and $null -ne $this.Shell) {
                # Bounded, because a UI thread that will not end must not become
                # a deployment that will not end.
                [void] $this.Handle.AsyncWaitHandle.WaitOne(5000)
                $this.Shell.Dispose()
            }

            if ($null -ne $this.Runspace) { $this.Runspace.Dispose() }
        } catch {
            Write-Verbose ("the boot status overlay could not be closed cleanly: {0}" -f [string] $_.Exception.Message)
        }
    }

    return $service
}
