function Import-HDTBootImageToWds {
    <#
        .SYNOPSIS
            Imports the HDT boot image into Windows Deployment Services,
            replacing an image of the same name rather than adding a second one.

        .DESCRIPTION
            DESIGN 6.1: "HDT does not ship a PXE server. WDS serves the WIM."
            This is the command that puts it there, and REPLACE-IN-PLACE IS THE
            WHOLE POINT OF IT ("WDS import replacing rather than
            duplicating an existing image").

            An MDT operator who has run Update-MDTDeploymentShare a dozen times
            recognises the failure this prevents: a PXE boot menu with a column of
            identically named images and no way to tell which one the fleet is
            actually booting. So this command asks the server what it already has,
            and when a row matches by name it REMOVES THAT ROW BEFORE IT IMPORTS -
            in that order, which is what the ordered journal in the unit suite
            asserts. An import before the remove would leave two images for a
            moment and then delete the new one.

            FIVE STEPS, AND THE ORDER IS THE CONTRACT:

              1. refuse a -Path that is not an existing .wim, NAMING
                 Update-HDTBootImage - and call nothing. A refusal that had
                 already asked the server for its image list is a refusal that
                 touched production;
              2. -ImageName defaults to the WIM's base name (HDTPE_x64);
              3. GetBootImage(<architecture>);
              4. a row matching -ImageName CASE-INSENSITIVELY, on the same
                 architecture: RemoveBootImage then ImportBootImage. Both are
                 logged at Info, naming the image being replaced and its previous
                 version, because an administrator needs to know what was thrown
                 away. No match: ImportBootImage alone;
              5. return ImageName, Architecture, Path, Replaced, PreviousVersion.

            SupportsShouldProcess, and not as decoration:
            step 4 deletes a boot image a fleet PXE boots from. Under -WhatIf
            NOTHING is called, including the read.

            IT HAS NEVER RUN AGAINST A REAL WDS SERVER. There is none on this
            host - it is Windows 11 Pro, and WDS is a Windows Server role - and
            PROJECT.md's lab safety rules forbid standing one up beside CM01's
            PXE responder. Everything above is asserted against
            New-HDTFakeWdsService; the one real assertion this machine can make
            is that New-HDTWdsService refuses with a named dependency error, and
            it is made against the real adapter.

        .PARAMETER Path
            The boot WIM to import, normally <workspace>\Boot\<name>.wim as
            Update-HDTBootImage wrote it.

        .PARAMETER ImageName
            What to call it on the server. Defaults to the WIM's base name.

        .PARAMETER Architecture
            The WDS image architecture: x64 (default), x86 or arm64. Note that
            this is WDS's vocabulary, not the ADK's - the ADK calls the same
            thing amd64.

        .PARAMETER WdsService
            An IWdsService. Defaults to the real adapter, which throws
            HDTDependencyError on a machine with no WDS module.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with ImageName,
            Architecture, Path, Replaced and PreviousVersion.

        .EXAMPLE
            Import-HDTBootImageToWds -Path 'C:\HDTLab\Share\Boot\HDTPE_x64.wim'

            Imports as HDTPE_x64, replacing an existing HDTPE_x64 if the server
            has one.

        .EXAMPLE
            Import-HDTBootImageToWds -Path $build.WimPath -ImageName 'HDT (test ring)' -WhatIf

            What it would remove and what it would import, without touching the
            server.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The noun is BootImageToWds, and Wds is the acronym for Windows Deployment Services - not a plural. The analyzer sees the trailing s. DESIGN 6.1 names this command.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ImageName,

        [Parameter()]
        [ValidateSet('x64', 'x86', 'arm64')]
        [string] $Architecture = 'x64',

        [Parameter()]
        [AllowNull()]
        [object] $WdsService,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # =====================================================================
    # 1. THE PATH, JUDGED BEFORE THE SERVICE IS EVEN BUILT
    # =====================================================================
    #
    # BEFORE, not after: the default -WdsService is New-HDTWdsService, which
    # throws on a machine with no WDS module, and a bad path should say so rather
    # than being masked by a dependency error. It is also what makes "it called
    # nothing" true of the refusal.

    if ([System.IO.Path]::GetExtension($Path) -ne '.wim') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("that is not a .wim, and Windows Deployment Services serves boot images as WIMs. Import the file Update-HDTBootImage wrote to <workspace>\Boot\<name>.wim; the .iso beside it is the debugging vehicle (DESIGN 6.1.1), not something WDS can serve.")))
    }

    if (-not $FileSystem.TestPath($Path)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path -Category ObjectNotFound `
                    -Message ("there is no boot image there to import. Run Update-HDTBootImage against the workspace first - it writes <workspace>\Boot\<name>.wim and the manifest beside it.")))
    }

    $name = $ImageName
    if (-not $PSBoundParameters.ContainsKey('ImageName')) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    }

    # =====================================================================
    # 2. WHAT THE SERVER ALREADY HAS
    # =====================================================================

    $description = 'Import boot image ''{0}'' ({1})' -f $name, $Architecture

    if (-not $PSCmdlet.ShouldProcess($Path, $description)) {
        return [pscustomobject] @{
            ImageName       = $name
            Architecture    = $Architecture
            Path            = $Path
            Replaced        = $false
            PreviousVersion = ''
        }
    }

    if ($null -eq $WdsService) { $WdsService = New-HDTWdsService }

    $existing = @($WdsService.GetBootImage($Architecture))

    # CASE-INSENSITIVELY. WDS image names are not case sensitive, and neither is
    # the decision about whether one is already there.
    $match = @($existing | Where-Object {
            [string] $_.ImageName -eq $name -or
            ([string] $_.ImageName).Equals($name, [System.StringComparison]::OrdinalIgnoreCase)
        })

    $replaced = $false
    $previousVersion = ''

    # =====================================================================
    # 3. REMOVE, THEN IMPORT - IN THAT ORDER
    # =====================================================================

    if ($match.Count -gt 0) {
        $previousVersion = [string] $match[0].Version
        $replaced = $true

        # WHAT WAS THROWN AWAY, said out loud. A fleet boots from this image;
        # a run that replaced one silently would leave nobody able to say what
        # the previous one was.
        Write-Information ("Replacing the existing WDS boot image '{0}' ({1}), version '{2}', file '{3}'. It is removed before the new image is imported, so the server ends with one image of this name rather than two." -f
            [string] $match[0].ImageName, $Architecture, $previousVersion, [string] $match[0].FileName)

        $WdsService.RemoveBootImage([string] $match[0].ImageName, $Architecture)
    }

    Write-Information ("Importing '{0}' into WDS as boot image '{1}' ({2})." -f $Path, $name, $Architecture)

    $WdsService.ImportBootImage($Path, $name, $Architecture)

    return [pscustomobject] @{
        ImageName       = $name
        Architecture    = $Architecture
        Path            = $Path
        Replaced        = $replaced
        PreviousVersion = $previousVersion
    }
}
