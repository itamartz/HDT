function Remove-HDTRule {
    <#
        .SYNOPSIS
            Removes one rule from a rules document, leaving every other line
            byte-identical.

        .DESCRIPTION
            The command an administrator types to delete a variable rule, and the
            one anything with a Remove button has to run.

            IT SPLICES LINES AND NEVER PARSES YAML. The parser yields a
            dictionary and a dictionary has no comments in it; a rules.yaml is
            created with a comment header carrying a worked example and collects
            an administrator's own notes from there on. A removal that
            round-tripped through the parser would hand back a file with every
            comment gone and every key reordered.

            THE COMMENT ABOVE THE RULE GOES WITH IT. A comment left behind
            attaches itself to whatever now sits beneath it, so the file ends up
            stating something untrue about a rule it was never about - worse than
            losing the comment.

            THE LAST RULE CANNOT BE REMOVED. A rules document declares at least
            one rule, so taking the last one out produces a file the engine
            refuses to load - and it would refuse at Save, after the
            administrator had done several more edits on top of it. Refusing here
            names the choice they actually have.

            REMOVING A RULE CHANGES WHAT THE RULES BELOW IT DO. A set: value only
            takes effect if the variable is not already resolved, so a variable
            the removed rule was winning now falls through to whichever rule
            below sets it next. That is the point of the removal, and it is worth
            knowing before it happens.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTRuleDocument is what
            touches the share.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The rule to remove.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the rule removed.

        .EXAMPLE
            Remove-HDTRule -Line $line -Name 'Lab subnet'
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
        [string] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $all = @(Get-HDTRuleBlock -Line $Line)
    $block = Resolve-HDTRuleBlock -Line $Line -Name $Name

    if (@($all).Count -le 1) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Name -Category InvalidOperation `
                    -Message ("'{0}' is the only rule in this document, and a rules document with no rules is not one the engine will load. Add the rule that replaces it first, or delete the file with the workspace." -f $Name)))
    }

    if (-not $PSCmdlet.ShouldProcess($Name, 'Remove from the rules')) {
        return [string[]] @($Line)
    }

    $keep = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($i -ge [int] $block.Start -and $i -le [int] $block.End) { continue }

        [void] $keep.Add($Line[$i])
    }

    # A removal leaves the blank line that separated the rule from the next one
    # sitting directly beneath the blank that separated it from the previous.
    # Collapsing that pair keeps the file's spacing where it was rather than
    # letting it grow a gap with every edit.
    $result = [string[]] @(Remove-HDTBlankRun -Line ([string[]] @($keep)) -At ([int] $block.Start))

    try {
        Assert-HDTRuleLine -Line $result
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $result
}
