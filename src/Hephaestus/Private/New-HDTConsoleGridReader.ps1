function New-HDTConsoleGridReader {
    <#
        .SYNOPSIS
            Reads driver rows off the dispatcher, in a runspace the window owns.

        .DESCRIPTION
            SELECTING A DRIVER FOLDER FROZE THE CONSOLE FOR TWO SECONDS, every
            time, because the grid was filled by calling Get-HDTConsoleDriverRow
            straight from the selection handler. An administrator clicking
            'Dell inc' and then 'WinPE' waits twice, and a window that ignores
            the mouse is a window that gets reported as hung - which is exactly
            what happened with the driver import before it moved off this thread.

            THE CACHE HID IT. Warm, the same read is 291 ms; cold it is 2.5
            seconds, and every FIRST look at a folder is cold. A measurement
            that only timed the second read said the problem was solved.

            ONE RUNSPACE, OPENED ONCE, OWNED BY THE WINDOW. This is the part
            that answers the objection New-HDTConsoleView already records about
            the tree fill: "a second runspace would need this module imported
            into it - the other second - before it could read anything". True,
            and it is paid ONCE here, at window open, instead of per click. The
            tree fills once so the dispatcher is the right answer for it; the
            grid reloads on every selection, so it is not.

            THE MODULE IMPORT IS ASYNCHRONOUS TOO, so opening the window does
            not wait for it. A read arriving before the import finished simply
            queues behind it in the same runspace - which is what ReuseThread
            and a single runspace buy: the calls are serialised, in order, with
            no lock to get wrong.

            THE CACHE CROSSES THE BOUNDARY, so it must be SYNCHRONIZED. It is a
            plain hashtable of parsed .inf rows shared by two threads; without
            [hashtable]::Synchronized a concurrent read and write corrupt it in
            a way that shows up as a wrong driver list much later. The caller
            makes it; this only insists on it.

            IT SUPERSEDES RATHER THAN QUEUES. Clicking three folders quickly
            should draw the third, not all three in turn - so Begin stops
            whatever is in flight. The result of a superseded read is dropped by
            its token not matching, which is cheaper and less fragile than
            trying to kill a runspace mid-parse.

        .PARAMETER ModulePath
            The module to import into the reader's runspace - by path, because a
            console started from a working copy is not running the module that
            Import-Module Hephaestus would find.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Begin, IsDone, End
            and Close methods, and a Token.

        .EXAMPLE
            $reader = New-HDTConsoleGridReader -ModulePath $script:HDTModuleRoot
            $reader.Begin('C:\HDTLab\Share', 'Drivers\WinPE', $cache)

            Starts a read. The window polls IsDone on a DispatcherTimer and
            calls End when it answers true.

        .EXAMPLE
            $reader.Close()

            What the window's Closed handler calls. A runspace nobody closed is
            a thread that outlives the window that made it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a reader object for the calling window; it changes nothing on the share.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $ModulePath
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $reader = [pscustomobject] @{
        ModulePath = $ModulePath
        Runspace   = $null
        Shell      = $null
        Handle     = $null

        # WHICH READ THIS IS. Begin bumps it; End refuses a result whose token
        # has moved on, which is how a superseded click is dropped.
        Token      = 0
        Failure    = ''
    }

    $reader | Add-Member -MemberType ScriptMethod -Name Open -Value {

        if ($null -ne $this.Runspace) { return }

        $this.Runspace = [runspacefactory]::CreateRunspace()

        # ReuseThread: one thread for every read this window ever does, so the
        # module stays imported between reads.
        $this.Runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $this.Runspace.Open()
    }

    $reader | Add-Member -MemberType ScriptMethod -Name Begin -Value {
        param([string] $Root, [string] $Path, [object] $Cache)

        $this.Open()
        $this.Failure = ''

        # SUPERSEDE, AND STOP BEFORE DISPOSING. A runspace runs one pipeline at
        # a time: disposing a shell that is still parsing leaves the pipeline
        # running, and the next Begin fails with "the runspace is currently
        # busy" - which on three quick clicks is a console that stops listing
        # folders. Stop() ends it first, and is a no-op on one already finished.
        if ($null -ne $this.Shell) {
            try { $this.Shell.Stop() } catch { $null = $_ }
            try { $this.Shell.Dispose() } catch { $null = $_ }

            $this.Shell = $null
            $this.Handle = $null
        }

        $this.Token = [int] $this.Token + 1

        $this.Shell = [powershell]::Create()
        $this.Shell.Runspace = $this.Runspace

        # THE IMPORT IS IN THE READ, NOT BESIDE IT. A runspace runs ONE pipeline
        # at a time, so warming the module with its own BeginInvoke and then
        # starting a read raced it: the read found no module, `& $null {...}`
        # threw, End caught it, and the grid drew ZERO ROWS with no error.
        #
        # The tell was which tests passed - 'does not block' and 'answers
        # nothing for a missing folder' both went green, because a read that
        # silently returns nothing looks exactly like a read that correctly
        # returns nothing. Only the two asserting REAL ROWS failed.
        #
        # It still costs the import once: after the first read the module is
        # loaded in this runspace and Get-Module short-circuits.
        [void] $this.Shell.AddScript({
                param($ModulePath, $Root, $Path, $Cache)

                if ($null -eq (Get-Module -Name Hephaestus)) {
                    Import-Module -Name $ModulePath -Force -ErrorAction Stop
                }

                $argument = @{ Root = $Root; Path = $Path }
                if ($null -ne $Cache) { $argument['Cache'] = $Cache }

                # PRIVATE, so it is reached the way everything reaches a private
                # command: through the module it lives in.
                $module = Get-Module -Name Hephaestus
                return & $module { param($A) Get-HDTConsoleDriverRow @A } $argument
            })

        [void] $this.Shell.AddArgument($this.ModulePath)
        [void] $this.Shell.AddArgument($Root)
        [void] $this.Shell.AddArgument($Path)
        [void] $this.Shell.AddArgument($Cache)

        $this.Handle = $this.Shell.BeginInvoke()

        return [int] $this.Token
    }

    $reader | Add-Member -MemberType ScriptMethod -Name IsDone -Value {

        if ($null -eq $this.Handle) { return $true }

        return [bool] $this.Handle.IsCompleted
    }

    $reader | Add-Member -MemberType ScriptMethod -Name End -Value {

        if ($null -eq $this.Handle) { return [object[]] @() }

        $row = @()

        try {
            $row = @($this.Shell.EndInvoke($this.Handle))
        } catch {
            # A READ THAT FAILED STILL HAS TO LEAVE A WINDOW SOMEBODY CAN USE.
            # The grid empties and the reason is kept where the window can show
            # it, rather than thrown into a dispatcher timer where it would take
            # the whole console down.
            $this.Failure = [string] $_.Exception.Message
            $row = @()
        }

        try { $this.Shell.Dispose() } catch { $null = $_ }

        $this.Shell = $null
        $this.Handle = $null

        return [object[]] @($row)
    }

    $reader | Add-Member -MemberType ScriptMethod -Name Close -Value {

        # A RUNSPACE NOBODY CLOSED IS A THREAD THAT OUTLIVES ITS WINDOW, and a
        # console opened and closed a dozen times in a session would leak one
        # each time. Every step is guarded: this runs while a window is coming
        # down, often because something else already went wrong.
        try { if ($null -ne $this.Shell) { $this.Shell.Dispose() } } catch { $null = $_ }

        try {
            if ($null -ne $this.Runspace) {
                $this.Runspace.Close()
                $this.Runspace.Dispose()
            }
        } catch { $null = $_ }

        $this.Shell = $null
        $this.Handle = $null
        $this.Runspace = $null
    }

    return $reader
}
