function New-HDTProgressHost {
    <#
        .SYNOPSIS
            The real IProgressHost: runs DESIGN 11.1's progress window in its
            own runspace.

        .DESCRIPTION
            THIS IS AN ADAPTER OVER AN EXTERNAL TOOL AND IS DELIBERATELY THIN.
            CLAUDE.md rule 1's only exception to TDD is a thin adapter over
            something that cannot be faked - here WPF and the PowerShell
            runspace API - and THE PRICE OF THAT EXEMPTION IS THAT THE ADAPTER
            MUST HAVE NOTHING IN IT WORTH TESTING. Every decision lives
            elsewhere: Get-HDTDeploymentProgress works out what the numbers are,
            Start-HDTProgressDisplay decides whether there should be a window at
            all. What is left here is: start a runspace, load markup, set text
            by name, and tear it down.

            THE ONE NUMBER THIS WORKS OUT ITSELF IS THE CLOCK, and it has to be
            here because it is the one fact the log cannot supply: how long the
            current step has been running is UtcNow minus the step's start time,
            and only something holding a clock can ask. It is a subtraction and
            a format string on a timer that was already ticking - see the timer
            below - which is small enough to stay inside the exemption, and the
            derivation it replaced is remembered in Get-HDTDeploymentProgress
            and in the markup because it froze on a real deployment.

            THE WINDOW RUNS IN ITS OWN RUNSPACE, and DESIGN 11.1 requires it in
            those words: "The engine must never block on rendering, and a UI
            fault must not take the deployment with it." A WPF window owns the
            thread it was created on for as long as it is open - ShowDialog does
            not return - so a window on the engine's thread would be a
            deployment that stopped at the first step and drew a progress bar
            about it forever.

            SO Update DOES NOT TOUCH THE WINDOW. It writes into a synchronised
            hashtable the two runspaces share, and the UI thread's own
            DispatcherTimer reads it. Reaching across a thread to a
            DependencyObject throws InvalidOperationException in WPF, and doing
            it through Dispatcher.Invoke would block the engine on the very
            rendering DESIGN 11.1 says it must never block on.

            NOTHING HERE THROWS INTO THE ENGINE. Open is allowed to - that is
            how a machine with no WinPE-NetFx reports itself, and
            Start-HDTProgressDisplay catches it and falls back to the console -
            but Update and Close are called from a running deployment, where an
            exception would take the deployment with it. They swallow, because a
            progress bar that stopped a build would be worse than no progress
            bar at all.

        .OUTPUTS
            A PSCustomObject with Open(xaml), Update(progress) and Close().

        .EXAMPLE
            $display = Start-HDTProgressDisplay -XamlPath 'X:\HDT\UI\HDTProgress.xaml'
            $display.Shown

            Start-HDTProgressDisplay builds this host itself and decides whether
            there should be a window at all, which is why an administrator never
            types this command.

        .EXAMPLE
            $progressHost = New-HDTProgressHost
            $progressHost.Stop()

            The adapter on its own, started and torn down. Update writes into a
            synchronised hashtable the two runspaces share - it never touches the
            window, because reaching across a thread to a WPF object throws.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a stateless service adapter object; it changes no state. Open is where a window appears, and it is a method.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE ONE THING BOTH THREADS TOUCH. Synchronized, because the engine writes
    # it on its thread and the UI's DispatcherTimer reads it on the other.
    $shared = [hashtable]::Synchronized(@{
            Progress     = $null
            ComputerName = ''
            Closing      = $false

            # THE WINDOW'S HWND, once it has one. A WPF Window is not a window
            # handle: it gets one only when it is sourced, which is why this is
            # filled in on ContentRendered and starts as zero. The timer below
            # reads it to keep the board at the front of the topmost band.
            Hwnd         = [System.IntPtr]::Zero
        })

    $service = [pscustomobject] @{
        Shared   = $shared
        Runspace = $null
        Handle   = $null
        Shell    = $null
    }

    $service | Add-Member -MemberType ScriptMethod -Name Open -Value {
        param([string] $Xaml, [string] $CommandPromptPath)

        $runspace = [runspacefactory]::CreateRunspace()

        # STA IS NOT OPTIONAL. WPF refuses to create a window on an MTA thread,
        # and the engine's own runspace is whatever the host gave it.
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()

        $runspace.SessionStateProxy.SetVariable('HDTShared', $this.Shared)
        $runspace.SessionStateProxy.SetVariable('HDTXaml', $Xaml)

        # THE PATH, NOT THE COMMAND. This runspace has no Hephaestus module in
        # it - importing one on a RAM disk to answer a keypress would cost the
        # deployment seconds it does not owe - so F8 below starts a file, and
        # Get-HDTCommandPromptPath decided which file on the engine's side.
        $runspace.SessionStateProxy.SetVariable('HDTCommandPromptPath', $CommandPromptPath)

        # THE SOURCE, FOR THE SAME REASON THE PATH IS A PATH. This runspace has
        # no module in it, so it cannot call Set-HDTWindowForeground; it gets the
        # C# handed across and compiles it there. One source of truth rather than
        # the same P/Invoke block written out twice and drifting.
        $runspace.SessionStateProxy.SetVariable('HDTForegroundSource', (Get-HDTWindowForegroundSource))

        $shell = [powershell]::Create()
        $shell.Runspace = $runspace

        [void] $shell.AddScript({
                Add-Type -AssemblyName PresentationFramework
                Add-Type -AssemblyName PresentationCore
                Add-Type -AssemblyName WindowsBase

                $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList ([xml] $HDTXaml)
                $window = [System.Windows.Markup.XamlReader]::Load($reader)

                $computerName = $window.FindName('HDTProgressComputerName')
                $sequenceName = $window.FindName('HDTProgressSequenceName')
                $phase = $window.FindName('HDTProgressPhase')
                $stepName = $window.FindName('HDTProgressStepName')
                $activity = $window.FindName('HDTProgressActivity')
                $stepGroup = $window.FindName('HDTProgressStepGroup')
                $stepCounter = $window.FindName('HDTProgressStepCounter')
                $bar = $window.FindName('HDTProgressBar')
                $stepBar = $window.FindName('HDTProgressStepBar')
                $stepPercent = $window.FindName('HDTProgressStepPercent')
                $status = $window.FindName('HDTProgressStatus')
                $elapsed = $window.FindName('HDTProgressElapsed')

                # THE UI PULLS; THE ENGINE NEVER PUSHES. Four ticks a second is
                # far below anything a technician perceives as lag and far above
                # anything that costs a deployment measurable time.
                #
                # AND IT IS WHAT MAKES THE CLOCK A CLOCK. The elapsed below is
                # not read out of the progress object - it is UtcNow minus the
                # step's start time, worked out here, on this tick, whether or
                # not the engine has said anything since the last one. One timer
                # rather than a second at one second: this one is already
                # repainting the card, and a clock rendered four times a second
                # instead of once costs a string format nobody can measure.
                $timer = New-Object -TypeName System.Windows.Threading.DispatcherTimer
                $timer.Interval = [TimeSpan]::FromMilliseconds(250)
                $timer.Add_Tick({
                        if ($HDTShared['Closing']) {
                            $timer.Stop()
                            $window.Close()
                            return
                        }

                        # BACK TO THE FRONT OF THE TOPMOST BAND, EVERY TICK, and
                        # BEFORE the early return below - a board with nothing
                        # to report yet is still a board that must be visible.
                        #
                        # Topmost="True" in the markup only puts this window IN
                        # the topmost band; anything created topmost after it
                        # lands above. This is the user's own mechanism from
                        # Show-UpgradeNotice.ps1, and their comment is the
                        # justification: doing it this often means a window that
                        # opened above us is in front for one tick and no more.
                        # SWP_NOACTIVATE, so it takes no focus - and it is Raise
                        # and never Force, because Force types.
                        try {
                            if ($HDTShared['Hwnd'] -ne [System.IntPtr]::Zero) {
                                [HDT.NativeForeground]::Raise($HDTShared['Hwnd'])
                            }
                        } catch {
                            $HDTShared['ForegroundError'] = [string] $_.Exception.Message
                        }

                        $progress = $HDTShared['Progress']
                        if ($null -eq $progress) { return }

                        $computerName.Text = [string] $HDTShared['ComputerName']
                        $sequenceName.Text = [string] $progress.SequenceId
                        $phase.Text = [string] $progress.Phase
                        $stepName.Text = [string] $progress.StepName
                        $stepGroup.Text = [string] $progress.StepType
                        $status.Text = [string] $progress.Status

                        # THE SEVERITY GOES IN Tag AND THE MARKUP PAINTS IT, the
                        # same split the wizard's message line uses.
                        $status.Tag = [string] $progress.Status

                        if ([int] $progress.StepCount -gt 0) {
                            $stepCounter.Text = 'Step {0} of {1}' -f [int] $progress.StepNumber, [int] $progress.StepCount
                        } else {
                            $stepCounter.Text = 'Step {0}' -f [int] $progress.StepNumber
                        }

                        $bar.Value = [int] $progress.PercentComplete

                        # THE STEP'S OWN BAR, AND IT IS THERE ONLY WHILE
                        # SOMETHING IS REPORTING. Most steps take a second and
                        # say nothing about themselves; an empty bar under every
                        # one of them is a control that looks broken. An apply
                        # says something every five points, and for nine minutes
                        # it is the only thing on this card that changes.
                        $stepValue = [int] $progress.StepPercent
                        $stepBar.Value = $stepValue

                        if ($stepValue -gt 0) {
                            $stepBar.Visibility = [System.Windows.Visibility]::Visible
                            $stepPercent.Text = '{0}%' -f $stepValue
                        } else {
                            $stepBar.Visibility = [System.Windows.Visibility]::Collapsed
                            $stepPercent.Text = ''
                        }

                        # WHICH ONE OF THE MANY - "installing 1 of 2: Acrobat
                        # Acrobat Reader DC", or a heartbeat's "still running
                        # after 45s". Blank between steps, and the markup keeps
                        # the line's height so the card does not breathe.
                        $activity.Text = [string] $progress.Activity

                        # THE CLOCK. UtcNow minus the step's start, worked out on
                        # every tick - see the timer's own comment above and the
                        # long note in the markup for the frozen clock this
                        # replaced and the backwards jump that is still real.
                        #
                        # $null IS "NO STEP YET" and shows 00:00:00 rather than
                        # nothing: this is a board a technician reads from
                        # across a room, and a field that appears once the first
                        # step starts is a field that looks broken until then.
                        #
                        # NEGATIVE IS CLAMPED. WinPE corrects its clock mid-run,
                        # and a correction landing between the step's start and
                        # this subtraction would otherwise render as a huge hour
                        # count on the wall of a room somebody is deploying in.
                        $span = [timespan]::Zero

                        if ($null -ne $progress.StepStartTime) {
                            $span = [datetime]::UtcNow - ([datetime] $progress.StepStartTime)
                            if ($span.Ticks -lt 0) { $span = [timespan]::Zero }
                        }

                        $elapsed.Text = '{0:00}:{1:00}:{2:00} in this step' -f
                        [int] $span.TotalHours, $span.Minutes, $span.Seconds
                    }.GetNewClosure())
                $timer.Start()

                # F8, AND THIS IS THE ONE THAT MATTERS. MDT's "Enable command
                # support (testing only)" is remembered for exactly this moment:
                # a deployment is running, something is wrong, and a technician
                # wants a prompt to go and look at a log WITHOUT stopping it.
                #
                # THIS WINDOW HAS NO BUTTONS BY DESIGN - it is a status board,
                # not a dialog - so F8 is the only way in and out is closing the
                # prompt. The deployment is untouched either way: nothing here
                # cancels, answers or closes the window.
                #
                # SWALLOWED, ALWAYS. This runs on the UI thread of a window the
                # engine cannot see; an exception here would take the progress
                # display down mid-deployment over a keystroke, and the machine
                # would finish deploying behind a dead screen.
                $window.Add_PreviewKeyDown({
                        if ($_.Key -ne [System.Windows.Input.Key]::F8) { return }

                        $_.Handled = $true

                        try {
                            [void] (Start-Process -FilePath $HDTCommandPromptPath -ErrorAction Stop)
                        } catch {
                            # Nothing to tell anybody with: this window has no
                            # message line, and the log belongs to the engine.
                            # The reason is kept where a debugger can reach it
                            # rather than thrown away, because an empty catch is
                            # how a key that never worked stays a mystery.
                            $HDTShared['CommandPromptError'] = [string] $_.Exception.Message
                        }
                    })

                # AND THE BOARD COMES TO THE FRONT AS IT APPEARS.
                #
                # THIS WINDOW OUTLIVES WinPE. In WinPE there is no shell to
                # compete with - cmd.exe is it - but the full-OS leg draws this
                # board on a real DESKTOP, under an autologon, and a deployed
                # machine showed the taskbar and the Start menu opening straight
                # over it. HDTProgress.xaml is Topmost, which handles the
                # passive case; it does NOT handle a Start menu that is already
                # open, because the taskbar is topmost too and the two are peers.
                # This is the other half.
                #
                # ONCE, ON ContentRendered, NEVER ON THE TIMER ABOVE. F8 on this
                # window opens a command prompt, and a board that re-raised
                # itself every tick would sit on top of it - the exact defect
                # HDTFailure.xaml lost its Topmost attribute over.
                #
                # SWALLOWED, LIKE F8 ABOVE. This runs on the UI thread of a
                # window the engine cannot see; an exception here would take the
                # progress display down mid-deployment over a z-order.
                $window.Add_ContentRendered({
                        try {
                            if (-not ([System.Management.Automation.PSTypeName]'HDT.NativeForeground').Type) {
                                Add-Type -TypeDefinition $HDTForegroundSource
                            }

                            $HDTShared['Hwnd'] = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle

                            if ($HDTShared['Hwnd'] -ne [System.IntPtr]::Zero) {
                                # Both halves, in order: get to the front, then
                                # to the front OF the topmost band.
                                [HDT.NativeForeground]::Force($HDTShared['Hwnd'], $true)
                                [HDT.NativeForeground]::Raise($HDTShared['Hwnd'])
                            }
                        } catch {
                            # GRACEFUL, NEVER FATAL. A boot image whose Add-Type
                            # cannot compile still gets the window - Topmost in
                            # the markup alone - and a board slightly in the
                            # wrong place beats no board at all.
                            $HDTShared['Hwnd'] = [System.IntPtr]::Zero
                            $HDTShared['ForegroundError'] = [string] $_.Exception.Message
                        }
                    })

                # AND IT GOES BACK TO THE FRONT WHEN SOMETHING TAKES IT, which
                # is the other half of the user's own mechanism
                # (Show-UpgradeNotice.ps1). SWP_NOACTIVATE, so this steals no
                # focus and no keystrokes - it only re-orders. Note it does NOT
                # call Force: that one types, and a board typing an Escape every
                # time the technician clicked elsewhere would be unusable.
                $window.Add_Deactivated({
                        try {
                            if ($HDTShared['Hwnd'] -ne [System.IntPtr]::Zero) {
                                [HDT.NativeForeground]::Raise($HDTShared['Hwnd'])
                            }
                        } catch {
                            $HDTShared['ForegroundError'] = [string] $_.Exception.Message
                        }
                    })

                [void] $window.ShowDialog()
            })

        $this.Runspace = $runspace
        $this.Shell = $shell
        $this.Handle = $shell.BeginInvoke()
    }

    $service | Add-Member -MemberType ScriptMethod -Name Update -Value {
        param([object] $Progress)

        # A HANDOFF, NOT A RENDER. See the header: touching the window from this
        # thread throws, and marshalling to it would block the engine.
        try {
            $this.Shared['Progress'] = $Progress
        } catch {
            # A deployment does not stop because a status board did not update.
            Write-Verbose ("the progress window could not be updated: {0}" -f [string] $_.Exception.Message)
        }
    }

    $service | Add-Member -MemberType ScriptMethod -Name SetComputerName -Value {
        param([string] $Name)

        # NOT IN THE EVENT STREAM. Every other value on screen is derived from
        # the log; the machine's own name is a variable, and the caller has it.
        $this.Shared['ComputerName'] = $Name
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
            Write-Verbose ("the progress window could not be closed cleanly: {0}" -f [string] $_.Exception.Message)
        }
    }

    return $service
}
