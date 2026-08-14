function Remove-HDTConsoleStep {
    <#
        .SYNOPSIS
            Removes one step or group from a task sequence document, leaving
            every other line byte-identical.

        .DESCRIPTION
            The Remove button, and the cmdlet an administrator can type instead
            (DESIGN 12: "the console may not do anything the cmdlets can't").

            IT SPLICES LINES AND NEVER PARSES YAML. ConvertFrom-HDTYaml yields a
            dictionary and a dictionary has no comments in it; the lab's DEMO-M4
            is 107 lines of which 51 are a header recording SPIKES findings. An
            edit that round-tripped through the parser would hand back a file
            with every comment gone and every key reordered - the thing DESIGN
            12 forbids, because "a UI that reformats the file breaks git review".

            THE COMMENT ABOVE A STEP GOES WITH IT. A comment left behind
            attaches itself to whatever now sits beneath it, so the file ends up
            stating something untrue - worse than losing the comment.

            REMOVING A GROUP REMOVES ITS STEPS. That is what the group is: the
            block spans its children, so the splice takes them.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTConsoleSequence is what
            touches the share, so an edit can be composed, reviewed and
            abandoned without a file ever changing.

        .PARAMETER Line
            The document, already split into lines.

        .PARAMETER Name
            The step or group to remove.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document with the block removed.

        .EXAMPLE
            $line = [System.IO.File]::ReadAllText($path) -split "`r?`n"
            Remove-HDTConsoleStep -Line $line -Name 'Apply OS'

        .EXAMPLE
            Remove-HDTConsoleStep -Line $line -Name 'Preinstall'

            The group and every step in it.
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

    $all = @(Get-HDTConsoleStepBlock -Line $Line)
    $found = Resolve-HDTConsoleStepBlock -Line $Line -Name $Name
    $block = @($all | Where-Object { $_.Entry -eq $found.Entry })[0]

    # A GROUP WITH NO STEPS IS NOT A DOCUMENT THE ENGINE ACCEPTS. The schema
    # says a group's steps must be a list of steps and groups, so taking the
    # last one out produces a file that fails to load - and it would fail at
    # Save, after the administrator had done several more edits on top of it.
    # Refusing here names the choice they actually have.
    $parent = @(Get-HDTConsoleStepParent -Block $all)
    $at = [array]::IndexOf($all, $block)

    if ($block.Kind -eq 'Step' -and $parent[$at] -ge 0) {
        $sibling = @($all | Where-Object { $parent[[array]::IndexOf($all, $_)] -eq $parent[$at] })

        if (@($sibling).Count -le 1) {
            throw (New-HDTConsoleErrorRecord -Path $Name -Category InvalidOperation `
                    -Message ("'{0}' is the only step in the '{1}' group, and a group with no steps is not a document the engine will load. Remove the group instead." -f $Name, $all[$parent[$at]].Name))
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Name, 'Remove from the task sequence')) {
        return [string[]] @($Line)
    }

    $keep = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($i -ge $block.Start -and $i -le $block.End) { continue }

        [void] $keep.Add($Line[$i])
    }

    # A removal leaves the blank line that separated it from the next block, and
    # the one before it, side by side. Collapsing a run of blanks INSIDE the
    # steps region keeps the file's spacing where it was rather than letting it
    # grow a gap with every edit.
    return [string[]] @(Remove-HDTConsoleBlankRun -Line $keep -At $block.Start)
}
