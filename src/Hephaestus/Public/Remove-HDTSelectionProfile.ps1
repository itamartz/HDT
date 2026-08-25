function Remove-HDTSelectionProfile {
    <#
        .SYNOPSIS
            Takes a selection profile out of a document, leaving every other line
            byte-identical.

        .DESCRIPTION
            The console's Delete button, and the one command in this family that
            destroys authored configuration - so it declares SupportsShouldProcess
            and answers to -WhatIf.

            IT TAKES THE WHOLE ENTRY, not the id line. A profile is a dash, a
            name and an include list, and removing only the line that names it
            would leave the rest behind as a nameless entry the validator
            refuses.

            IT LEAVES A COMMENT ABOVE THE PROFILE ALONE. A sentence an
            administrator wrote is theirs, it is as likely to be about the
            profile below as the one above, and a delete that silently takes
            somebody's note with it is the kind of thing found weeks later.

            REMOVING THE LAST PROFILE LEAVES 'profiles: []', NOT A BARE KEY. A
            profiles: with nothing under it parses as a null, and the validator
            refuses a document whose profiles is not a list - so leaving the husk
            would produce a file that cannot be loaded, from a command whose whole
            job was to take one profile away. Set-HDTWorkspaceKey removes an empty
            bootImage block for the same reason.

            A BUILT-IN IS REFUSED. all-drivers, everything and nothing are
            answered by the engine and have no lines to remove.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTSelectionProfileDocument
            is what touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Id
            The profile to remove.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document without the profile.

        .EXAMPLE
            $line = Remove-HDTSelectionProfile -Line $line -Id 'dell-winpe'
            Save-HDTSelectionProfileDocument -Path 'C:\HDTLab\Share\Control\selection-profiles.yaml' -Line $line

        .EXAMPLE
            Remove-HDTSelectionProfile -Line $line -Id 'dell-winpe' -WhatIf

            What it would take out, without taking it out.

        .LINK
            Set-HDTSelectionProfile
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Id
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $text = [string[]] @($Line)

    Assert-HDTSelectionProfileId -Id $Id -Cmdlet $PSCmdlet

    $map = Get-HDTSelectionProfileLineMap -Line $text
    $entry = @($map.Entry | Where-Object { $_.Id -eq $Id })

    if (@($entry).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                    -Message ("no profile with the id '{0}' is in this document. The ids it declares are {1}." -f
                        $Id, (@($map.Entry | ForEach-Object { $_.Id }) -join ', ')) `
                    -Category ObjectNotFound))
    }

    if (-not $PSCmdlet.ShouldProcess($Id, 'Remove this selection profile')) {
        return [string[]] $text
    }

    $target = @($entry)[0]
    $wasLast = (@($map.Entry).Count -eq 1)

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $text.Count; $i++) {
        if (($i -ge $target.Start) -and ($i -le $target.End)) { continue }

        if ($wasLast -and ($i -eq $map.ListIndex)) {
            [void] $result.Add(($text[$i] -replace '^(\s*profiles\s*:).*$', '$1 []'))
            continue
        }

        [void] $result.Add($text[$i])
    }

    return [string[]] @($result)
}
