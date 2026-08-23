function Remove-HDTBootImageContent {
    <#
        .SYNOPSIS
            Stops a folder or file being copied into the boot image, leaving
            every other line of workspace.yaml byte-identical.

        .DESCRIPTION
            The command an administrator types to take a tool back out of the
            WinPE image, and the one anything with a Remove button has to run.

            IT REFUSES TO GUESS. Two entries may legally land on the same
            destination - that is how content is merged into one folder - so a
            destination that names two of them is an error rather than a coin
            toss. Name the source as well and the ambiguity is gone.

            THE COMMAND THAT STARTED IT IS NOT REMOVED WITH IT. startCommand and
            extraContent are separate lists on purpose: a tool may be started from
            somewhere else in the image, and a command left pointing at nothing is
            a line in startnet.cmd that fails visibly rather than a deletion the
            administrator did not ask for. Run
            Remove-HDTBootImageStartCommand for that.

            THE KEY GOES WITH THE LAST ENTRY. `extraContent:` with nothing under
            it parses as a null, and the engine refuses a workspace whose
            extraContent is not a list - so a removal that left the key behind
            would produce a document that cannot be loaded. If that empties the
            bootImage block, the block goes too.

            IT SPLICES LINES AND NEVER PARSES AND RE-EMITS, so the comment above
            the entry's neighbour and the header at the top of the file come back
            exactly as they went in.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTWorkspaceDocument is what
            touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Destination
            The destination of the entry to remove.

        .PARAMETER Source
            The source, when two entries share a destination.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the entry removed.

        .EXAMPLE
            $line = [string[]] @([System.IO.File]::ReadAllLines('C:\HDTLab\Share\workspace.yaml'))
            Remove-HDTBootImageContent -Line $line -Destination '\HDT\Tools\BGInfo'

        .EXAMPLE
            Remove-HDTBootImageContent -Line $line -Destination '\HDT\Tools\BGInfo' -Source 'Tools\BGInfoConfig'

            The one of two entries that merge into that folder.

        .LINK
            Add-HDTBootImageContent
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Destination,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Source
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $workspace = ConvertFrom-HDTWorkspaceLine -Line $Line
    $entry = @($workspace.BootImage.ExtraContent)

    $match = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt @($entry).Count; $i++) {
        if (([string] $entry[$i].Destination) -ne $Destination) { continue }
        if ($PSBoundParameters.ContainsKey('Source') -and ([string] $entry[$i].Source) -ne $Source) { continue }

        [void] $match.Add($i)
    }

    if (@($match).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Destination -Category ObjectNotFound `
                    -Message ("this document copies nothing to '{0}'. A removal that quietly did nothing would look exactly like one that worked." -f $Destination)))
    }

    if (@($match).Count -gt 1) {
        $source = @($match | ForEach-Object { "'{0}'" -f [string] $entry[$_].Source }) -join ', '

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Destination `
                    -Message ("{0} entries copy to '{1}' - from {2} - and this command will not guess which one you meant. Pass -Source to name it." -f
                        @($match).Count, $Destination, $source)))
    }

    if (-not $PSCmdlet.ShouldProcess($Destination, 'Stop copying this into the boot image')) {
        return [string[]] @($Line)
    }

    $result = [string[]] @(Remove-HDTWorkspaceItem -Line $Line -Path @('bootImage', 'extraContent') `
            -Position ([int] $match[0]))

    try {
        [void] (ConvertFrom-HDTWorkspaceLine -Line $result)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
