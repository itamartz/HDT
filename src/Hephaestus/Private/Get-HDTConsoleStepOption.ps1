function Get-HDTConsoleStepOption {
    <#
        .SYNOPSIS
            Builds the editor's Options tab for one step or group: the two
            checkboxes, and the filter that decides whether it runs.

        .DESCRIPTION
            WORKBENCH'S SECOND TAB. MDT splits a step's dialog into Properties -
            what it does - and Options - whether it does it: "Disable this
            step", "Continue on error", and the conditions beneath them. The
            split is worth copying because the two halves are read at different
            times: Properties when building a sequence, Options when working out
            why a deployment did something surprising.

            EVERY ROW IS DECIDED HERE, which is the same rule
            Get-HDTConsoleStepNode follows and for the same reason: the window
            binds to these objects and formats nothing, so the checkbox states
            and the cmdlet each one shows can be asserted without a screen.

            A CHECKBOX CARRIES THE COMMAND FOR THE PRESS, NOT FOR ITS STATE. The
            Value in each row's command is the OPPOSITE of what the step
            currently says, because that is what pressing the box would do -
            which means the string the console displays is the string an
            administrator can paste into a shell and get the same result from.
            A command that merely restated the current value would be true and
            useless.

            A GROUP HAS NO continueOnError TO OFFER. Import-HDTSequenceDocument
            gives a group Path, Condition, RunIn and Disabled and nothing else,
            so the tab shows one box rather than two greyed ones - an offer the
            file cannot hold is worse than no offer.

            THE PHASE IS ON THIS TAB TOO, because it filters. Running in the
            wrong one is the commonest reason a step is silently skipped, and an
            administrator looking at Options is asking exactly that question.

        .PARAMETER Step
            One step or group from Import-HDTSequenceDocument. A group is
            recognised by having no Type.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Name, Kind        what this tab is about
              Flag              one row per checkbox, with Label, Property,
                                Checked and the cmdlet the press would run
              Condition         the expression as written, or empty
              ConditionText     the same, or a sentence saying there is none
              HasCondition      whether there is one
              ConditionCommand  the cmdlet that would set it
              RunIn, RunInText  the phase it is restricted to

        .EXAMPLE
            $document = Import-HDTSequenceDocument -Path $path -FileSystem (New-HDTFileSystem)
            Get-HDTConsoleStepOption -Step $document.Step[0] | Select-Object -ExpandProperty Flag
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Step
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # A group is the row that has no type. Nothing here is keyed on which
    # collection it came out of, so the caller may hand over either.
    $property = @($Step.PSObject.Properties.Name)

    $kind = 'Group'
    if ($property -contains 'Type') { $kind = 'Step' }

    $name = ''

    if ($kind -eq 'Step') {
        $name = [string] $Step.Name
    } else {
        $path = @($Step.Path)
        if ($path.Count -gt 0) { $name = [string] $path[-1] }
    }

    $disabled = [bool] $Step.Disabled

    # -- the checkboxes ----------------------------------------------------

    $flag = New-Object -TypeName System.Collections.ArrayList

    $disableLabel = 'Disable this step'
    if ($kind -eq 'Group') { $disableLabel = 'Disable this group' }

    [void] $flag.Add((New-HDTConsoleOptionFlag -Label $disableLabel -Property 'Disabled' `
                -Checked $disabled -Name $name))

    if ($kind -eq 'Step') {
        [void] $flag.Add((New-HDTConsoleOptionFlag -Label 'Continue on error' -Property 'ContinueOnError' `
                    -Checked ([bool] $Step.ContinueOnError) -Name $name))
    }

    # -- the filter --------------------------------------------------------

    $condition = ''
    if ($null -ne $Step.Condition) { $condition = [string] $Step.Condition }

    $hasCondition = -not [string]::IsNullOrWhiteSpace($condition)

    $conditionText = $condition
    if (-not $hasCondition) { $conditionText = '(none - this step always runs)' }

    $runIn = ''
    if ($null -ne $Step.RunIn) { $runIn = [string] $Step.RunIn }

    return [pscustomobject] @{
        Name             = $name
        Kind             = $kind
        Disabled         = $disabled
        Flag             = [pscustomobject[]] @($flag)
        Condition        = $condition
        ConditionText    = $conditionText
        HasCondition     = $hasCondition
        ConditionCommand = ("Set-HDTStepCondition -Line `$line -Name '{0}' -Condition '{1}'" -f $name, $condition)
        RunIn            = $runIn
        RunInText        = (Get-HDTConsoleDisplayText -Text $runIn -Fallback 'any phase')
    }
}
