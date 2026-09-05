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
            it. Writing needs the comment-preserving YAML round-trip the editor
            requires - "a UI that reformats the file breaks git review" - and
            that does not exist yet. A box that accepts typing and silently
            discards it would be worse than one that plainly does not.

        .PARAMETER Label
            The caption. Empty for a note that stands on its own.

        .PARAMETER Value
            The text, which may span lines.

        .PARAMETER Hint
            One sentence behind a ? beside the box, for a row whose value has a
            rule nobody can see by looking at it. Most rows have none, and that
            is what makes the dot worth reading where it appears.

        .PARAMETER Choice
            The values this row may take, shown as a list instead of a box. For
            a row the document constrains to a closed set - a log level, not a
            path.

        .PARAMETER Check
            The value is yes-or-no, so the row is a tick box. For a key the
            document writes as a YAML boolean - wipe, expand, recoveryPassword -
            where a text box asks an administrator to type the word True.

        .PARAMETER Browse
            The row's value is picked off the disk rather than typed, and this
            says WHAT is picked. A path is a thing to point at, not a thing to
            remember.

            A KIND AND NOT A SWITCH. A bare switch would force the window's
            click handler to know that "a browse here means a save dialog
            filtered to .iso" - a decision, inside an adapter, where nothing can
            test it. Get-HDTConsoleFieldBrowse decides it instead, and a CLOSED
            SET is a thing a contract can walk: the contract reads this
            ValidateSet and asserts the mapper answers every member of it, so
            the day somebody adds a kind the mapper does not know, the sweep
            fails rather than the button doing nothing.

            AN ADJUNCT, NOT A FOURTH Kind. The box is still the control; the
            button sits beside it in the third column, the way the help dot
            does.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Label, Value,
            Property, Editable, ReadOnly, Original, Hint, HasHint, Choice,
            HasChoice, Browse, HasBrowse and Kind.

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
        [string] $Property = '',

        # WHAT THE BOX CANNOT SAY BY ITSELF. An install command line is handed
        # to cmd.exe with the application's own folder as the working directory
        # - a fact with real consequences for what an administrator types, and
        # nothing on the row shows it. A hint here rather than a paragraph under
        # the box: three of those turn a properties sheet into a manual, and MDT
        # admins are not reading the manual on the deployment screen.
        [Parameter()]
        [AllowEmptyString()]
        [string] $Hint = '',

        # THE VALUES THIS ROW MAY TAKE, for a row where the document allows a
        # closed set and a box named none of them. Log level was the case that
        # forced it: four levels are legal, and the only way to discover them
        # from the pane was to type something, save, and read the refusal.
        #
        # A LIST IS NOT A SECOND KIND OF ROW. It writes the same key, diffs
        # against the same Original and lights the same Apply - only the control
        # that produces the string is different.
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $Choice = @(),

        # YES-OR-NO, WHICH IS A TICK BOX EVERYWHERE ELSE IN THIS WINDOW. The
        # Options tab draws Disabled and Continue on error as boxes; a step's
        # own booleans - wipe, expand, recoveryPassword, wait - were drawn as
        # text and asked for the word True, which is both more typing and one
        # more thing to spell wrong.
        #
        # IT IS A SWITCH RATHER THAN INFERENCE FROM Value. 'true' is a legal
        # string for a key that is not a boolean at all, and a row that guessed
        # would turn one into a tick box the document never asked for.
        [Parameter()]
        [switch] $Check,

        # THE VALUE IS A FLAT LIST SHOWN AS A COMMA LINE. It draws as an ordinary
        # text box - there is nothing for a control to do differently - but the
        # SPLICE is not ordinary: Set-HDTStepProperty would quote it, and
        # 'features: ''Web-Server, DNS''' is one feature with a comma in its
        # name. Get-HDTConsoleStepChange reads this and routes to
        # Set-HDTStepPropertyList instead.
        [Parameter()]
        [switch] $List,

        # WHAT THIS ROW PICKS OFF THE DISK, for the row whose value is a path.
        # See the help above for why it is a kind rather than a switch.
        #
        # NO [AllowEmptyString()], DELIBERATELY, AND THIS IS NOT THE SHAPE THE
        # REST OF THIS FUNCTION USES. Every other optional string here carries
        # one; this one must not. AllowEmptyString exempts a value from the
        # null/empty check and NOT from ValidateSet, so the pair would accept
        # -Browse unbound - a default is never validated - and then refuse
        # -Browse '' with a set error naming IsoFile: two spellings of "no
        # browse", one of which throws. Leaving it off makes this ValidateSet
        # EXACTLY the set of browse kinds, which is what the contract sweep
        # reads off this parameter and walks.
        [Parameter()]
        [ValidateSet('IsoFile')]
        [string] $Browse = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not [string]::IsNullOrEmpty($Browse)) {

        # A PICKER WITH NOWHERE TO PUT THE ANSWER is a defect that looks, from
        # the outside, like a UI that does nothing: the dialog opens, a file is
        # chosen, and the value is dropped. Refused here, the failure names the
        # line that declared the row.
        if ([string]::IsNullOrEmpty($Property)) {
            throw (New-Object System.ArgumentException (
                    "the '{0}' row asks for a Browse button but names no document key, so there is nowhere to put what it picks." -f $Label))
        }

        if ($Choice.Count -gt 0 -or $Check) {
            throw (New-Object System.ArgumentException (
                    "the '{0}' row asks for a Browse button and a closed set at the same time. A path picked off the disk is not one of a list." -f $Label))
        }
    }

    return [pscustomobject] @{
        Label    = $Label
        Value    = $Value
        Property = $Property
        Hint     = $Hint

        # THE SAME FACT AS A BOOLEAN, for the same reason ReadOnly exists below:
        # XamlReader parses markup and nothing else, so a template that had to
        # ask "is this string empty" would need a converter the window cannot
        # load. The dot binds its visibility to this.
        HasHint  = (-not [string]::IsNullOrEmpty($Hint))
        Editable = (-not [string]::IsNullOrEmpty($Property))

        # WHAT THE LIST HOLDS, AND WHETHER THERE IS ONE. Two properties for one
        # fact, for the reason ReadOnly exists below: the template swaps a
        # ComboBox in for the TextBox on a DataTrigger, and a trigger compares a
        # value - it cannot ask whether a collection is empty without a
        # converter this markup has nowhere to load from.
        Choice   = [string[]] $Choice
        HasChoice = ($Choice.Count -gt 0)

        # WHAT THIS ROW PICKS, AND WHETHER IT PICKS AT ALL. Two properties for
        # one fact, for the same reason HasHint exists above: the template shows
        # the browse button on a DataTrigger, and a trigger compares a value -
        # it cannot ask whether a string is empty without a converter this
        # markup has nowhere to load from.
        Browse    = $Browse
        HasBrowse = (-not [string]::IsNullOrEmpty($Browse))

        # WHICH CONTROL DRAWS THIS ROW, AS ONE STRING. A DataTrigger compares a
        # value, so three booleans would need three triggers that can all fire
        # at once and leave two controls stacked in the same column. One string
        # cannot contradict itself.
        #
        # A LIST WINS OVER A TICK BOX if a row somehow asked for both: a closed
        # set of two is still a set, and showing it loses nothing.
        Kind     = $(
            if ($Choice.Count -gt 0) { 'Choice' }
            elseif ($Check) { 'Check' }
            elseif ($List) { 'List' }
            else { 'Text' }
        )

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
