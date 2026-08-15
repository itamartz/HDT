function Start-HDTProgressDisplay {
    <#
        .SYNOPSIS
            Puts DESIGN 11.1's progress window on screen - or reports why it
            could not, and never stops the deployment either way.

        .DESCRIPTION
            THREE OUTCOMES, AND NONE OF THEM IS AN ERROR:

              Window      the window is up.
              Console     it could not be drawn, and the deployment carries on
                          writing status to the console instead.
              Suppressed  HDTSkipProgress said not to show one at all.

            IT MUST DEGRADE TO THE CONSOLE, in DESIGN 11.1's words: "If XAML
            fails to load - a boot image built without the right components, an
            exotic display, a serial console - the engine logs the reason and
            writes styled console lines instead, then carries on. A deployment
            that refused to run because it cannot draw a progress bar would be a
            worse toolkit than one with no progress bar at all."

            SO THIS COMMAND DOES NOT THROW. Not for a missing window file, not
            for markup that will not parse, not for a machine whose WinPE was
            built without WinPE-NetFx and has no PresentationFramework to load.
            Every one of those comes back as Console with a Reason, and the
            caller decides what to say about it.

            THE FALLBACK IS TESTED BECAUSE NOBODY EXERCISES IT UNTIL THE NIGHT
            IT MATTERS. That is DESIGN 11.1's own reasoning, and it is why the
            host is injected: New-HDTFakeProgressHost -FailOpen is a machine
            with no WPF, on a developer's desktop, in three milliseconds.

            Suppressed AND Console ARE DIFFERENT FACTS and are never conflated.
            One is a machine nobody is standing at; the other is a machine that
            could not draw. Reporting the second as the first would hide a
            broken boot image behind a deliberate setting.

            THE WINDOW IS NOT IN THIS FUNCTION. An injected IProgressHost owns
            Add-Type, XamlReader and the runspace the window lives in; this owns
            whether there should be one. Same split as the wizard, for the same
            reason (DESIGN 12.2.1).

        .PARAMETER XamlPath
            The window. X:\HDT\UI\HDTProgress.xaml inside a boot image.

        .PARAMETER Variable
            The resolved variables. HDTSkipProgress is the only one read.

        .PARAMETER DisplayHost
            An IProgressHost. Defaults to the real adapter.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Mode ('Window',
            'Console' or 'Suppressed'), Reason, XamlPath and DisplayHost.

        .EXAMPLE
            $display = Start-HDTProgressDisplay -XamlPath 'X:\HDT\UI\HDTProgress.xaml' -Variable $resolved

        .EXAMPLE
            if ($display.Mode -eq 'Window') { $display.DisplayHost.Update($progress) }

            What the engine does on every step: render if there is something to
            render to, and never ask whether it worked.
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
        [hashtable] $Variable,

        [Parameter()]
        [AllowNull()]
        [object] $DisplayHost,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $DisplayHost) { $DisplayHost = New-HDTProgressHost }

    $resolved = $Variable
    if ($null -eq $resolved) { $resolved = @{} }

    $result = [ordered] @{
        Mode        = 'Window'
        Reason      = ''
        XamlPath    = $XamlPath
        DisplayHost = $DisplayHost
    }

    # -- was there meant to be one at all? ---------------------------------
    #
    # Read loosely for the reason Get-HDTWizardPage reads its keys loosely:
    # rules.yaml gives a real boolean and a command line gives text, and a skip
    # that silently failed to apply is a full-screen window on a machine that
    # was supposed to deploy unattended.
    $skip = $false
    if ($resolved.ContainsKey('HDTSkipProgress')) {
        $value = $resolved['HDTSkipProgress']

        if ($value -is [bool]) {
            $skip = [bool] $value
        } elseif ($null -ne $value) {
            $skip = (@('true', 'yes', '1', 'on') -contains ([string] $value).Trim().ToLowerInvariant())
        }
    }

    if ($skip) {
        # AND THE FILE IS NOT READ. A missing window is not a failure on a run
        # that was never going to draw one.
        $result['Mode'] = 'Suppressed'
        $result['Reason'] = 'HDTSkipProgress'
        return [pscustomobject] $result
    }

    # -- the window file ----------------------------------------------------

    # THE FALLBACK IS A HOST, NOT A BRANCH AT THE CALL SITE. The caller gets an
    # object with the same Update it would have had, so the engine reports
    # progress the same way whatever machine it is on - and there is no
    # `if ($mode -eq 'Window')` anywhere for somebody to forget. That matters
    # precisely because this path only happens on machines nobody is testing on.
    $fallback = {
        param([string] $Why)

        $result['Mode'] = 'Console'
        $result['Reason'] = $Why
        $result['DisplayHost'] = New-HDTConsoleProgressHost

        return [pscustomobject] $result
    }

    if (-not $FileSystem.TestPath($XamlPath)) {
        return (& $fallback ("the progress window '{0}' is not there, so the deployment will report progress to the console instead. In a boot image it is staged to X:\HDT\UI\ by Update-HDTBootImage." -f $XamlPath))
    }

    $xaml = ''
    try {
        $xaml = [string] $FileSystem.ReadAllText($XamlPath)
        [void] ([xml] $xaml)
    } catch {
        return (& $fallback ("the progress window '{0}' could not be read as XML, so the deployment will report progress to the console instead: {1}" -f
                $XamlPath, [string] $_.Exception.Message))
    }

    # -- and whether this machine can show one ------------------------------
    #
    # THE PATH NOBODY EXERCISES UNTIL THE NIGHT IT MATTERS. A boot image built
    # without WinPE-NetFx has no PresentationFramework, and the adapter throws
    # here rather than returning anything. It is caught because a deployment
    # that will not run without a progress bar is worse than one with none.
    try {
        $DisplayHost.Open($xaml)
    } catch {
        return (& $fallback ("the progress window could not be opened, so the deployment will report progress to the console instead: {0}" -f
                [string] $_.Exception.Message))
    }

    return [pscustomobject] $result
}
