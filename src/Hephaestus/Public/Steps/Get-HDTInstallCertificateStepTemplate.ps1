function Get-HDTInstallCertificateStepTemplate {
    <#
        .SYNOPSIS
            The YAML for a new InstallCertificate step.

        .DESCRIPTION
            The optional fourth of the step contract: what a NEW step of this
            type looks like on disk. See Get-HDTNoOpStepTemplate for the shape
            all of them share.

            IT COMES WITH THE CONDITION ON IT. The step is harmless on an image
            that carries no certificates - it completes having written nothing -
            but a sequence that runs it anyway says it does something it does
            not, and a technician reading the log sees a step nobody can explain.
            The condition is how the sequence SAYS "only when there are any".

            IT DECLARES NO PATHS. Which certificates go in is the boot image's
            answer, made on the Windows PE window and carried in bootstrap.json;
            a list repeated here is a second place for the two to disagree.

        .PARAMETER Name
            The step's name. Defaults to the name this type is offered under.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String[] - the YAML lines, unindented.

        .EXAMPLE
            Get-HDTInstallCertificateStepTemplate

            The YAML lines for a new InstallCertificate step, named after its type.

        .EXAMPLE
            $line = Get-HDTInstallCertificateStepTemplate -Name 'Prepare the disk'
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
        [string] $Name = 'Install Certificates'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    return [string[]] @(
        ('- name: {0}' -f $Name)
        '  type: InstallCertificate'
        '  target: "%HDTOSVolume%"'
        '  condition: "%HDTHasCertificate% == True"'
    )
}
