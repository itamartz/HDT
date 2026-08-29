function Start-HDTConsole {
    <#
        .SYNOPSIS
            Opens the admin console, dealing with the apartment and the terminal.

        .DESCRIPTION
            WHAT AN ADMINISTRATOR TYPES. Show-HDTConsole is the command - it
            opens the window on the thread that calls it and returns an answer -
            and this is the wrapper around it that handles the three things a
            person at a prompt cares about and a script does not:

              the apartment  WPF needs STA, and pwsh is MTA by default;
              the terminal   a console window this process owns is hidden;
              -Detach        the window in its own process, prompt straight back.

            IT IS A FUNCTION SO IMPORTING THE MODULE IS ENOUGH.
            Start-HDTConsole.ps1 sits beside the module and is still there for
            Explorer and for a shortcut, but a .ps1 in a folder is not a command:
            Import-Module gives you functions, and nothing puts a script file on
            the command path. That file is now a shim that calls this.

            THE TERMINAL IS ONLY HIDDEN WHEN THIS PROCESS OWNS IT.
            GetConsoleProcessList says how many processes are attached; one is a
            console spawned for this alone - a double-click, or Explorer's Run
            with PowerShell - and hiding it is right. More than one is a terminal
            somebody was already working in, and hiding it takes their prompt,
            their history and, under Windows Terminal, every other tab with it.
            -Detach is the answer in that case.

            IN THE ISE, -Detach STARTS powershell.exe RATHER THAN A SECOND ISE.
            The ISE is not a console host: it takes -File, -Mta and -NoProfile
            and has never had -STA. It is also already STA, so the window opens
            there without -Detach at all.

            IT IS AN ADAPTER AND IT STAYS ONE. Win32 window state and
            Start-Process cannot be proven under Pester; what CAN be is that the
            command exists, is exported, and that the .ps1 beside it delegates
            here rather than growing a second copy of the same logic - which is
            what tests/unit/Start-HDTConsole.Tests.ps1 asserts.

        .PARAMETER Path
            One or more deployment shares. Every extra argument is another share,
            so 'D:\DeploymentShare' '\\host\HdtShare' opens both in one
            window. Give none and the console reopens the shares it was last
            closed on, or opens empty on a machine that has never had one.

        .PARAMETER Title
            The window title.

        .PARAMETER Detach
            Start the window in its own hidden process and return at once,
            leaving the prompt you ran this from usable.

            IT BEHAVES THE SAME UNDER conhost AND WINDOWS TERMINAL, which hiding
            does not: a console app under Windows Terminal runs on a
            pseudoconsole, so the window GetConsoleWindow hands back was never on
            screen and hiding it changes nothing anybody can see.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - what Show-HDTConsole
            returned. Nothing, with -Detach: the window belongs to another
            process by then.

        .EXAMPLE
            Start-HDTConsole

            The console on C:\HDTLab\Share.

        .EXAMPLE
            Start-HDTConsole -Detach C:\HDTLab\Share

            The window opens and the prompt comes straight back.

        .EXAMPLE
            Start-HDTConsole 'C:\HDTLab\Share' '\\host\HdtShare'

            Two shares, one window.

        .LINK
            Show-HDTConsole
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Opens a window. Nothing here writes; the editing commands the window offers carry their own ShouldProcess, and a confirmation prompt in front of a GUI is a prompt nobody sees.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # NO PATH MEANS YOUR OWN SHARES, NOT SOMEBODY ELSE'S.
        #
        # This defaulted to @('C:\HDTLab\Share') - one author's lab - and
        # shipped that way, which was worse than untidy: Show-HDTConsole
        # deliberately defaults -Path to @() so a bare console reopens THE
        # SHARES YOU LAST CLOSED IT ON, and opens empty with New and Open on
        # the root row when there are none. This command is the one people
        # actually type, and it overrode that behaviour with a path that
        # exists on exactly one machine.
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [AllowEmptyCollection()]
        [string[]] $Path = @(),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Title = 'Hephaestus Deployment Toolkit',


        [Parameter()]
        [switch] $Detach
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # -- the terminal, which is not part of the product ----------------------

    if (-not ('HDTConsoleNative.Terminal' -as [type])) {
        Add-Type -Namespace 'HDTConsoleNative' -Name 'Terminal' -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();

[DllImport("kernel32.dll")]
public static extern int GetConsoleProcessList(int[] lpdwProcessList, int dwProcessCount);

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    }

    $consoleWindow = [HDTConsoleNative.Terminal]::GetConsoleWindow()
    $consoleHidden = $false

    if ($consoleWindow -ne [IntPtr]::Zero) {
        $attached = New-Object -TypeName 'int[]' -ArgumentList 8
        $attachedCount = [HDTConsoleNative.Terminal]::GetConsoleProcessList($attached, $attached.Length)

        if ($attachedCount -eq 1) {
            [void] [HDTConsoleNative.Terminal]::ShowWindow($consoleWindow, 0)   # SW_HIDE
            $consoleHidden = $true
        }
    }

    # -- the relaunch, for -Detach and for an MTA host -----------------------
    #
    # QUOTED, BECAUSE Start-Process DOES NOT QUOTE. -ArgumentList joins an array
    # with spaces into one command line, so '-Title Hephaestus Deployment
    # Toolkit' arrives as three arguments and the child dies binding them -
    # invisibly, because the child is hidden. Every value is quoted, not only
    # the ones that look like they need it: a share path with a space in it is
    # ordinary.
    $launcher = Join-Path -Path $script:HDTModuleRoot -ChildPath 'Start-HDTConsole.ps1'

    $argument = New-Object -TypeName System.Collections.ArrayList

    [void] $argument.Add('-NoProfile')
    [void] $argument.Add('-STA')
    [void] $argument.Add('-File')
    [void] $argument.Add('"{0}"' -f $launcher)
    [void] $argument.Add('-Title')
    [void] $argument.Add('"{0}"' -f $Title)
    [void] $argument.Add('-Path')

    foreach ($one in @($Path)) { [void] $argument.Add('"{0}"' -f $one) }

    # NOT THIS PROCESS'S OWN EXECUTABLE. In powershell.exe they are the same
    # thing; in the ISE this process is powershell_ise.exe, which takes -File,
    # -Mta and -NoProfile and has never had -STA - so -Detach started a second
    # ISE with a switch it does not have and reported an error about apartments.
    # Get-HDTPowerShellPath falls back to the console host in $PSHOME.
    #
    # NOT $host either: that is an automatic variable, and assigning to it is
    # both an analyzer error and a way to break every Write-Host in the session.
    $shell = Get-HDTPowerShellPath -ProcessPath ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -InstallPath $PSHOME

    if ($Detach) {
        [void] (Start-Process -FilePath $shell -ArgumentList ([string[]] @($argument)) -WindowStyle Hidden)
        return
    }

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        $process = Start-Process -FilePath $shell -ArgumentList ([string[]] @($argument)) `
            -WindowStyle Hidden -PassThru -Wait

        if ($consoleHidden) {
            [void] [HDTConsoleNative.Terminal]::ShowWindow($consoleWindow, 5)   # SW_SHOW
        }

        return [pscustomobject] @{
            Action    = 'Relaunched'
            ExitCode  = [int] $process.ExitCode
            NodeCount = 0
        }
    }

    # -- the window ----------------------------------------------------------

    try {
        return Show-HDTConsole -Path $Path -Title $Title
    } finally {
        # HIDDEN IS A PRESENTATION CHOICE, NOT A PLACE TO GET STUCK. Whether the
        # window closed cleanly or never opened, the terminal comes back - there
        # has to be something to read and something to type into.
        if ($consoleHidden) {
            [void] [HDTConsoleNative.Terminal]::ShowWindow($consoleWindow, 5)   # SW_SHOW
        }
    }
}
