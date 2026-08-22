function Get-HDTConsoleStepChange {
    <#
        .SYNOPSIS
            Which rows of the Properties tab were typed into, and the cmdlet
            each one would run.

        .DESCRIPTION
            APPLY IS ONE PRESS OVER SEVERAL BOXES, and working out which of them
            changed is a decision - so it is made here rather than in a loop
            inside the window. The handler behind the button
            walks what this returns and calls Set-HDTStepProperty once
            per entry, with nothing left to work out.

            A ROW IS CHANGED WHEN ITS Value NO LONGER MATCHES ITS Original.
            Value is bound two-way to the box, so it holds what the
            administrator typed; Original is what the row said when
            Get-HDTConsoleStepNode built it. Nothing else is consulted - in
            particular the FILE is not re-read, because the file is not what the
            administrator has been looking at.

            A READ-ONLY ROW IS IGNORED EVEN IF ITS VALUE CHANGED. 'Type' and
            'Runs' are reports; a binding, a template or a future edit could
            still write to them, and a change that silently spliced a report
            into the document would be very hard to explain afterwards. The row
            says whether it writes, and only rows that say so are collected.

            A RENAME GOES LAST, AND THAT IS THE WHOLE REASON THIS RETURNS AN
            ORDERED LIST RATHER THAN A SET. Every editing cmdlet resolves its
            target by name; renaming first would leave the remaining changes
            looking for a step that no longer answers to it, and they would fail
            one by one having already half-applied the edit.

        .PARAMETER Field
            The rows from the selected node, as the window has them - Value
            carrying whatever was typed.

        .PARAMETER Name
            The step or group they belong to.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per change, with
            Property, Value and the Set-HDTStepProperty call that would
            make it. Nothing at all when nothing was typed.

        .EXAMPLE
            $change = Get-HDTConsoleStepChange -Field $state.Selected.Field -Name 'Apply OS'
            foreach ($one in $change) {
                $line = Set-HDTStepProperty -Line $line -Name 'Apply OS' -Property $one.Property -Value $one.Value
            }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $Field,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $naming = @('name', 'group')

    $change = New-Object -TypeName System.Collections.ArrayList
    $rename = New-Object -TypeName System.Collections.ArrayList

    foreach ($row in @($Field)) {
        if ($null -eq $row) { continue }
        if (-not $row.Editable) { continue }

        $value = [string] $row.Value

        # A TICK BOX WRITES 'true', NOT 'True'. WPF converts the box's bool back
        # through the default string converter, which capitalises - and the
        # document, every Get-HDT*StepTemplate and DEMO-M4 all spell it lower.
        # A commit that turned 'wipe: true' into 'wipe: True' would be a diff
        # with a reformat in it and no edit (DESIGN 12), and the reviewer would
        # have to work out which it was.
        #
        # HERE RATHER THAN IN THE ROW, because the row is the edit buffer: it
        # holds whatever the control last wrote into it, and this is the moment
        # that becomes a line in a file.
        $kind = ''
        if ($null -ne $row.PSObject.Properties['Kind']) { $kind = [string] $row.Kind }
        if ($kind -eq 'Check') { $value = $value.ToLowerInvariant() }

        if ($value -eq [string] $row.Original) { continue }

        $renames = ($naming -contains [string] $row.Property)

        # WHAT THE STEP ANSWERS TO ONCE THIS CHANGE IS APPLIED. Only a rename
        # moves it, and the caller applying these in order needs to know when -
        # so it is stated here rather than left to a test in the window about
        # which properties are names.
        $after = $Name
        if ($renames) { $after = $value }

        $entry = [pscustomobject] @{
            Property  = [string] $row.Property
            Value     = $value
            Original  = [string] $row.Original
            Renames   = $renames
            NameAfter = $after
            Command   = ("Set-HDTStepProperty -Line `$line -Name '{0}' -Property {1} -Value '{2}'" -f $Name, $row.Property, $value)
        }

        if ($renames) {
            [void] $rename.Add($entry)
        } else {
            [void] $change.Add($entry)
        }
    }

    # The rename last, so everything before it still finds the step.
    foreach ($entry in $rename) { [void] $change.Add($entry) }

    return [pscustomobject[]] @($change)
}
