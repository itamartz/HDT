function Set-HDTBootImageUnattend {
    <#
        .SYNOPSIS
            Names the WinPE answer file the boot image is built with.

        .DESCRIPTION
            THIS IS WinPE'S ANSWER FILE, NOT THE DEPLOYED OS'S. They are both
            called unattend.xml and they are read by different things at
            different times, which is how one ends up in the other's place.
            This one is processed by wpeinit when WinPE starts; the deployed
            machine's belongs to the task sequence and is applied to the image
            on disk.

            WHAT wpeinit ACCEPTS is a short, fixed list - Display,
            EnableFirewall, EnableNetwork, LogPath, PageFile, Restart,
            RunSynchronous and RunAsynchronous. Everything else in the file is
            ignored, silently. THE FIREWALL IS THE ONE PEOPLE COME LOOKING FOR:
            `wpeutil disablefirewall` is a command a technician types at a
            prompt, and it is gone on the next boot. An image built with this is
            the same setting, every time, without anybody typing it.

            THE PATH IS A PATH, exactly as extraContent's SOURCE is: relative to
            the share root, or rooted on the build host. An earlier version
            refused a rooted one, reasoning that the answer file was share
            content - a rule this command invented and nothing else in the
            workspace holds. The file an administrator browses to is wherever
            they keep it, and Update-HDTBootImage resolves both forms.

            WHETHER IT EXISTS IS NOT CHECKED HERE. This edits a document; the
            file is read at build time, and Update-HDTBootImage refuses a named
            answer file it cannot find BEFORE it mounts anything.

            IT IS SHAPED LIKE Set-HDTBootImageDriver ON PURPOSE - one value,
            -Clear to take it away, and the key removed rather than written
            empty. Two commands doing the same kind of thing to the same block
            should not have to be learned twice.

        .PARAMETER Line
            The workspace.yaml lines to edit. Returned spliced, with every line
            this command was not asked to change byte-identical.

        .PARAMETER Path
            The answer file. Unattend-PE.xml is read relative to the share;
            C:\build\Unattend-PE.xml is read from there.

        .PARAMETER Clear
            Build the image with no answer file. The key is removed, not written
            empty: an empty unattend is a document saying "there is a file" and
            naming none, and the engine refuses it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the workspace.yaml lines, spliced.

        .EXAMPLE
            $line = Get-Content -LiteralPath 'C:\HDTLab\Share\workspace.yaml'
            $line = Set-HDTBootImageUnattend -Line $line -Path 'Unattend-PE.xml'
            Save-HDTWorkspaceDocument -Line $line -Path 'C:\HDTLab\Share\workspace.yaml'

        .EXAMPLE
            Set-HDTBootImageUnattend -Line $line -Clear

            Back to a plain wpeinit.
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

    # The document has to be readable before it is worth editing.
    [void] (ConvertFrom-HDTWorkspaceLine -Line $Line)

    # Read from the switch rather than from the parameter set name, as
    # Set-HDTBootImageDriver does: the two say the same thing, and the switch is
    # the half a reader, and PSScriptAnalyzer, can follow.
    if ($Clear) {
        if (-not $PSCmdlet.ShouldProcess('bootImage: unattend', 'Build the boot image with no answer file')) {
            return [string[]] @($Line)
        }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'unattend') `
                -Text ([string[]] @()))
    } else {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Path `
                        -Message 'an answer file is a path on the share, for example Unattend-PE.xml. Pass -Clear to build the image with none.'))
        }

        if (-not $PSCmdlet.ShouldProcess($Path, 'Build the boot image with this WinPE answer file')) {
            return [string[]] @($Line)
        }

        $result = [string[]] @(Set-HDTWorkspaceKey -Line $Line -Path @('bootImage', 'unattend') `
                -Text ([string[]] @('unattend: {0}' -f (ConvertTo-HDTRuleScalarText -Value $Path))))
    }

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
