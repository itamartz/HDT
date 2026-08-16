function Get-HDTGroupTemplate {
    <#
        .SYNOPSIS
            The YAML for a new, empty-looking group.

        .DESCRIPTION
            The group's counterpart to Get-HDT<Type>StepTemplate. A group is not
            a step type - it has no Invoke command and never appears in
            Get-HDTStepType - so it cannot carry its template the way a step type
            does, and it lives here instead. It is here rather than in a UI for
            the same reason all the others are: authoring YAML is the engine's
            job, and a window that wrote its own would be a second definition of
            what a group looks like.

            A NEW GROUP ARRIVES WITH A STEP IN IT, because this engine has no
            such thing as an empty one. 'steps:' with nothing under it is
            rejected by Import-HDTSequenceDocument with "steps must be a list of
            steps and groups", so a truly empty group would leave whoever created
            it holding a document that can no longer be read - and in an editor,
            no tree, every button dark, and no way back except discarding the
            other edits too.

            NoOp IS THE RIGHT PASSENGER. It is a real registered step type that
            does nothing, so the group is valid the moment it exists and the
            author replaces a placeholder rather than working around a broken
            document.

        .PARAMETER Name
            The group's name.

        .PARAMETER StepName
            The name of the placeholder step inside it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTGroupTemplate

        .EXAMPLE
            Get-HDTGroupTemplate -Name 'Preinstall'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'New Group',

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $StepName = 'New Step'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $line = New-Object -TypeName System.Collections.ArrayList

    [void] $line.Add('- group: {0}' -f $Name)
    [void] $line.Add('  steps:')

    # The passenger comes from the NoOp type's own template rather than being
    # written out again here, so a change to what a NoOp step looks like reaches
    # every new group without this function knowing about it.
    foreach ($current in @(Get-HDTNoOpStepTemplate -Name $StepName)) {
        [void] $line.Add('    ' + $current)
    }

    return [string[]] @($line)
}
