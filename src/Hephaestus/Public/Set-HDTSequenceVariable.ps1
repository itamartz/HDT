function Set-HDTSequenceVariable {
    <#
        .SYNOPSIS
            Sets or removes one variable in a task sequence's variables block,
            leaving every other line byte-identical.

        .DESCRIPTION
            THE BLOCK THE NEW SEQUENCE WINDOW FILLS AND NOTHING COULD CHANGE.
            New-HDTTaskSequence asks for the administrator password, the OS image
            and the organisation, writes them into variables:, and until this
            command existed that was the end of it - the editor edits steps, the
            detail pane edits name and description, and an administrator who
            mistyped the password re-created the sequence.

            The template's own comment above that block says "WHAT AN AUTHOR IS
            EXPECTED TO CHANGE", and it was the one part of a sequence a window
            could not touch.

            IT SPLICES ONE LINE. The comments inside the block, the order of the
            variables already there and the spacing around them all come back
            exactly as they went in - sequence.yaml is read in review, and an
            editor that reformats it makes every change unreadable.

            IT BUILDS THE BLOCK WHEN THERE IS NONE, before steps:. A variables:
            written after the steps belongs to the last step, or to nothing.

            THE NAME IS HELD TO THE SAME RULE AS rules.yaml. Every deployment
            variable is prefixed HDT and no _HDT* name may be assigned - a
            sequence that set 'ComputerName' would set something nothing reads,
            and the failure would be a machine with the wrong name rather than
            an error anybody saw.

            IT RETURNS LINES AND WRITES NOTHING. Save-HDTSequenceDocument is what
            touches the share, so an edit can be composed, reviewed and abandoned
            without a file ever changing.

        .PARAMETER Line
            The sequence document, as lines.

        .PARAMETER Name
            The variable. HDTSomething, and not _HDTSomething.

        .PARAMETER Value
            What to set it to. Ignored with -Remove.

        .PARAMETER Remove
            Take the variable out of the block instead of setting it. A variable
            set by mistake has to be removable, and removing one that is not
            there is refused rather than silently doing nothing.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the document, spliced.

        .EXAMPLE
            $line = Get-Content -LiteralPath 'C:\HDTLab\Share\TaskSequences\DEMO\sequence.yaml'
            $line = Set-HDTSequenceVariable -Line $line -Name 'HDTAdminPassword' -Value 'P@ssw0rd!'
            Save-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO\sequence.yaml' -Line $line

        .EXAMPLE
            Set-HDTSequenceVariable -Line $line -Name 'HDTOSImageIndex' -Remove

        .LINK
            Save-HDTSequenceDocument

        .LINK
            Set-HDTTaskSequenceProperty
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low', DefaultParameterSetName = 'Set')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory = $true, Position = 2, ParameterSetName = 'Set')]
        [AllowEmptyString()]
        [string] $Value,

        [Parameter(Mandatory = $true, ParameterSetName = 'Remove')]
        [switch] $Remove
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # -- what is being asked for ---------------------------------------------

    if ($Name.StartsWith('_')) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name -Category InvalidArgument `
                    -Message ("'{0}' is engine-owned and cannot be assigned. A variable named _HDT* is set by the engine while the sequence runs and is read-only to a document." -f $Name)))
    }

    if ($Name -notmatch '^HDT[A-Za-z0-9_]*$') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name -Category InvalidArgument `
                    -Message ("'{0}' is not an HDT variable name. Every deployment variable is prefixed HDT; run Get-HDTVariableMap for the MDT translation." -f $Name)))
    }

    # The document has to be readable before it is worth editing.
    $document = ConvertFrom-HDTSequenceLine -Line $Line

    $declared = ($null -ne $document.Variable) -and $document.Variable.Contains($Name)

    if ($Remove -and -not $declared) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Name -Category ObjectNotFound `
                    -Message ("'{0}' is not declared by this sequence, so there is nothing to remove. The variables it does declare are: {1}." -f
                        $Name, ((@($document.Variable.Keys) -join ', '), '(none)')[(@($document.Variable.Keys).Count -eq 0)])))
    }

    if ($Remove) {
        $action = "Remove the variable '$Name'"
    } else {
        $action = "Set the variable '$Name'"
    }

    if (-not $PSCmdlet.ShouldProcess('sequence.yaml', $action)) {
        return [string[]] @($Line)
    }

    # -- the splice ----------------------------------------------------------
    #
    # THE BLOCK IS FOUND BY ITS OWN LINE, not by parsing: a rewrite from the
    # parsed document would return a tidy file with none of the author's
    # comments in it.

    $result = New-Object -TypeName System.Collections.ArrayList
    foreach ($current in @($Line)) { [void] $result.Add([string] $current) }

    $blockIndex = -1
    $stepsIndex = -1

    for ($index = 0; $index -lt $result.Count; $index++) {
        $text = [string] $result[$index]

        if ($blockIndex -lt 0 -and $text -match '^variables\s*:\s*$') { $blockIndex = $index }
        if ($stepsIndex -lt 0 -and $text -match '^steps\s*:\s*$') { $stepsIndex = $index }
    }

    # WHERE THE BLOCK ENDS: the first line at column zero after it, or the end
    # of the document. Everything between belongs to variables:, comments and
    # blank lines included.
    $blockEnd = $result.Count
    if ($blockIndex -ge 0) {
        for ($index = $blockIndex + 1; $index -lt $result.Count; $index++) {
            $text = [string] $result[$index]
            if ($text -match '^\S') { $blockEnd = $index; break }
        }
    }

    $written = '  {0}: {1}' -f $Name, (ConvertTo-HDTRuleScalarText -Value $Value)

    if ($blockIndex -ge 0) {
        $existing = -1

        for ($index = $blockIndex + 1; $index -lt $blockEnd; $index++) {
            if (([string] $result[$index]) -match ('^\s+{0}\s*:' -f [regex]::Escape($Name))) {
                $existing = $index
                break
            }
        }

        if ($existing -ge 0 -and $Remove) {
            $result.RemoveAt($existing)
        } elseif ($existing -ge 0) {
            $result[$existing] = $written
        } else {
            # AFTER THE LAST VARIABLE, not at the top of the block: the comment
            # the template writes sits at the top, and a value inserted above it
            # reads as if the comment describes something else.
            $insertAt = $blockEnd
            while ($insertAt -gt $blockIndex + 1 -and [string]::IsNullOrWhiteSpace([string] $result[$insertAt - 1])) {
                $insertAt--
            }

            $result.Insert($insertAt, $written)
        }
    } else {
        # NO BLOCK YET. It goes before steps:, or at the end of a document that
        # has none, with a blank line after it so the steps still read as their
        # own section.
        $at = $stepsIndex
        if ($at -lt 0) { $at = $result.Count }

        $result.Insert($at, '')
        $result.Insert($at + 1, 'variables:')
        $result.Insert($at + 2, $written)
    }

    $spliced = [string[]] @($result)

    try {
        [void] (ConvertFrom-HDTSequenceLine -Line $spliced)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    return [string[]] $spliced
}
