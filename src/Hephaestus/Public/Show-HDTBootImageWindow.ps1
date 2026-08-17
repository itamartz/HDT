function Show-HDTBootImageWindow {
    <#
        .SYNOPSIS
            Opens the Windows PE window on a deployment share.

        .DESCRIPTION
            Deployment Workbench's deployment share Properties, Windows PE tab.
            Four tabs over workspace.yaml's bootImage block: General, Features,
            Drivers and Customisations.

            IT READS THE DOCUMENT'S OWN LINES AND NEVER ROUND-TRIPS THEM. Every
            editing cmdlet this window presses splices a string array, and the
            whole reason for that is that an administrator's comments survive.
            A parse-and-re-emit would hand back a correct document and none of
            the notes beside the keys.

            THE ADK IS READ HERE, ONCE, AND HANDED IN. Get-HDTAdkComponent wants
            an installed ADK and a registry hive; asking for it at the edge
            means Get-HDTConsoleBootImageSetting stays testable with neither, and means
            a build host without an ADK gets an empty Features tab rather than a
            window that will not open.

            A BUILD HOST WITH NO ADK IS NOT AN ERROR. It is a machine somebody
            is authoring a share on, and every other tab still works.

        .PARAMETER Path
            The workspace.yaml to configure.

        .PARAMETER XamlPath
            The window's markup. Defaults to the one shipped beside the module.

        .PARAMETER ConsoleHost
            The host to show it through. Omitted, one is created - which is what
            makes this command runnable on its own, without the browser.

        .PARAMETER FileSystem
            The IFileSystem to read the document with.

        .PARAMETER Theme
            Light or Dark, applied through Get-HDTConsoleTheme like every other
            console window.

        .PARAMETER OwnerWidth
            The width of the window this was opened from. Zero means the
            markup's own size.

        .PARAMETER OwnerHeight
            The height of the window this was opened from.

        .PARAMETER Screen
            The IScreen the size is fitted to. Omitted, the real desktop.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Action and
            DocumentPath.

        .EXAMPLE
            Show-HDTBootImageWindow -Path 'C:\HDTLab\Share\workspace.yaml'

        .EXAMPLE
            Show-HDTBootImageWindow -Path '\\HDT-HOST\HdtShare\workspace.yaml' -Theme Dark
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $XamlPath = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'UI\Console\HDTBootImage.xaml'),

        [Parameter()]
        [AllowNull()]
        [object] $ConsoleHost,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        [Parameter()]
        [ValidateSet('Light', 'Dark')]
        [string] $Theme = 'Light',

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
    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $Screen) { $Screen = New-HDTConsoleScreen }

    if (-not (Test-Path -LiteralPath $XamlPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $XamlPath `
                    -Category ObjectNotFound `
                    -Message 'the Windows PE window markup is missing, so the window cannot be shown.'))
    }

    if (-not $FileSystem.TestPath($Path)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Category ObjectNotFound `
                    -Message 'there is no workspace document here, so there is no boot image to configure.'))
    }

    $line = [string[]] @([string] $FileSystem.ReadAllText($Path) -split "`r?`n")

    # THE ARCHITECTURE THE DOCUMENT ASKS FOR, because the ADK ships a separate
    # cab set per architecture and a list for the wrong one describes an image
    # nobody is building.
    $architecture = 'amd64'
    $workspace = ConvertFrom-HDTWorkspaceLine -Line $line

    if (-not [string]::IsNullOrWhiteSpace([string] $workspace.BootImage.Architecture)) {
        $architecture = [string] $workspace.BootImage.Architecture
    }

    # BEST EFFORT, AND A MACHINE WITH NO ADK STILL OPENS THE WINDOW. Three of
    # the four tabs have nothing to do with the ADK.
    $component = @()

    try {
        $component = @(Get-HDTAdkComponent -Architecture $architecture -FileSystem $FileSystem)
    } catch {
        Write-Warning ("the ADK component list could not be read, so the Features tab is empty: {0}" -f
            $_.Exception.Message)
    }

    # THE GROUPS THIS SHARE HAS, so the Drivers tab is a list rather than a box
    # to spell a folder name into. A share with none imported yet answers
    # nothing, and the only choice on that tab is "no drivers" - which is the
    # truth about that share.
    $driverGroup = @(Get-HDTDriverGroup -Root (Split-Path -Parent $Path) -FileSystem $FileSystem)

    $size = Resolve-HDTConsoleEditorSize -OwnerWidth $OwnerWidth -OwnerHeight $OwnerHeight -Screen $Screen

    # THE TIME ZONES THIS BUILD HOST KNOWS. Read here rather than in the view
    # model for the same reason the ADK list is: it comes off this machine's
    # registry, and a window is the only caller that needs it.
    $timeZone = @(Get-HDTTimeZone)

    $answer = [string] $ConsoleHost.ShowBootImage(
        [System.IO.File]::ReadAllText($XamlPath), $Path, $line,
        [object[]] @($component), [object[]] @($driverGroup),
        (Get-HDTConsoleTheme -Name $Theme), $size, $Theme, [object[]] @($timeZone))

    $action = 'Close'
    if (-not [string]::IsNullOrWhiteSpace($answer)) { $action = $answer }

    return [pscustomobject] @{
        Action         = $action
        DocumentPath   = $Path
        Architecture   = $architecture
        ComponentCount = @($component).Count
    }
}
