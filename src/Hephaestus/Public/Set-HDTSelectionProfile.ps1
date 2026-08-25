function Set-HDTSelectionProfile {
    <#
        .SYNOPSIS
            Changes a selection profile's name or what it includes, leaving every
            other line of the document byte-identical.

        .DESCRIPTION
            What the console's profile editor runs when Save is pressed, and what
            an administrator types to add a vendor pack to a profile that already
            has one.

            IT REWRITES ONE ENTRY'S LINES AND NOTHING ELSE. The profiles above
            and below it keep their comments, their spacing and their order - see
            Get-HDTSelectionProfileLineMap for how the entry's extent is found,
            and why a trailing comment is left to whatever follows.

            -Name AND -Include ARE INDEPENDENT. Renaming a profile must not
            silently empty it, and repointing one must not silently rename it,
            so a parameter that was not passed is a value that is not touched.

            AN EMPTY -Include EMPTIES THE PROFILE, which is different from
            omitting it. It is how the console says "I unticked everything", and
            it writes 'include: []' rather than dropping the key - a profile with
            no include key is a document the validator refuses.

            A BUILT-IN IS REFUSED, AND THE MESSAGE SAYS SO. all-drivers,
            everything and nothing have no lines in any document; answering
            "it is not in this document" would be true and useless.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTSelectionProfileDocument
            is what touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Id
            The profile to change.

        .PARAMETER Name
            The new display name. Omitted, the name is left alone.

        .PARAMETER Include
            The new include list, replacing the old one entirely. Omitted, what
            the profile includes is left alone.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the profile changed.

        .EXAMPLE
            $line = Set-HDTSelectionProfile -Line $line -Id 'boot-critical' -Include 'Drivers\WinPE\Dell WinPE 11 x64', 'Drivers\WinPE\HP WinPE 11 x64'

            Both vendor packs on the profile the boot image points at.

        .EXAMPLE
            $line = Set-HDTSelectionProfile -Line $line -Id 'boot-critical' -Name 'WinPE - both vendors'

            A rename, with the two folders untouched.

        .LINK
            New-HDTSelectionProfile

        .LINK
            Save-HDTSelectionProfileDocument
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter(Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Position = 3)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Include
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $text = [string[]] @($Line)

    $checkInclude = @()
    if ($PSBoundParameters.ContainsKey('Include')) { $checkInclude = @($Include) }

    Assert-HDTSelectionProfileId -Id $Id -Include $checkInclude -Cmdlet $PSCmdlet

    if ((-not $PSBoundParameters.ContainsKey('Name')) -and (-not $PSBoundParameters.ContainsKey('Include'))) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                    -Message 'nothing was asked for. Pass -Name to rename the profile, -Include to change what it includes, or both.'))
    }

    $map = Get-HDTSelectionProfileLineMap -Line $text
    $entry = @($map.Entry | Where-Object { $_.Id -eq $Id })

    if (@($entry).Count -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                    -Message ("no profile with the id '{0}' is in this document. The ids it declares are {1}." -f
                        $Id, (@($map.Entry | ForEach-Object { $_.Id }) -join ', ')) `
                    -Category ObjectNotFound))
    }

    $target = @($entry)[0]

    # WHAT THE ENTRY SAYS NOW, for the half the caller did not pass. Read from the
    # parsed document rather than from the lines: 'name: '\''Dell'\''' is a quoted
    # scalar, and unquoting it by hand here would be a second, worse YAML parser.
    $existing = ConvertFrom-HDTYaml -Yaml ($text -join "`r`n") -Path 'selection-profiles.yaml'
    $current = @($existing['profiles'] | Where-Object { [string] $_['id'] -eq $Id })[0]

    $newName = [string] $current['name']
    if ($PSBoundParameters.ContainsKey('Name')) { $newName = $Name }

    $newInclude = @()
    if ($null -ne $current['include']) { $newInclude = @($current['include'] | ForEach-Object { [string] $_ }) }
    if ($PSBoundParameters.ContainsKey('Include')) { $newInclude = @($Include) }

    if (-not $PSCmdlet.ShouldProcess($Id, 'Change this selection profile')) {
        return [string[]] $text
    }

    $entryLine = ConvertTo-HDTSelectionProfileLine -Id $Id -Name $newName -Include $newInclude -Indent $map.Indent

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $text.Count; $i++) {
        if ($i -eq $target.Start) {
            foreach ($replacement in $entryLine) { [void] $result.Add($replacement) }
            continue
        }

        if (($i -gt $target.Start) -and ($i -le $target.End)) { continue }

        [void] $result.Add($text[$i])
    }

    return [string[]] @($result)
}
