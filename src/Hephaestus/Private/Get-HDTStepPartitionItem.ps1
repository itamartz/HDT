function Get-HDTStepPartitionItem {
    <#
        .SYNOPSIS
            Where each row of a step's partition table starts and ends.

        .DESCRIPTION
            THE LOCATOR THE THREE EDITING COMMANDS SHARE. Add, Remove and Move
            all have to answer the same question first - which lines does the
            partition called 'Windows' own - and answering it three times is
            answering it differently twice.

            AN ITEM OWNS EVERY LINE UNTIL THE NEXT DASH AT ITS OWN COLUMN, which
            is what makes a multi-line row work:

                partition:
                  - name: Windows      <- Index
                    type: Primary
                    size: 60%          <- End

            COMMENTS ABOVE A ROW BELONG TO IT. An administrator writing "# the
            volume the OS lands on" above a partition means it about that
            partition, and a move that left the comment behind would attach it
            to whatever slid into its place.

            IT FINDS NOTHING WHEN THE STEP NAMES A LAYOUT INSTEAD, and that is
            an ordinary answer rather than an error - the caller says what to do
            about it, because Add and Remove have different things to say.

        .PARAMETER Line
            The sequence document's lines.

        .PARAMETER Block
            The step, from Resolve-HDTStepBlock.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] in document order:

              Name    the partition's name
              Index   the line its dash sits on
              Start   Index, or the first comment line above it
              End     the last line it owns
              Indent  the column the dash sits at, which an insert must match

        .EXAMPLE
            Get-HDTStepPartitionItem -Line $line -Block (Resolve-HDTStepBlock -Line $line -Name 'Format and Partition')
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Block
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $key = Get-HDTStepKey -Line $Line -Block $Block -Key 'partition'

    if ([int] $key.Index -lt 0) { return [pscustomobject[]] @() }

    $item = New-Object -TypeName System.Collections.ArrayList
    $current = $null
    $itemIndent = -1

    for ($index = [int] $key.Index + 1; $index -le [int] $Block.End; $index++) {
        $text = [string] $Line[$index]

        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $indent = $text.Length - $text.TrimStart(' ').Length
        $trimmed = $text.TrimStart(' ')

        # BACK OUT TO THE KEY'S OWN COLUMN AND THE LIST IS OVER - the next key
        # of the step has started.
        if ($indent -le [int] $key.Indent -and -not $trimmed.StartsWith('- ')) { break }

        if ($trimmed.StartsWith('- ')) {
            if ($itemIndent -lt 0) { $itemIndent = $indent }
            if ($indent -ne $itemIndent) { continue }

            $name = ''
            if ($trimmed -match '^-\s+name:\s*(.+?)\s*$') { $name = [string] $Matches[1].Trim('"', "'") }

            $current = [pscustomobject] @{
                Name   = $name
                Index  = $index
                Start  = $index
                End    = $index
                Indent = $indent
            }

            # THE COMMENTS ABOVE IT ARE PART OF IT. Walk back over any comment
            # lines written at the item's own column or deeper.
            $above = $index - 1
            while ($above -gt [int] $key.Index) {
                $previous = [string] $Line[$above]
                if (-not $previous.TrimStart(' ').StartsWith('#')) { break }

                $current.Start = $above
                $above--
            }

            [void] $item.Add($current)
            continue
        }

        if ($null -ne $current) { $current.End = $index }
    }

    return [pscustomobject[]] @($item)
}
