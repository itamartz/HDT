function Get-HDTCommandLineStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new CommandLine step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            THE COMMAND ARRIVES EMPTY AND THAT IS THE POINT. A template that
            guessed 'cmd.exe /c' would be a step that runs and does nothing,
            which is worse than one that plainly is not finished. successCodes
            is written out because 0 and 3010 is the pair almost every real
            step wants and it is the one an author would otherwise have to
            look up.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTCommandLineStepTemplate

            The YAML lines for a new CommandLine step, named after its type.

        .EXAMPLE
            $line = Get-HDTCommandLineStepTemplate -Name 'Prepare the disk'
            $line -join [System.Environment]::NewLine

            The same lines under a name of your own. They are lines, not a
            document: Add-HDTStep splices them into a sequence.yaml so the
            comments and the order of everything already in it survive.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Run Command Line'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: CommandLine'
        "  command: ''"
        '  successCodes: [0, 3010]'
    )
}
