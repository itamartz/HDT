function New-HDTConsoleField {
    <#
        .SYNOPSIS
            Builds one labelled field for the console's detail pane.

        .DESCRIPTION
            THE DETAIL PANE IS A PROPERTIES SHEET, NOT A PARAGRAPH. Deployment
            Workbench shows a selected item as labelled fields, and so does this:
            a caption on the left and the value in a box on the right, one row
            per fact. A single block of pre-formatted text reads as a log entry,
            cannot be copied a field at a time, and gives nothing for an editor
            to attach to later.

            THE VALUE BOX IS READ-ONLY IN C1, AND THAT IS DELIBERATE RATHER THAN
            UNFINISHED. C1 opens a live deployment share and writes nothing to
            it. Writing needs the comment-preserving YAML round-trip the design
            requires - "a UI that reformats the file breaks git review" - and
            that does not exist yet. A box that accepts typing and silently
            discards it would be worse than one that plainly does not.

        .PARAMETER Label
            The caption. Empty for a note that stands on its own.

        .PARAMETER Value
            The text, which may span lines.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Label and Value.

        .EXAMPLE
            New-HDTConsoleField -Label 'Steps' -Value $sequence.StepCount
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a display row object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Label,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Value,

        # THE YAML KEY THIS ROW WRITES, for the rows that write one. Most do
        # not: the browser's rows are a report, and even in the editor 'Runs' is
        # 'step 3 of 5', which is a position rather than anything in the file.
        # A row with no Property is read-only, and the window reads that off the
        # row rather than keeping its own list of which labels are typeable.
        [Parameter()]
        [AllowEmptyString()]
        [string] $Property = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [pscustomobject] @{
        Label    = $Label
        Value    = $Value
        Property = $Property
        Editable = (-not [string]::IsNullOrEmpty($Property))

        # THE SAME FACT THE OTHER WAY UP, because the control that needs it is
        # a TextBox and the property it exposes is IsReadOnly. XamlReader parses
        # markup and nothing else - there is no code-behind to host a value
        # converter and no assembly to point an xmlns at - so the inversion is
        # done here, where it is one expression and a test can read it, rather
        # than in a converter the window cannot load.
        ReadOnly = [string]::IsNullOrEmpty($Property)

        # WHAT IT SAID WHEN IT WAS BUILT. Value is bound two-way to a box an
        # administrator types into, so it is the only copy of what they typed -
        # and Original is what the diff is taken against when Apply is pressed.
        # A row compared against itself would never look changed.
        Original = $Value
    }
}
