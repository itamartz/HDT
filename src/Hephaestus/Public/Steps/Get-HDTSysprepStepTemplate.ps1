function Get-HDTSysprepStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new Sysprep step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            runIn: FullOS IS WRITTEN OUT AND IS NOT OPTIONAL. sysprep.exe is not
            in WinPE at all, so a step left on the default would fail with
            "the system cannot find the file specified" at the end of a
            reference build - a two-word answer to a question about a machine
            somebody spent a day preparing.

            timeoutMinutes IS WRITTEN OUT BECAUSE THE DEFAULT IS WRONG HERE.
            A generalize on a machine with a large provisioned appx set runs for
            several minutes and reports nothing while it does; sixty is MDT's
            own order of magnitude and leaves room for the slow case rather than
            killing a working sysprep half way through.

            unattend: IS NOT. It is the GENERALIZE-PASS answer file, which is a
            different document from the deployment's unattend.xml, and most
            reference builds need none - so the key is left out rather than
            written empty, because an empty one reads like a setting somebody
            forgot to fill in.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTSysprepStepTemplate

            The YAML lines for a new Sysprep step, named after its type.

        .EXAMPLE
            $line = Get-HDTSysprepStepTemplate -Name 'Generalize the reference build'
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
        [string] $Name = 'Sysprep'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: Sysprep'
        '  runIn: FullOS'
        '  timeoutMinutes: 60'
    )
}
