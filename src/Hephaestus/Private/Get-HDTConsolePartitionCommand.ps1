function Get-HDTConsolePartitionCommand {
    <#
        .SYNOPSIS
            What the Partition Properties dialog's OK would run, as an
            administrator would retype it.

        .DESCRIPTION
            DESIGN 12 AGAIN: every action maps to a cmdlet and the console shows
            which one, so an administrator scripts what they can click.

            THE EDITOR ALREADY PRINTED THIS AND IT WAS NOT ENOUGH. It prints the
            line on its own strip AFTER the modal closes - so the whole time
            somebody is deciding whether eight boxes say what they meant, the
            command those boxes compose is behind a window. Every other modal in
            this console shows it live. This one had nowhere to.

            ADD OR SET IS DECIDED BY WHETHER THE ROW ALREADY EXISTS, which is
            what -Existing carries: the dialog opens empty for New and full for
            Edit, and those are the two commands the editor calls.

            A RENAME LOOKS THE ROW UP BY ITS OLD NAME. Set-HDTStepPartition finds
            a volume by what the document still says; the typed name is a value
            it writes. A line naming the new one would find nothing, which is
            exactly the line somebody would have copied.

            AN EMPTY NAME IS NO COMMAND. The dialog refuses a nameless volume -
            it is how every command refers to the row - and a line reading
            -Partition '' would look like one that could be run.

        .PARAMETER Step
            The task sequence step whose table is being edited.

        .PARAMETER Partition
            The volume name as the boxes currently read.

        .PARAMETER Existing
            The name the document still carries, when this row is one it already
            has. Empty means the row is new.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - one line, or empty when there is nothing to say.

        .EXAMPLE
            Get-HDTConsolePartitionCommand -Step 'Format and Partition' -Partition 'Recovery'

            Add-HDTStepPartition -Line $line -Name 'Format and Partition' -Partition 'Recovery'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Step,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowEmptyString()]
        [string] $Partition,

        [Parameter(Position = 2)]
        [AllowEmptyString()]
        [string] $Existing = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $subject = $Partition
    $verb = 'Add'

    if (-not [string]::IsNullOrWhiteSpace($Existing)) {
        $subject = $Existing
        $verb = 'Set'
    }

    if ([string]::IsNullOrWhiteSpace($Step)) { return '' }
    if ([string]::IsNullOrWhiteSpace($subject)) { return '' }

    $literal = {
        param([string] $Value)

        return "'" + ($Value -replace "'", "''") + "'"
    }

    # THE SAME SHAPE THE EDITOR'S OWN STRIP PRINTS, deliberately. Two windows
    # describing one press in two wordings is two things to keep in step.
    return '{0}-HDTStepPartition -Line $line -Name {1} -Partition {2}' -f
        $verb, (& $literal $Step), (& $literal $subject)
}
