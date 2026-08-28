function New-HDTDriverFolder {
    <#
        .SYNOPSIS
            Creates a folder in the share's driver store.

        .DESCRIPTION
            Deployment Workbench's New Folder on Out-of-Box Drivers, and the
            thing a selection profile has nothing to tick without: the profile
            editor's tree offers folders the share actually HAS, so a share whose
            Drivers\ is empty is one where a profile can be created and never
            filled.

            A DRIVER FOLDER IS A REAL DIRECTORY, not a label in a document. That
            is what makes it different from Add-HDTWorkspaceFolder, which writes
            a folder: into a task sequence or an application. A profile includes
            a PATH, the build hands that path to Add-WindowsDriver, and DISM
            needs it to exist.

            IT CREATES THE WHOLE PATH IN ONE CALL, because a Make\Model layout
            is two levels and a vendor's WinPE pack is usually two as well -
            'Dell\Latitude 7450', 'WinPE\HP WinPE 11 x64'. Creating them one at a
            time would be two clicks for one idea.

            IT CREATES Drivers\ ITSELF IF THE SHARE HAS NOT GOT ONE. That is not
            hypothetical: a share made before New-HDTWorkspace created the folder
            has no Drivers\ at all, and the first folder anybody adds has to work
            anyway.

            A FOLDER THAT IS ALREADY THERE IS NOT AN ERROR. It reports
            Created = $false and changes nothing, so a console that offers New
            Folder twice does not punish the second press.

            THE TRAVERSAL RULES ARE THE PROFILE'S OWN. A folder called
            '..\..\Windows' would put a directory outside the share and then
            invite a profile to include it, which is the boot image attack the
            profile validator already refuses - so the same check runs here,
            against Drivers\ rather than against all five content folders.

        .PARAMETER Root
            The deployment share root.

        .PARAMETER Path
            The folder to create, relative to Drivers\.

        .PARAMETER FileSystem
            The IFileSystem to write with. Omitted, the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path, FullPath and
            Created.

        .EXAMPLE
            New-HDTDriverFolder -Root 'C:\HDTLab\Share' -Path 'WinPE'

            The folder the vendor boot packs go under.

        .EXAMPLE
            New-HDTDriverFolder -Root 'C:\HDTLab\Share' -Path 'Dell\Latitude 7450'

            MDT's Total Control layout - a folder per Make\Model - in one call.

        .LINK
            Import-HDTDriver

        .LINK
            New-HDTSelectionProfile
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE PROFILE'S OWN CHECK, aimed at Drivers\. Composing it rather than
    # writing a second set of rules is what stops the two coming to disagree
    # about what a legal path is.
    $failure = Get-HDTSelectionProfilePathFailure `
        -Include ([System.IO.Path]::Combine('Drivers', $Path.TrimStart('\', '/'))) `
        -ContentFolder @('Drivers')

    if (-not [string]::IsNullOrEmpty($failure)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path `
                    -Message ("'{0}' cannot be a driver folder: {1}" -f $Path, $failure)))
    }

    $full = [System.IO.Path]::Combine((Get-HDTWorkspacePath -Root $Root -Kind Drivers),
        $Path.TrimStart('\', '/'))

    if ($FileSystem.TestPath($full)) {
        return [pscustomobject] @{ Path = $Path; FullPath = $full; Created = $false }
    }

    if (-not $PSCmdlet.ShouldProcess($full, 'Create this driver folder')) {
        return [pscustomobject] @{ Path = $Path; FullPath = $full; Created = $false }
    }

    # CreateDirectory MAKES THE PARENTS TOO, which is what lets 'Dell\Latitude
    # 7450' and a missing Drivers\ both be one call.
    $FileSystem.CreateDirectory($full)

    return [pscustomobject] @{ Path = $Path; FullPath = $full; Created = $true }
}
