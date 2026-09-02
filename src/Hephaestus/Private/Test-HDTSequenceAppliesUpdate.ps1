function Test-HDTSequenceAppliesUpdate {
    <#
        .SYNOPSIS
            Whether a task sequence document would apply the updates of a given
            release.

        .DESCRIPTION
            WHAT Remove-HDTWindowsUpdate HAS TO KNOW before it deletes anything,
            and it is Test-HDTSequenceNamesApplication's twin - the same tree
            walk, the same refusal to treat a text match as a fact.

            IT ASKS ABOUT BOTH, AND THE ID WINS WHERE THERE IS ONE. An
            ApplyUpdates step names a release, and MAY ALSO name ids in
            `updates` - and those two questions have different answers and
            different consequences. A step that applies a release and no ids
            deploys without a removed update; a step that NAMES the id points at
            WindowsUpdates\<id>\ by name and refuses at the machine once the
            folder is gone (Invoke-HDTApplyUpdatesStep).

            SO A STEP THAT NAMES IDS IS ANSWERED BY ITS IDS, not by its release.
            Reading the release for such a step would name a sequence for an
            update it explicitly does not apply - which is the warning crying
            wolf about the one case it exists to warn about.

            IT WALKS THE TREE, because a sequence of any size is one and a scan
            of the top level would miss nearly every step in the share.

            AN EMPTY release IS "EVERYTHING IMPORTED" and so it is a match. The
            step template says as much in as many words, and a sequence with one
            would have applied this update.

            AN EMPTY updates IS "EVERY UPDATE FOR THE RELEASE", which narrows
            nothing - so it falls through to the release, which is what the
            shipped template writes and what nearly every step means.

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

        .PARAMETER Id
            The update's catalog id - the folder name under WindowsUpdates\.
            Optional: a caller that does not pass one is asking the release
            question alone, which is what this answered before `updates`
            existed.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTSequenceAppliesUpdate -Document $parsed -Release 'Win11-24H2' -Id 'KB5094126-x64'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Document,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Release,

        [Parameter(Position = 2)]
        [AllowEmptyString()]
        [string] $Id = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Document -or -not ($Document -is [System.Collections.IDictionary])) { return $false }

    $wanted = $Release.Trim()
    $wantedId = $Id.Trim()

    # THE IDS A STEP NAMES, AS THE DOCUMENT SPELLS THEM. A YAML sequence or a
    # comma line, matching Invoke-HDTApplyUpdatesStep - but NOT expanded, because
    # this reads a document and has no variable scope to expand against.
    $namedId = {
        param($Node)

        if (-not $Node.Contains('updates')) { return [string[]] @() }

        $raw = $Node['updates']

        if ($raw -is [System.Collections.IList] -and -not ($raw -is [string])) {
            return [string[]] @(@($raw) | ForEach-Object { ([string] $_).Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        return [string[]] @(@([string] $raw -split '[,;]') | ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

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

            # THE IDS FIRST, BECAUSE THEY ARE THE STRONGER STATEMENT. A step
            # that names any is answered by them and never by its release.
            $named = @(& $namedId $current)

            # A LIST THAT IS ALL VARIABLES IS NOT A LIST OF IDS. Same rule as the
            # release below and for the same reason: '%HDTUpdates%' is resolved
            # from the rules at run time, so what it will name cannot be read
            # from the document. Falling through to the release is the honest
            # answer - it is what the step applies if the variable resolves to
            # nothing.
            $literal = @(@($named) | Where-Object { $_ -notmatch '%' })

            if ($literal.Count -gt 0) {
                if ([string]::IsNullOrWhiteSpace($wantedId)) { continue }

                foreach ($one in $literal) {
                    if ([string]::Equals($one, $wantedId, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return $true
                    }
                }

                continue
            }

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
