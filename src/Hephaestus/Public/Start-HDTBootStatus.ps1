function Start-HDTBootStatus {
    <#
        .SYNOPSIS
            Puts the boot status overlay on screen - or reports why it could
            not, and never stops the deployment either way.

        .DESCRIPTION
            WHAT THE OVERLAY IS FOR. WinPE boots into cmd.exe running
            startnet.cmd, and that black full-screen console covers the desktop
            for the whole run. A BGInfo start command - the machine's serial,
            model and address painted onto the wallpaper, which is the only
            reason BGInfo is in a boot image at all - draws BEHIND it, so a
            technician never sees any of it. MDT has no console to hide:
            winpeshl.ini makes LiteTouch.wsf the shell, which is why the same
            BGInfo is on screen there from the first second.

            Start-HDTDeployment hides the console for that reason, and this is
            what goes in its place: the payload's own account of itself, in a
            transparent panel in the corner of the wallpaper rather than a black
            rectangle over it.

            TWO OUTCOMES, AND NEITHER IS AN ERROR:

              Window   the overlay is up.
              Console  it could not be drawn, and the WinPE console is where the
                       deployment's account of itself stays.

            AND THE SECOND ONE IS WHY THIS COMMAND EXISTS SEPARATELY FROM THE
            HOST. The payload hides the console ONLY when this returns Window.
            A boot image built without WinPE-NetFx has no PresentationFramework,
            the overlay cannot open, the console is left exactly where it was,
            and nobody is ever left looking at a blank screen. Deciding that here
            rather than in the adapter is what makes it testable without a
            display attached.

            SO THIS COMMAND DOES NOT THROW. Not for a missing window file, not
            for markup that will not parse, not for a machine with no WPF. Every
            one of those comes back as Console with a Reason, and the caller
            decides what to say about it.

            THERE IS NO Suppressed MODE, unlike Start-HDTProgressDisplay. That
            one has HDTSkipProgress because a full-screen status board on an
            unattended machine is a screen nobody asked for; this window is what
            a technician sees INSTEAD OF a console, and the variables that could
            suppress it have not been resolved yet at step 4a. A run nobody is
            standing at pays for a transparent panel it never draws twice.

            THE WINDOW IS NOT IN THIS FUNCTION. An injected host owns Add-Type,
            XamlReader and the runspace the window lives in; this owns whether
            there should be one. Same split as the wizard and the progress board,
            for the same reason (DESIGN 12.2.1).

        .PARAMETER XamlPath
            The window. X:\HDT\UI\HDTBootStatus.xaml inside a boot image.

        .PARAMETER StatusHost
            An IBootStatusHost. Defaults to the real adapter.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .PARAMETER EnvironmentProvider
            Where the F8 command prompt path comes from. The overlay runs in a
            runspace with no Hephaestus module in it, so it cannot resolve
            ComSpec for itself - and F8 matters more on this window than on any
            other, because the console is hidden behind it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Mode ('Window' or
            'Console'), Reason, XamlPath and StatusHost.

        .EXAMPLE
            $status = Start-HDTBootStatus -XamlPath 'X:\HDT\UI\HDTBootStatus.xaml'
            if ($status.Mode -eq 'Window') { $shellHidden = [bool] (Hide-HDTShellWindow) }

            The whole contract in two lines: the console goes away only if there
            is something to look at instead.

        .EXAMPLE
            $status.StatusHost.Write('12:00:01  bootstrap: provider Smb')

            What the payload does with every line it says - with no branch on
            Mode, because the fallback host has the same method.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Opens a status window the deployment asked for; it changes no system state and there is no operator to confirm to.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $XamlPath,

        [Parameter()]
        [AllowNull()]
        [object] $StatusHost,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $EnvironmentProvider
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $StatusHost) { $StatusHost = New-HDTBootStatusHost }

    $result = [ordered] @{
        Mode       = 'Window'
        Reason     = ''
        XamlPath   = $XamlPath
        StatusHost = $StatusHost
    }

    $fallback = {
        param([string] $Why)

        $result['Mode'] = 'Console'
        $result['Reason'] = $Why
        $result['StatusHost'] = New-HDTConsoleBootStatusHost

        return [pscustomobject] $result
    }

    if (-not $FileSystem.TestPath($XamlPath)) {
        return (& $fallback ("the boot status overlay '{0}' is not there, so the WinPE console stays on screen instead. In a boot image it is staged to X:\HDT\UI\ by Update-HDTBootImage." -f $XamlPath))
    }

    $xaml = ''
    try {
        $xaml = [string] $FileSystem.ReadAllText($XamlPath)
        [void] ([xml] $xaml)
    } catch {
        return (& $fallback ("the boot status overlay '{0}' could not be read as XML, so the WinPE console stays on screen instead: {1}" -f
                $XamlPath, [string] $_.Exception.Message))
    }

    # THE PATH NOBODY EXERCISES UNTIL THE NIGHT IT MATTERS. A boot image built
    # without WinPE-NetFx has no PresentationFramework, and the adapter throws
    # here rather than returning anything.
    if (-not $PSBoundParameters.ContainsKey('EnvironmentProvider') -or $null -eq $EnvironmentProvider) {
        $EnvironmentProvider = New-HDTEnvironmentProvider
    }

    $commandPromptPath = Get-HDTCommandPromptPath -Environment $EnvironmentProvider

    # THE WINDOW'S TWO STRINGS, READ HERE BECAUSE THE HOST CANNOT. Its runspace
    # has no Hephaestus module in it, so it cannot reach the table itself - the
    # same split that hands it a command prompt path rather than a command.
    $text = Get-HDTStringTable -Page 'BootStatus'

    try {
        $StatusHost.Open($xaml, $commandPromptPath, $text)
    } catch {
        return (& $fallback ("the boot status overlay could not be opened, so the WinPE console stays on screen instead: {0}" -f
                [string] $_.Exception.Message))
    }

    return [pscustomobject] $result
}
