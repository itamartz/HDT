function Get-HDTWindowForegroundSource {
    <#
        .SYNOPSIS
            The C# that puts a window in front of the Windows shell.

        .DESCRIPTION
            A STRING RATHER THAN AN Add-Type, AND THE REASON IS A RUNSPACE. The
            progress window runs on its own STA runspace with NO MODULE IN IT -
            importing one on a RAM disk to draw a status board would cost the
            deployment seconds it does not owe - so it cannot call
            Set-HDTWindowForeground. It gets the SOURCE handed across instead
            and compiles it there. Get-HDTCommandPromptPath was extracted for
            exactly this reason and this follows it: one source of truth, two
            places that need it, rather than the same P/Invoke block typed twice
            and drifting.

            IT IS THE USER'S OWN WORKING CODE, FROM TWO OF THEIR SCRIPTS, and
            it is two halves of one mechanism:

              Force  - from 31-Show-OSDFinish.ps1 ("OSD Deployment Complete
                       finish screen, native WPF, no MDT/ServiceUI"), whose own
                       comment says it exists to force the window in front of
                       the auto-logon Start menu. This is how a window GETS to
                       the front.

              Raise  - from Show-UpgradeNotice.ps1, a borderless un-closable
                       countdown driven by a ConfigMgr task sequence. This is
                       how it STAYS there.

            Renamed to HDT's namespace and otherwise unchanged, because both are
            known to work on the machines this is for. Not derived from MDT or
            PSD, so there is no NOTICE.md row: MDT does not solve this at all -
            there is no Topmost, no SetWindowPos and no taskbar hiding anywhere
            in LiteTouch, because it holds the SHELL back instead (HideShell,
            and AsyncRunOnce=0 in the specialize pass of its answer file) - and
            PSD's finish dialog only sets Topmost.

            WHY Raise EXISTS WHEN THE WINDOW IS ALREADY Topmost. Topmost="True"
            puts a window IN the topmost band; it does not keep it at the front
            OF that band, so anything created topmost after it lands above.
            SetWindowPos with HWND_TOPMOST moves it back to the front, and
            SWP_NOACTIVATE means it steals no focus doing so. Re-asserted on a
            one-second tick, a window that opened above ours is in front for one
            tick and no longer.

            AND Raise IS NOT ENOUGH ON ITS OWN, which is why both halves are
            here. The Start menu and the Search flyout are ApplicationFrameWindow
            and XAML host surfaces that sit ABOVE the ordinary topmost band, so
            no amount of SetWindowPos gets over one that is already open. The
            Escape tap in Force is what closes it. That is the reported symptom,
            and it is the half a "just set Topmost" fix would miss.

            WHY NOT Topmost, WHICH IS THE OBVIOUS ANSWER AND THE WRONG ONE. The
            taskbar is ITSELF a topmost window, so a topmost window of ours is
            its peer and whichever was activated last is in front - opening the
            Start menu puts the shell over anything. And the Deployment Summary
            must never be topmost: its Open CMD button hands the machine to a
            command prompt, and a topmost window outranks the prompt it just
            launched, which is the defect HDTFailure.xaml lost its Topmost
            attribute over. Forcing the foreground has neither problem, because
            being in front is not a state that sticks - anything the technician
            activates next takes it back, which is exactly what should happen.

            FOUR THINGS IN IT LOOK REDUNDANT AND ARE LOAD BEARING. Deleting any
            one gives a call that returns false and a window still behind the
            Start menu, which is indistinguishable from having changed nothing:

              SPI_SETFOREGROUNDLOCKTIMEOUT set to 0 removes Windows' own
                foreground lock. It is passed fWinIni 0, so it is NOT written to
                the user profile and dies with the session - there is no
                setting here left switched on afterwards.

              The ALT TAP satisfies the "this thread has received input" rule.
                Without it SetForegroundWindow is silently ignored and returns
                false; with it the request is allowed.

              AttachThreadInput to the thread that currently owns the
                foreground is what makes the request permissible at all - and it
                is DETACHED again on the next line. A thread left attached to
                another process's input queue is a machine whose keyboard
                misbehaves for the rest of the session, which is worse than the
                defect being fixed.

              The ESCAPE TAP closes a Start menu that is ALREADY OPEN, which is
                the reported symptom exactly. Optional, because a window raised
                over a plain taskbar has nothing to dismiss and a stray Escape
                is a keystroke nobody asked for.

            KEYSTROKES ARE INJECTED, WHICH IS WHY NO TEST CALLS Force. Escape
            and Alt go to whatever has focus on the machine running them, so the
            suite asserts this text and the zero-handle guard, and never the
            Win32 path. tests/unit/Set-HDTWindowForeground.Tests.ps1 says so at
            the top.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - a C# compilation unit declaring HDT.NativeForeground.

        .EXAMPLE
            Add-Type -TypeDefinition (Get-HDTWindowForegroundSource)

            What both callers do, each guarded by a check that the type is not
            already in the AppDomain.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A SINGLE-QUOTED HERE-STRING. The C# below contains $ in no place today,
    # and a double-quoted one would expand the next one somebody adds.
    return @'
using System;
using System.Runtime.InteropServices;

namespace HDT {

    public static class NativeForeground {

        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int n);
        [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
        [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
        [DllImport("user32.dll", SetLastError=true)] static extern bool SystemParametersInfoW(uint a, uint b, IntPtr c, uint d);

        const int SW_RESTORE = 9;
        const byte VK_ESCAPE = 0x1B, VK_MENU = 0x12;
        const uint KEYUP = 0x2, SPI_SETFOREGROUNDLOCKTIMEOUT = 0x2001;

        // SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
        const uint SWP_KEEP = 0x0001 | 0x0002 | 0x0010;

        // Re-asserts HWND_TOPMOST, which is NOT the same as being topmost
        // already: Topmost="True" only puts a window IN the topmost band, and
        // anything created topmost afterwards lands above it. SetWindowPos
        // moves it back to the FRONT of that band. SWP_NOACTIVATE, so it takes
        // no focus from anything the technician is using.
        public static void Raise(IntPtr hwnd) {
            if (hwnd == IntPtr.Zero) return;
            SetWindowPos(hwnd, new IntPtr(-1), 0, 0, 0, 0, SWP_KEEP);
        }

        public static void Force(IntPtr hwnd, bool dismissStart) {
            if (hwnd == IntPtr.Zero) return;

            // Removes Windows' own foreground lock. fWinIni is 0, so this is
            // NOT persisted to the profile and does not outlive the session.
            try { SystemParametersInfoW(SPI_SETFOREGROUNDLOCKTIMEOUT, 0, IntPtr.Zero, 0); } catch {}

            // Closes a Start menu that is already open - the reported symptom.
            if (dismissStart) { keybd_event(VK_ESCAPE, 0, 0, IntPtr.Zero); keybd_event(VK_ESCAPE, 0, KEYUP, IntPtr.Zero); }

            // ALT tap satisfies the "thread received input" rule so
            // SetForegroundWindow isn't ignored.
            keybd_event(VK_MENU, 0, 0, IntPtr.Zero); keybd_event(VK_MENU, 0, KEYUP, IntPtr.Zero);

            ShowWindow(hwnd, SW_RESTORE);

            IntPtr fg = GetForegroundWindow();
            uint fgT = GetWindowThreadProcessId(fg, IntPtr.Zero);
            uint me = GetCurrentThreadId();

            // Attaching to the thread that owns the foreground is what makes
            // the request permissible. It MUST be detached again.
            AttachThreadInput(fgT, me, true);
            BringWindowToTop(hwnd);
            SetForegroundWindow(hwnd);
            AttachThreadInput(fgT, me, false);
        }
    }
}
'@
}
