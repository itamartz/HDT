function Set-HDTBootImageBackground {
    <#
        .SYNOPSIS
            Names the image WinPE shows behind everything.

        .DESCRIPTION
            MDT'S "custom background bitmap file", and HDT has one for a
            narrower reason. DESIGN 11.1 solves the bare-prompt problem with the
            progress window's own full-screen ground rather than with a
            wallpaper - that is why the toolkit does not NEED one - but the boot
            image still has a desktop behind that window, and an administrator
            who wants it branded should not have to hand-edit YAML to get it.

            WinPE READS ONE FILE AND IT IS A JPEG. The background is
            \Windows\System32\winpe.jpg inside the image; the build copies
            whatever is named here over that path, under that name. A .png or a
            a .bmp would be carried into the image and never shown - a build
            succeeds and a background that does not appear, which is the worst
            way to learn the rule - so the extension is refused here, at the
            moment somebody types it.

            THE PATH IS A PATH, exactly as the answer file's is: relative to the
            share root, or rooted on the build host. Browse hands back wherever
            the administrator keeps their branding.

            WHETHER IT EXISTS IS NOT CHECKED HERE. This edits a document; the
            file is read at build time, and Update-HDTBootImage refuses a named
            background it cannot find BEFORE it mounts anything.

        .PARAMETER Line
            The workspace.yaml lines to edit. Returned spliced, with every line
            this command was not asked to change byte-identical.

        .PARAMETER Path
            The image. Branding\winpe.jpg is read relative to the share;
            C:\Branding\winpe.jpg is read from there. It must be a .jpg or a
            or .jpeg.

        .PARAMETER Clear
            Build the image with the WinPE background Microsoft ships. The key
            is removed, not written empty.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the workspace.yaml lines, spliced.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\workspace.yaml'))
            $line = Set-HDTBootImageBackground -Line $line -Path 'C:\HDTLab\Branding\winpe.jpg'
            Save-HDTWorkspaceDocument -Path 'C:\HDTLab\Share\workspace.yaml' -Line $line

            The picture WinPE shows behind everything. The next Update-HDTBootImage is
            what puts it in the image.

        .EXAMPLE
            $line = Set-HDTBootImageBackground -Line $line -Clear

            Back to the WinPE default. -Clear and -Path are the same decision written
            two ways, so one of them has to be given.

    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'File')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1, ParameterSetName = 'File')]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true, ParameterSetName = 'Clear')]
        [switch] $Clear
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    [void] (ConvertFrom-HDTWorkspaceLine -Line $Line)

    if ($Clear) {
        if (-not $PSCmdlet.ShouldProcess('bootImage: background', 'Use the WinPE background Microsoft ships')) {
            return [string[]] @($Line)
        }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'background') `
                -Text ([string[]] @()))
    } else {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path `
                        -Message 'a background is a path to a .jpg. Pass -Clear to use the one WinPE ships.'))
        }

        # REFUSED AT THE MOMENT IT IS TYPED. See the header: WinPE reads
        # winpe.jpg and nothing else, so any other format is a file the image
        # carries and never shows.
        if ($Path -notmatch '\.(jpg|jpeg)$') {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path `
                        -Message ("'{0}' is not a .jpg. WinPE's background is \Windows\System32\winpe.jpg and it must be a JPEG - anything else is copied into the image and never shown, which is a build that succeeds and a background that does not appear." -f $Path)))
        }

        if (-not $PSCmdlet.ShouldProcess($Path, 'Show this behind everything in WinPE')) {
            return [string[]] @($Line)
        }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'background') `
                -Text ([string[]] @('background: {0}' -f (ConvertTo-HDTRuleScalarText -Value $Path))))
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
