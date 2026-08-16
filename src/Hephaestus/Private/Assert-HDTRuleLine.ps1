function Assert-HDTRuleLine {
    <#
        .SYNOPSIS
            Holds a spliced rules document to the engine's own validators before
            the lines are handed back.

        .DESCRIPTION
            THE GATE EVERY RULE EDIT PASSES THROUGH. Add, Set and Remove write
            nothing, so nothing they do can corrupt a share - but an edit that
            produces a document the engine refuses is still a failure, and one
            that surfaces at Save, after several more edits have been stacked on
            top of it, is a failure nobody can attribute to the edit that caused
            it. Checking here names the edit that was wrong at the moment it was
            made.

            IT USES THE ENGINE'S OWN READER AND THE ENGINE'S OWN VALIDATOR, not a
            second opinion written for the editor. Two validators that agree
            today diverge the first time one of them is fixed, and the symptom is
            a green editor and a red deployment.

            IT PARSES A COPY IN MEMORY. No file is read and none is written; the
            caller still holds the only copy of the edit.

        .PARAMETER Line
            The spliced document.

        .OUTPUTS
            None. It throws or it returns nothing.

        .EXAMPLE
            Assert-HDTRuleLine -Line $result
    #>
    [CmdletBinding()]
    [OutputType([void])]
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
    $label = 'rules.yaml'

    $document = ConvertFrom-HDTYaml -Yaml ($Line -join "`n") -Path $label

    Assert-HDTRuleDocument -Document $document -Path $label
}
