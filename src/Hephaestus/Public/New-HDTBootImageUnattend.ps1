function New-HDTBootImageUnattend {
    <#
        .SYNOPSIS
            Puts this module's WinPE answer file template on the share.

        .DESCRIPTION
            THE OTHER HALF OF Set-HDTBootImageUnattend. That command names a
            file in workspace.yaml and deliberately does not check whether it
            exists - a document is not a filesystem. This one makes the file
            exist, and it makes it exist with something in it.

            WHAT IT WRITES IS Templates\unattend-winpe.xml, the document this
            module ships: a windowsPE pass setting the display to 1024x768,
            which is what the deployment wizard was laid out for and larger than
            the 800x600 WinPE falls back to. It launches nothing - startnet.cmd
            already starts the engine, and a RunSynchronous here would start a
            second one against the same share and the same log.

            IT IS A COPY, NOT A LINK. The file is the administrator's from the
            moment it lands: wpeinit also reads EnableFirewall, EnableNetwork,
            LogPath, PageFile and Restart, and setting any of them means editing
            this file. Upgrading the module does not change a share's copy, and
            that is the point.

            IT RETURNS Relative AS WELL AS Path because workspace.yaml wants the
            relative one. A rooted path is legal there - Update-HDTBootImage
            resolves both - but a file that lives on the share written as
            C:\HDTLab\Share\Unattend-PE.xml names one build host's drive letter
            in a document every build host reads.

            IT REFUSES AN EXISTING FILE. Somebody's answer file, with their
            firewall setting in it, is not this command's to replace on the way
            past; -Force is how that is said out loud.

        .PARAMETER Workspace
            The deployment share's root.

        .PARAMETER Path
            Where on the share to write it, relative to the root. Defaults to
            Unattend-PE.xml, which is what MDT's boot image answer file is
            called minus MDT's architecture suffix.

        .PARAMETER Force
            Overwrite an answer file that is already there.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path and Relative.

        .EXAMPLE
            New-HDTBootImageUnattend -Workspace C:\HDTLab\Share

        .EXAMPLE
            $made = New-HDTBootImageUnattend -Workspace C:\HDTLab\Share
            $line = Set-HDTBootImageUnattend -Line $line -Path $made.Relative

            The two halves: the file exists, and the document names it.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Workspace,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path = 'Unattend-PE.xml',

        [Parameter()]
        [switch] $Force,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # ON THE SHARE, WHICH IS WHAT MAKES Relative MEAN ANYTHING. A rooted path
    # here would write outside the workspace and hand back a Relative naming
    # nothing.
    if ([System.IO.Path]::IsPathRooted($Path)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path `
                    -Message ("'{0}' is a rooted path. This writes the answer file onto the share, so the name is relative to it - Unattend-PE.xml, or Config\WinPE.xml. To name a file you keep elsewhere, use Set-HDTBootImageUnattend on its own." -f $Path)))
    }

    $target = [System.IO.Path]::Combine($Workspace, $Path)

    if ($FileSystem.TestPath($target) -and -not $Force) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $target -Category ResourceExists `
                    -Message ("there is already an answer file at '{0}'. It may be the one somebody set the WinPE firewall in; pass -Force to replace it." -f $target)))
    }

    # THE MODULE'S OWN COPY IS READ WITH THE MODULE'S OWN FILESYSTEM, not with
    # the injected one: the injected one describes the share, and under a fake
    # it describes a share that has no module in it.
    $source = Join-Path -Path (Join-Path -Path $script:HDTModuleRoot -ChildPath 'Templates') `
        -ChildPath 'unattend-winpe.xml'

    $moduleFileSystem = New-HDTFileSystem

    if (-not $moduleFileSystem.TestPath($source)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $source -Category ObjectNotFound `
                    -Message ("this module ships a WinPE answer file template and it is not at '{0}'. The install is incomplete." -f $source)))
    }

    if (-not $PSCmdlet.ShouldProcess($target, 'Write the WinPE answer file template')) {
        return [pscustomobject] @{
            Path     = [string] $target
            Relative = [string] $Path
        }
    }

    $folder = [System.IO.Path]::GetDirectoryName($target)

    if (-not [string]::IsNullOrWhiteSpace($folder) -and -not $FileSystem.TestPath($folder)) {
        [void] $FileSystem.CreateDirectory($folder)
    }

    $FileSystem.WriteAllText($target, [string] $moduleFileSystem.ReadAllText($source))

    return [pscustomobject] @{
        Path     = [string] $target
        Relative = [string] $Path
    }
}
