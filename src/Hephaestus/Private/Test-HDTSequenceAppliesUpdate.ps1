function Test-HDTSequenceAppliesUpdate {
    <#
        .SYNOPSIS
            Whether a task sequence document would apply the updates of a given
            release.

        .DESCRIPTION
            WHAT Remove-HDTWindowsUpdate HAS TO KNOW before it deletes anything,
            and it is Test-HDTSequenceNamesApplication's twin - the same tree
            walk, the same refusal to treat a text match as a fact.

            IT ASKS ABOUT A RELEASE AND NOT ABOUT AN ID, because that is all an
            ApplyUpdates step names. Nothing in a sequence points at
            WindowsUpdates\<id>\ by name, so removing one update breaks no
            sequence: the machine simply arrives without it. That is why this
            answers a warning rather than a refusal.

            IT WALKS THE TREE, because a sequence of any size is one and a scan
            of the top level would miss nearly every step in the share.

            AN EMPTY release IS "EVERYTHING IMPORTED" and so it is a match. The
            step template says as much in as many words, and a sequence with one
            would have applied this update.

            A RELEASE THAT IS A VARIABLE IS NOT A MATCH, which is
            Test-HDTSequenceNamesApplication's rule and it holds here for that
            command's reason and for one of its own: '%HDTOSRelease%' is resolved
            from the rules at run time, so what it will apply cannot be read from
            the document - AND it is the shipped template's default, so answering
            yes would name every sequence on the share for every update and leave
            the warning saying nothing.

        .PARAMETER Document
            The parsed sequence, as ConvertFrom-HDTYaml returns it.

        .PARAMETER Release
            The release id the update is filed under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTSequenceAppliesUpdate -Document $parsed -Release 'Win11-24H2'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Document,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Release
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Document -or -not ($Document -is [System.Collections.IDictionary])) { return $false }

    $wanted = $Release.Trim()

    $applies = {
        param($Step)

        foreach ($current in @($Step)) {
            if ($null -eq $current -or -not ($current -is [System.Collections.IDictionary])) { continue }

            # A GROUP HOLDS STEPS, and its own type is not ApplyUpdates - so the
            # walk happens whatever this step turns out to be.
            if ($current.Contains('steps')) {
                if (& $applies $current['steps']) { return $true }
            }

            $type = ''
            if ($current.Contains('type')) { $type = [string] $current['type'] }

            if ($type -ne 'ApplyUpdates') { continue }

            # THE KEY MAY NOT BE THERE AT ALL, and an absent release is the same
            # statement as an empty one: apply everything imported.
            $release = ''
            if ($current.Contains('release')) { $release = [string] $current['release'] }

            if ([string]::IsNullOrWhiteSpace($release)) { return $true }

            # SEE THE NOTE ABOVE: what a variable resolves to is not in this
            # document, and guessing makes the report worthless.
            if ($release -match '%') { continue }

            if ([string]::Equals($release.Trim(), $wanted, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }

        return $false
    }

    if (-not $Document.Contains('steps')) { return $false }

    return [bool] (& $applies $Document['steps'])
}
