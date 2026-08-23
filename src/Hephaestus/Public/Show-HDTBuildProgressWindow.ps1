function Show-HDTBuildProgressWindow {
    <#
        .SYNOPSIS
            Runs Update-HDTBootImage and shows what it is doing while it does it.

        .DESCRIPTION
            THE BUILD USED TO FREEZE THE WINDOW THAT STARTED IT. Seventeen steps
            and about two and a half minutes on the dispatcher: the Windows PE
            window greyed out for the whole of it, which reads as a window that
            has hung. That is not cosmetic - somebody kills it, and a killed
            build leaves a MOUNTED IMAGE behind that needs dism /cleanup-wim
            before anything can build again.

            SO THE BUILD RUNS IN ITS OWN RUNSPACE and this window drains its
            reports on a dispatcher timer. What each step is called comes from
            Update-HDTBootImage itself, through New-HDTBuildProgress - the
            window names none of them, so a step added to the build appears here
            without this file being touched.

            IT IS MODAL, AND IT REFUSES TO CLOSE UNTIL THE BUILD ENDS. Closing
            over a running mount would leave the runspace holding it with
            nothing on screen to say so. The Close button and the title-bar X
            are both refused, and the button LOOKS refused.

            IT RETURNS WHETHER THE BUILD WORKED, so a caller can decide what to
            do next. The window has already said so on screen; the boolean is
            for the caller, not for the administrator.

        .PARAMETER WorkspaceRoot
            The deployment share to build the boot image of.

        .PARAMETER XamlPath
            The window's markup. Defaults to the one shipped beside the module.

        .PARAMETER ModulePath
            The module the build runspace imports. Defaults to the RUNNING
            module's own root, so a console started from a working copy builds
            with that copy rather than with whatever Import-Module would find.

        .PARAMETER ConsoleHost
            The host to show it through. Omitted, one is created.

        .PARAMETER Screen
            The IScreen the position is taken from. Omitted, the real desktop.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean - whether the build succeeded.

        .EXAMPLE
            $root = 'C:\HDTLab\Share'
            Show-HDTBuildProgressWindow -WorkspaceRoot 'C:\HDTLab\Share'

        .EXAMPLE
            if (-not (Show-HDTBuildProgressWindow -WorkspaceRoot $root)) { return }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $XamlPath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'UI\Console\HDTBuildProgress.xaml'),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ModulePath = $script:HDTModuleRoot,

        [Parameter()]
        [AllowNull()]
        [object] $ConsoleHost,


        [Parameter()]
        [AllowNull()]
        [object] $Screen
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $ConsoleHost) { $ConsoleHost = New-HDTConsoleHost }
    if ($null -eq $Screen) { $Screen = New-HDTConsoleScreen }

    if (-not (Test-Path -LiteralPath $XamlPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $XamlPath `
                    -Category ObjectNotFound `
                    -Message 'the build progress markup is missing, so the build cannot be watched.'))
    }

    # THE CORNER OF THE WORK AREA, like every other HDT window. It keeps its own
    # size from the markup - it is a dialog, not a browser - and only the origin
    # comes from the desktop.
    $work = $Screen.GetWorkArea()

    $answer = $ConsoleHost.ShowBuildProgress(
        [System.IO.File]::ReadAllText($XamlPath), $WorkspaceRoot, $ModulePath,
        (Get-HDTConsoleTheme),
        [pscustomobject] @{ Left = [double] $work.Left; Top = [double] $work.Top })

    return [bool] $answer
}
