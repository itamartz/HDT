function ConvertFrom-HDTWorkspaceLine {
    <#
        .SYNOPSIS
            Reads a spliced workspace document with the engine's own reader,
            without a file existing anywhere.

        .DESCRIPTION
            THE GATE EVERY WORKSPACE EDIT PASSES THROUGH, AND THE WAY EVERY ONE OF
            THEM LEARNS WHAT THE DOCUMENT CURRENTLY SAYS. The authoring commands
            write nothing, so nothing they do can corrupt a share - but an edit
            that produces a document the engine refuses is still a failure, and
            one that surfaces at Save, after several more edits have been stacked
            on top of it, is a failure nobody can attribute to the edit that
            caused it. Checking here names the edit that was wrong at the moment
            it was made.

            IT USES THE ENGINE'S OWN READER AND THE ENGINE'S OWN VALIDATOR, not a
            second opinion written for the editor. Two validators that agree today
            diverge the first time one of them is fixed, and the symptom is a
            green editor and a red boot image build.

            IT ALSO ANSWERS "WHAT DOES THIS DOCUMENT MEAN RIGHT NOW", WITH THE
            DEFAULTS APPLIED, which is what makes an add to an unstated
            optionalComponents list able to keep the three components that list
            would have taken by default. Reading them from the projection means
            the defaults are declared in exactly one place - the reader - rather
            than copied into every command that has to respect them.

            IT PARSES A COPY IN MEMORY. No file is read and none is written; the
            caller still holds the only copy of the edit.

        .PARAMETER Line
            The document, already split into lines.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            The same object Import-HDTWorkspaceDocument returns.

        .EXAMPLE
            $workspace = ConvertFrom-HDTWorkspaceLine -Line $result
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # The document is not on a share yet, so the locator in any message is the
    # file's name rather than a path the administrator has never seen.
    $label = 'workspace.yaml'

    $reader = New-HDTFileSystemFromText -Path $label -Text (@($Line) -join "`n")

    return Import-HDTWorkspaceDocument -Path $label -FileSystem $reader
}
