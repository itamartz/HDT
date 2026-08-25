function Get-HDTConsoleImageWrite {
    <#
        .SYNOPSIS
            What the Apply OS pane writes when a box on it is left: the four step
            properties, the variable write when there is one, and the command to
            echo.

        .DESCRIPTION
            UNCHANGED MEANS UNCHANGED, and that is the trap this exists around.
            The image box shows what the step RESOLVES TO, not what the step
            says. A step naming its image through '%HDTOSImage%' shows today's
            answer in the box, so writing back whatever the box holds would
            replace the variable with a literal - silently, on a press meant for
            the time limit. The box is compared against what it was FILLED with,
            and when they match the file keeps what it had.

            THE VARIABLE, NOT THE TOKEN. When the image really was changed and
            the step names it through a variable this sequence sets, the new
            choice belongs in the variables block and the step keeps saying
            '%HDTOSImage%'. Writing the literal into the step would delete the
            indirection the sequence was built on, and leave the Variables tab
            showing an image the step no longer uses.

            THE INDEX IS THE NUMBER, NEVER THE LABEL. A selected editable
            ComboBox reports its display text - '1  -  Windows 11 Enterprise
            LTSC' - and that is not an index. The selected row's number wins over
            the typed text whenever there is a selection, and the same
            unchanged-means-unchanged rule applies: an index that still reads
            what the box was filled with writes back what the FILE had, which may
            be a variable of its own.

            THE ECHO IS THE COMMAND THAT RAN, not the one that usually runs. A
            press that moved the variable echoes Set-HDTSequenceVariable; a press
            that wrote the step echoes Set-HDTStepProperty. Showing the wrong one
            teaches a command that would undo the indirection if it were typed.

            IT WRITES NOTHING. This is the decision; the caller runs it inside
            the pane's own attempt-and-rollback wrapper.

        .PARAMETER Step
            The selected step's name.

        .PARAMETER Image
            What the step's os property says now - a name or a '%Var%' token.

        .PARAMETER ImageShown
            What the image box was FILLED with. The comparison against Chosen is
            what makes an untouched box a no-op.

        .PARAMETER ImageVariable
            The variable the step names its image through, or '' when it names
            the image directly.

        .PARAMETER Chosen
            What the image box holds now.

        .PARAMETER IndexTyped
            The index box's text.

        .PARAMETER IndexSelected
            The number off the selected row, or '' when nothing is selected. Wins
            over IndexTyped, because the text is a label.

        .PARAMETER IndexShown
            What the index box was filled with.

        .PARAMETER IndexWritten
            What the file says the index is, used when the box is untouched.

        .PARAMETER Target
            The target box.

        .PARAMETER TimeoutMinutes
            The time limit box.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              ImageChanged   whether the image box was actually changed
              VariableName   the variable to set, '' when there is none
              VariableValue  what to set it to
              Property       four rows of Key and Value, in pane order
              Command        the invocation to echo

        .EXAMPLE
            Get-HDTConsoleImageWrite -Step 'Apply OS' -Image '%HDTOSImage%' -ImageShown 'Win11' -ImageVariable 'HDTOSImage' -Chosen 'Win11' -IndexTyped '1' -IndexShown '1' -IndexWritten '1' -Target 'C:' -TimeoutMinutes '90'

        .EXAMPLE
            $write = Get-HDTConsoleImageWrite -Step $book.Selected -Image $book.Image -Chosen $imageBox.SelectedValue @rest
            foreach ($one in $write.Property) { $line = @(Set-HDTStepProperty -Line $line -Property $one.Key -Value $one.Value) }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Step,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Image,
        [Parameter()] [AllowEmptyString()] [string] $ImageShown = '',
        [Parameter()] [AllowEmptyString()] [string] $ImageVariable = '',
        [Parameter()] [AllowEmptyString()] [string] $Chosen = '',
        [Parameter()] [AllowEmptyString()] [string] $IndexTyped = '',
        [Parameter()] [AllowEmptyString()] [string] $IndexSelected = '',
        [Parameter()] [AllowEmptyString()] [string] $IndexShown = '',
        [Parameter()] [AllowEmptyString()] [string] $IndexWritten = '',
        [Parameter()] [AllowEmptyString()] [string] $Target = '',
        [Parameter()] [AllowEmptyString()] [string] $TimeoutMinutes = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $imageChanged = ($Chosen -ne $ImageShown)

    # UNCHANGED MEANS UNCHANGED: the file keeps its token.
    $osValue = $Image
    if ($imageChanged) { $osValue = $Chosen }

    $variableName = ''
    $variableValue = ''

    # THE VARIABLE, NOT THE TOKEN.
    if ($imageChanged -and -not [string]::IsNullOrWhiteSpace($ImageVariable)) {
        $variableName = $ImageVariable
        $variableValue = $Chosen

        # And the step keeps saying %HDTOSImage%.
        $osValue = $Image
    }

    # THE NUMBER, NEVER THE LABEL.
    $index = $IndexTyped
    if (-not [string]::IsNullOrWhiteSpace($IndexSelected)) { $index = $IndexSelected }

    if ($index -eq $IndexShown) { $index = $IndexWritten }

    if ($variableName -ne '') {
        $command = "Set-HDTSequenceVariable -Line `$line -Name '{0}' -Value '{1}'" -f $variableName, $variableValue
    } else {
        $command = "Set-HDTStepProperty -Line `$line -Name '{0}' -Property 'os' -Value '{1}'" -f $Step, $Chosen
    }

    return [pscustomobject] @{
        ImageChanged  = $imageChanged
        VariableName  = $variableName
        VariableValue = $variableValue
        Property      = [pscustomobject[]] @(
            [pscustomobject] @{ Key = 'os'; Value = [string] $osValue }
            [pscustomobject] @{ Key = 'index'; Value = [string] $index }
            [pscustomobject] @{ Key = 'target'; Value = [string] $Target }
            [pscustomobject] @{ Key = 'timeoutMinutes'; Value = [string] $TimeoutMinutes }
        )
        Command       = $command
    }
}
