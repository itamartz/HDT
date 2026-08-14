function Get-HDTConsoleStepParent {
    <#
        .SYNOPSIS
            Works out which group each block sits inside.

        .DESCRIPTION
            WHAT MAKES TWO STEPS NEIGHBOURS. Every step in a sequence document
            sits at the same indentation whichever group it belongs to, so
            "same column" is not the same question as "same group". Matching on
            indentation alone would make the LAST step of one group the
            neighbour of the FIRST step of the next, and Down would then move a
            step quietly across a group boundary - the one thing
            Move-HDTConsoleStep refuses to do, because a step that changes group
            changes the phase and the condition it runs under.

            A BLOCK'S PARENT IS THE NEAREST BLOCK ABOVE IT THAT IS LESS
            INDENTED. That is the whole rule, and it works for any nesting depth
            because the locator already records the indentation of each block.

            The answer is returned as a parallel array rather than added to the
            blocks, so Get-HDTConsoleStepBlock stays a description of the
            document's text and nothing else.

        .PARAMETER Block
            The blocks from Get-HDTConsoleStepBlock, in document order.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Int32[] - for each block, the index of its parent block, or
            -1 for a block at the top level of the steps region.

        .EXAMPLE
            $parent = Get-HDTConsoleStepParent -Block $block
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [object[]] $Block
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $result = New-Object -TypeName System.Collections.ArrayList

    for ($i = 0; $i -lt $Block.Count; $i++) {
        $parent = -1

        for ($j = $i - 1; $j -ge 0; $j--) {
            if ($Block[$j].Indent -lt $Block[$i].Indent) {
                $parent = $j
                break
            }
        }

        [void] $result.Add($parent)
    }

    return [int[]] @($result)
}
