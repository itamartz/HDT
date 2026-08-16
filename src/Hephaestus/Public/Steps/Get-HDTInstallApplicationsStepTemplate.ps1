function Get-HDTInstallApplicationsStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new InstallApplications step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            THE SELECTION ARRIVES AS THE VARIABLE, NOT AS AN EMPTY LIST. MDT's
            Install Applications defaults to "Install multiple applications"
            reading its list from a variable, and that is the form that works
            with a wizard answer or a rule without the author editing the
            sequence again. An author who wants a fixed list replaces the token
            with one; an author who leaves it alone gets the behaviour they
            almost certainly wanted.

            runIn: FullOS is written out because an application installer in
            WinPE is the unusual case, and a step that tried to run one there
            would fail in a way that is tedious to diagnose.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTInstallApplicationsStepTemplate
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Install Applications'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: InstallApplications'
        "  selection: '%HDTApplications%'"
        '  runIn: FullOS'
    )
}
