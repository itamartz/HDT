function Get-HDTConsoleSequenceSave {
    <#
        .SYNOPSIS
            What one press of Apply on a task sequence writes: the edits in
            order, whether the tree went stale, and every command it ran.

        .DESCRIPTION
            ONE READ, EVERY CHANGE, ONE WRITE. Saving per row would write the
            document twice for a name and a description typed together, and the
            SECOND write would be built from lines read before the first - so the
            first edit vanishes into a file that looks like it saved. The edits
            are therefore returned as an ordered list to apply against one set of
            lines carried through, and the save happens once at the end.

            THE KEY IS 'name' AND THE PARAMETER IS -Name. The document spells its
            keys camelCase and the command spells its parameters PascalCase, so
            only the first letter changes - 'timeoutMinutes' is -TimeoutMinutes
            and not -Timeoutminutes, which would not bind.

            ONLY A RENAME MAKES THE TREE STALE. The row reads 'id - name', so a
            description edit leaves it accurate; rebuilding anyway re-reads every
            open share and revalidates every sequence in it, which is a third of
            a second spent to learn nothing.

            NOTHING PENDING ECHOES NOTHING, not a save of no changes. A press
            with an empty list never reaches the document, and a Save line in the
            box would name a write that did not happen - which is worse than an
            empty box, because it is a command somebody could retype against a
            file they did not mean to touch.

            EVERY COMMAND THE PRESS RAN, ending with the save. DESIGN 12's "learn
            the automation surface by clicking around" only works if the box
            shows the whole sequence, retypeable top to bottom.

            IT READS NO FILE AND WRITES NONE.

        .PARAMETER Pending
            The edited fields, as Get-HDTConsoleStepChange reports them: each
            with a Property naming the document key and a Value.

        .PARAMETER Path
            The document the save goes to.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Edit      one row per change, in order: Parameter, Value, Command
              Renamed   whether one of them was the name
              Command   every line the press ran, the save last

        .EXAMPLE
            Get-HDTConsoleSequenceSave -Pending $pending -Path 'C:\ws\Control\DEMO-05\sequence.yaml'

        .EXAMPLE
            $save = Get-HDTConsoleSequenceSave -Pending $pending -Path $documentPath
            if ($save.Renamed) { & $rebuildTree }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Pending,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $renamed = $false

    $edit = foreach ($one in @($Pending)) {
        if ($null -eq $one) { continue }

        $key = [string] $one.Property
        if ($key.Length -eq 0) { continue }

        # camelCase key, PascalCase parameter.
        $parameter = $key.Substring(0, 1).ToUpperInvariant() + $key.Substring(1)
        $value = [string] $one.Value

        # THE ROW READS 'id - name'. See the rebuild note above.
        if ($key -eq 'name') { $renamed = $true }

        [pscustomobject] @{
            Parameter = $parameter
            Value     = $value
            Command   = "Set-HDTTaskSequenceProperty -Line `$line -{0} '{1}'" -f $parameter, $value
        }
    }

    $edit = [pscustomobject[]] @($edit)

    # NOTHING PENDING ECHOES NOTHING. See above.
    $command = @()
    if ($edit.Count -gt 0) {
        $command = [string[]] @(
            @($edit.Command)
            "Save-HDTSequenceDocument -Line `$line -Path '{0}'" -f $Path
        )
    }

    return [pscustomobject] @{
        Edit    = $edit
        Renamed = $renamed
        Command = [string[]] $command
    }
}
