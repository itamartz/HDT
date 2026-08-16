function Get-HDTInstallRolesStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new InstallRoles step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            THE FEATURE LIST ARRIVES EMPTY, for the reason the CommandLine
            template's command does: a guessed feature - Web-Server, say - would
            be a step that silently installs a role nobody asked for, which is
            worse than one that plainly is not finished. The step refuses to run
            with an empty list, so the unfinished state is loud.

            source: is written out as a comment rather than as a value. Most
            features do not need it, and the ones that do (the .NET 3.5 case)
            need a path only the administrator knows.

            runIn: FullOS because Install-WindowsFeature does not exist in WinPE.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTInstallRolesStepTemplate
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name = 'Install Roles'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: InstallRoles'
        '  features: []'
        '  includeManagementTools: true'
        '  # source: for features whose payload was removed from the image'
        '  runIn: FullOS'
    )
}
