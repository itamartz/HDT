function Set-HDTWindowForeground {
    <#
        .SYNOPSIS
            Puts a deployment window in front of the Windows shell, and lets go
            again.

        .DESCRIPTION
            THE SCREEN A DEPLOYED MACHINE COVERED UP. In the full-OS leg the
            machine is logged in as the local Administrator with a real desktop
            behind it, and a deployed VM showed the Windows taskbar and the
            Start menu drawing straight OVER the progress board and over the
            Deployment Summary - the two screens whose entire job is to tell the
            person standing in front of the machine what it is doing and what it
            did.

            Topmost IS THE OBVIOUS ANSWER AND IT IS THE WRONG ONE. The taskbar
            is itself a topmost window, so a topmost window of ours is its PEER
            and whichever was activated last is in front - opening the Start
            menu puts the shell over anything. Worse, the Deployment Summary
            must never be topmost at all: its Open CMD button hands the machine
            to a command prompt, and a topmost window outranks the prompt it
            just launched, which is the defect HDTFailure.xaml lost its Topmost
            attribute over. tests/contract/WinPeWindowReach.Contract.Tests.ps1
            holds that rule for every window in src\Hephaestus\UI, and this
            command exists so that raising a window does not mean breaking it.

            NOTHING IS LEFT RAISED, AND THAT IS THE POINT. Being in front is not
            a state that sticks: the moment the technician activates anything
            else - a command prompt, most of all - it takes the foreground back,
            which is exactly what should happen. There is nothing to undo
            afterwards, no flag to clear and no teardown to get wrong. The one
            system setting it touches, the foreground lock timeout, is written
            with fWinIni 0, so it is not persisted to the profile and dies with
            the session; and AttachThreadInput is detached on the line after it
            is attached. See Get-HDTWindowForegroundSource for what each of the
            four steps is for - none of them is decoration, and deleting any one
            gives a call that silently returns false.

            SO IT IS CALLED ONCE, WHEN THE WINDOW APPEARS, AND NEVER ON A TIMER.
            A window that re-raised itself every tick would be a topmost window
            built out of parts, sitting over the prompt it had just launched.

            THE CODE IS THE USER'S OWN, from their 31-Show-OSDFinish.ps1
            ("OSD Deployment Complete finish screen, native WPF, no
            MDT/ServiceUI"), whose comment says it exists to force the window in
            front of the auto-logon Start menu. Renamed to HDT's namespace and
            otherwise unchanged, because it is known to work on the machine this
            is for. Not from MDT or PSD, so there is no NOTICE.md row.

            IT IS AN ADAPTER OVER user32, AND IT DOES NOT CLAIM THE TDD
            EXEMPTION. That exemption is for adapters that are BRANCH-FREE, and
            this one is not: it guards a null handle and it chooses whether to
            dismiss the Start menu. What can be tested is tested - the guard,
            which returns before anything is compiled or any keystroke is sent,
            and the source, asserted as text so the four load-bearing steps
            cannot be quietly simplified away. The Win32 path itself is never
            executed by the suite, because Force injects real Escape and Alt
            keystrokes and they would go to whatever has focus on the machine
            running the tests.

            SAFE OUTSIDE A DESKTOP. A window with no handle yet - and a WPF
            window has none before it is sourced - reports false and does
            nothing. This must never be the reason a deployment screen fails to
            appear.

        .PARAMETER Handle
            The window's HWND. A WPF Window is not one: take it from
            [System.Windows.Interop.WindowInteropHelper]::new($window).Handle,
            which is only non-zero once the window has been sourced.

        .PARAMETER DismissStartMenu
            Tap Escape first, to close a Start menu that is already open. The
            reported symptom, and the reason this switch exists - but a stray
            Escape is a keystroke nobody asked for, so a window raised over a
            plain taskbar leaves it off.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean - whether there was a window to act on.

        .EXAMPLE
            $window = New-Object -TypeName System.Windows.Window
            $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
            [void] (Set-HDTWindowForeground -Handle $hwnd -DismissStartMenu)

            Where the handle comes from. A window that has not been shown yet
            reports zero, and this reports false rather than acting on it -
            which is why the real callers wire it to ContentRendered and call it
            once, as the window appears.

        .EXAMPLE
            Set-HDTWindowForeground -Handle ([System.IntPtr]::Zero)

            Reports false and does nothing at all.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes which window is in front, which is presentation and not system state; nothing it does outlives the session. A confirmation prompt in front of a technician watching a deployment would be a second window to answer.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [System.IntPtr] $Handle,

        [Parameter()]
        [switch] $DismissStartMenu
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # BEFORE Add-Type, AND THAT ORDER IS ASSERTED. A window that has not been
    # sourced yet has no handle, and there is nothing here to compile or to type
    # into on its behalf - which is also what makes this the one path a test on
    # a developer's own desktop may safely run.
    if ($Handle -eq [System.IntPtr]::Zero) {
        return $false
    }

    # ONCE PER PROCESS. Add-Type throws if the name already exists, and a
    # deployment shows more than one window.
    if (-not ([System.Management.Automation.PSTypeName]'HDT.NativeForeground').Type) {
        Add-Type -TypeDefinition (Get-HDTWindowForegroundSource)
    }

    [HDT.NativeForeground]::Force($Handle, [bool] $DismissStartMenu)

    return $true
}
