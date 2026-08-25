function Show-HDTDriverWindow {
    <#
        .SYNOPSIS
            Opens the properties of one driver.

        .DESCRIPTION
            Deployment Workbench's driver Properties, with its two tabs
            collapsed into one: what the .inf says, the PnP ids it claims, and
            the single thing about it that can be changed.

            ONE TAB, NOT TWO. Workbench put a tick box and a comment on General
            and everything a technician came to read on Details, so the ordinary
            question - which machine is this driver for - was always one tab
            away from the answer.

            IT OPENS ON A ROW, NOT A PATH. The grid already read the .inf to
            draw itself; re-parsing the same file to fill a window that was
            opened from it would be the second answer to a question already
            answered, and the two could disagree.

            THE PnP IDS ARE THE POINT OF THE WINDOW, which is why they get the
            space that is left rather than a field on a row.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Driver
            The driver, as Get-HDTConsoleDriverRow or Get-HDTDriver answered it.

        .PARAMETER XamlPath
            The window's markup. Defaults to the one shipped beside the module.

        .PARAMETER ConsoleHost
            The host to show it through. Omitted, one is created - which is what
            makes this command runnable on its own, without the browser.

        .PARAMETER OwnerWidth
            The width of the window this was opened from. Zero means the
            remembered size.

        .PARAMETER OwnerHeight
            The height of the window this was opened from.

        .PARAMETER Screen
            The screen service, for keeping the window on a monitor that exists.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Answer - 'saved'
            when the window wrote the enabled state, 'deleted' when it removed
            the driver, empty otherwise.

        .EXAMPLE
            $one = @(Get-HDTDriver -Root 'C:\HDTLab\Share')[0]
            Show-HDTDriverWindow -Root 'C:\HDTLab\Share' -Driver $one

        .EXAMPLE
            $bad = @(Get-HDTDriver -Root 'C:\HDTLab\Share' -Path 'WinPE\Dell WinPE 11 x64' |
                    Where-Object { $_.Class -eq 'Net' })[0]
            $answer = Show-HDTDriverWindow -Root 'C:\HDTLab\Share' -Driver $bad
            if ($answer.Answer -eq 'saved') { Update-HDTBootImage -WorkspaceRoot 'C:\HDTLab\Share' }

            Turning off the network driver that hangs WinPE on one model, and
            rebuilding the boot image so the change is in it - which is the
            whole reason the tick box is on this window.

        .LINK
            Get-HDTDriver

        .LINK
            Set-HDTDriverState
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Driver,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $XamlPath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'UI\Console\HDTDriverProperties.xaml'),

        [Parameter()]
        [AllowNull()]
        [object] $ConsoleHost,

        [Parameter()]
        [ValidateRange(0, 100000)]
        [int] $OwnerWidth = 0,

        [Parameter()]
        [ValidateRange(0, 100000)]
        [int] $OwnerHeight = 0,

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
                    -Message 'the driver properties window markup is missing, so the window cannot be shown.'))
    }

    $size = Resolve-HDTConsoleEditorSize -OwnerWidth $OwnerWidth -OwnerHeight $OwnerHeight -Screen $Screen

    $answer = $ConsoleHost.ShowDriver(
        [System.IO.File]::ReadAllText($XamlPath), $Root, $Driver,
        (Get-HDTConsoleTheme), $size)

    return [pscustomobject] @{
        Answer = [string] $answer
        Root   = $Root
        Path   = [string] $Driver.Path
    }
}
