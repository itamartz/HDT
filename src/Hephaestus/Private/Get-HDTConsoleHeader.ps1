function Get-HDTConsoleHeader {
    <#
        .SYNOPSIS
            Builds what the banner says while a row of one share is selected.

        .DESCRIPTION
            BOTH PATHS, ALWAYS. The share an administrator opened and the
            deployRoot that share declares are different facts and are routinely
            different strings: the lab share is C:\HDTLab\Share on the host and
            \\192.168.2.108\HDTShare to a machine that booted the image, and the
            boot image carries only the second. Editing a share that no client
            can reach, and not being able to see why, is the mistake this banner
            exists to make impossible.

            EMPTY IS NEVER SHOWN. A share that failed to open has no name and no
            deployRoot, and a blank banner beside a tree full of rows reads as a
            console that lost its place rather than a share that would not open.

        .PARAMETER Workspace
            A share from Get-HDTConsoleWorkspace, or a failure from
            New-HDTConsoleShareFailure.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Title, Root and
            DeployRoot.

        .EXAMPLE
            Get-HDTConsoleHeader -Workspace $share
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Workspace
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $title = Get-HDTConsoleDisplayText -Text $Workspace.Name -Fallback $Workspace.Root

    return [pscustomobject] @{
        Title      = $title
        Root       = Get-HDTConsoleDisplayText -Text $Workspace.Root -Fallback '(unknown)'
        DeployRoot = Get-HDTConsoleDisplayText -Text $Workspace.DeployRoot -Fallback '(the share could not be read)'
    }
}
