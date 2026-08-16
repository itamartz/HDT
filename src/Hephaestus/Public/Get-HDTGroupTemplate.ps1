function Get-HDTGroupTemplate {
    <#
        .SYNOPSIS
            The YAML for a new, empty group.

        .DESCRIPTION
            The group's counterpart to Get-HDT<Type>StepTemplate. A group is not
            a step type - it has no Invoke command and never appears in
            Get-HDTStepType - so it cannot carry its template the way a step type
            does, and it lives here instead. It is here rather than in a UI for
            the same reason all the others are: authoring YAML is the engine's
            job, and a window that wrote its own would be a second definition of
            what a group looks like.

            A NEW GROUP IS A GROUP AND NOTHING ELSE. It used to arrive carrying a
            NoOp step, because the engine refused a group with no steps in it and
            a truly empty one would have left whoever created it holding a
            document that could no longer be read. The engine accepts an empty
            group now - naming a shelf before there is anything to put on it is
            what an administrator does first - so the passenger went with the
            refusal, and pressing New Group adds a group.

            THE EMPTY LIST IS WRITTEN OUT, as `steps: []` rather than a bare
            `steps:`. Both parse to an empty group, but only the explicit one
            says so to a reader, to a schema validator and to any other YAML tool
            the file passes through.

        .PARAMETER Name
            The group's name.

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
        [string] $Name = 'New Group'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- group: {0}' -f $Name)
        '  steps: []'
    )
}
